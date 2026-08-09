/// MCP Stdio Transport Implementation
// - Standard input/output transport for CLI-based MCP communication
// - Used by Claude Desktop and other MCP clients that spawn the server
// - Reads JSON-RPC from stdin (newline delimited)
// - Writes JSON-RPC responses to stdout
// - Writes logs to stderr (NOT stdout to avoid protocol interference)
// - EOF on stdin triggers graceful shutdown
// - Handles SIGTERM/SIGINT for graceful shutdown with 5s timeout (REQ-019)
unit MCP.Transport.Stdio;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.rtti,
  MCP.Types,
  MCP.Events,
  MCP.Transport.Base;

type
  /// A 2026-07-28 subscriptions/listen registration on the stdio channel
  TMCPStdioSubscription = record
    /// JSON-RPC id of the subscriptions/listen request (= subscription id)
    Id: Variant;
    /// agreed notification filter
    FilterTools: Boolean;
    FilterPrompts: Boolean;
    FilterResources: Boolean;
    /// resource URIs subscribed via resourceSubscriptions
    FilterUris: TRawUtf8DynArray;
    /// whether this subscription is active
    Active: Boolean;
  end;

  /// Stdio Transport for MCP server
  // - Reads JSON-RPC messages from stdin, writes responses to stdout
  // - Messages are newline-delimited JSON
  // - Logs are written to stderr to avoid interfering with the protocol
  // - Handles SIGTERM/SIGINT with graceful shutdown (5s timeout for pending requests)
  TMCPStdioTransport = class(TMCPTransportBase)
  private
    fWriteLock: TRTLCriticalSection;
    fSubsLock: TRTLCriticalSection;
    fSubscriptions: array of TMCPStdioSubscription;
    /// True once a legacy initialize request was processed on this channel
    // - unsolicited list_changed notifications (pre-2026 behavior) are only
    //   emitted for such sessions; modern-era clients must opt in through
    //   subscriptions/listen
    fLegacySession: Boolean;
    /// Read a line from stdin
    function ReadLine: RawUtf8;
    /// Write a line to stdout (JSON-RPC responses), thread-safe
    procedure WriteLine(const Line: RawUtf8);
    /// Write a log message to stderr (NOT stdout)
    procedure LogToStderr(const Msg: RawUtf8);
    /// Process incoming messages in a loop
    procedure ProcessLoop;
    /// Wait for pending requests to complete (for graceful shutdown)
    // - Returns True if all requests completed within timeout
    function WaitForPendingRequests(TimeoutMs: Cardinal): Boolean;
    /// Handle a modern-era subscriptions/listen request (no response now;
    // the acknowledged notification is emitted instead)
    procedure HandleSubscriptionsListen(const RequestDoc: Variant);
    /// Remove the subscription matching a notifications/cancelled requestId
    // - returns True when a subscription was cancelled (message consumed)
    function CancelSubscription(const RequestId: Variant): Boolean;
    /// Forward a list-changed style event to legacy session and matching
    // modern subscriptions (Kind selects the filter flag; Uri for updated)
    procedure ForwardEvent(const Method: RawUtf8; const Data: Variant);
    /// Send the final SubscriptionsListenResult for every active
    // subscription (graceful teardown, 2026-07-28)
    procedure SendSubscriptionTeardowns;
    /// EventBus callbacks (called from background threads)
    procedure OnToolsListChanged(const Data: Variant);
    procedure OnResourcesListChanged(const Data: Variant);
    procedure OnResourcesUpdated(const Data: Variant);
    procedure OnPromptsListChanged(const Data: Variant);
    /// Generic passthrough: Data = {method, params}; forward verbatim
    procedure OnSendNotification(const Data: Variant);
    /// Subscribe/unsubscribe to EventBus notifications
    procedure SubscribeToEventBus;
    procedure UnsubscribeFromEventBus;
  public
    /// Create stdio transport
    constructor Create(const AConfig: TMCPTransportConfig); override;
    /// Destroy the transport
    destructor Destroy; override;
    /// Start reading from stdin (registers signal handlers for graceful shutdown)
    procedure Start; override;
    /// Stop the transport
    procedure Stop; override;
    /// Send a notification to stdout
    procedure SendNotification(const Method: RawUtf8;
      const Params: Variant); override;
  end;

implementation

{$ifdef OSWINDOWS}
uses
  Winapi.Windows;
{$endif OSWINDOWS}

{ TMCPStdioTransport }

constructor TMCPStdioTransport.Create(const AConfig: TMCPTransportConfig);
begin
  inherited Create(AConfig);
  {$ifdef OSWINDOWS}
  // ReadLn otherwise decodes redirected stdin with the active ANSI page,
  // turning valid JSON UTF-8 text such as "válido" into "vÃ¡lido".
  SetTextCodePage(Input, CP_UTF8);
  {$endif OSWINDOWS}
  InitializeCriticalSection(fWriteLock);
  InitializeCriticalSection(fSubsLock);
  fLegacySession := False;
end;

destructor TMCPStdioTransport.Destroy;
begin
  if fActive then
    Stop;
  DeleteCriticalSection(fSubsLock);
  DeleteCriticalSection(fWriteLock);
  inherited;
end;

function TMCPStdioTransport.ReadLine: RawUtf8;
var
  S: string;
begin
  Result := '';
  if not Eof(Input) then
  begin
    ReadLn(S);
    Result := StringToUtf8(S);
  end;
end;

procedure TMCPStdioTransport.WriteLine(const Line: RawUtf8);
var
  Payload: RawUtf8;
  Written: Integer;
begin
  // Thread-safe: EventBus callbacks come from background threads (pipe monitor).
  // Write RawUtf8 bytes directly. Converting through UnicodeString and the RTL
  // Text output encoded non-ASCII characters with the Windows console code page
  // (e.g. an em dash became a lone cp1252 $97 byte), violating JSONL UTF-8.
  EnterCriticalSection(fWriteLock);
  try
    Payload := Line + #10; // MCP stdio uses LF-only newline-delimited JSON.
    Written := FileWrite(
      {$ifdef OSWINDOWS}GetStdHandle(STD_OUTPUT_HANDLE){$else}
      TTextRec(Output).Handle{$endif}, Payload[1], Length(Payload));
    if Written <> Length(Payload) then
      raise EWriteError.CreateFmt(
        'Unable to write MCP stdio response (%d of %d bytes)',
        [Written, Length(Payload)]);
  finally
    LeaveCriticalSection(fWriteLock);
  end;
end;

procedure TMCPStdioTransport.LogToStderr(const Msg: RawUtf8);
begin
  // Write diagnostic log to stderr (MCP clients ignore stderr per spec)
  Write(ErrOutput, '[MCP] ', Utf8ToString(Msg), #10);
  Flush(ErrOutput);
  // Also send to TSynLog for file logging
  TSynLog.Add.Log(sllInfo, '%', [Msg]);
end;

procedure TMCPStdioTransport.ProcessLoop;
var
  InputLine: RawUtf8;
  ResponseJson: RawUtf8;
  RequestDoc: Variant;
  Method: RawUtf8;
  Ctx: TMCPRequestContext;
begin
  LogToStderr('Stdio transport started, waiting for JSON-RPC messages');

  while fActive and not Eof(Input) and not fShuttingDown do
  begin
    // Check for shutdown signal (SIGTERM/SIGINT)
    if CheckShutdownSignal then
    begin
      LogToStderr('Shutdown signal received, initiating graceful shutdown');
      fShuttingDown := True;
      Break;
    end;

    try
      InputLine := ReadLine;

      // Skip empty lines
      if TrimU(InputLine) = '' then
        Continue;

      // Don't accept new requests during shutdown
      if fShuttingDown then
      begin
        LogToStderr('Rejecting request during shutdown');
        ResponseJson := CreateJsonRpcError(Null, JSONRPC_SERVER_ERROR,
          'Server is shutting down');
        WriteLine(ResponseJson);
        Continue;
      end;

      LogToStderr(FormatUtf8('Received: %', [InputLine]));

      // Peek at the method for transport-level handling
      Method := '';
      try
        TDocVariantData(RequestDoc).InitJson(InputLine, JSON_FAST_FLOAT);
        Method := TDocVariantData(RequestDoc).U['method'];
      except
        VarClear(RequestDoc);
      end;

      // legacy initialize marks this channel as a pre-2026 session, which
      // keeps receiving unsolicited list_changed notifications
      if IdemPropNameU(Method, 'initialize') then
        fLegacySession := True;

      // 2026-07-28 long-lived notification channel: the transport owns the
      // subscription registry, so intercept before generic dispatch
      if IdemPropNameU(Method, 'subscriptions/listen') then
      begin
        HandleSubscriptionsListen(RequestDoc);
        Continue;
      end;

      // a notifications/cancelled naming an active subscription terminates
      // that stream (the only client-side cancel defined on stdio)
      if IdemPropNameU(Method, 'notifications/cancelled') and
         CancelSubscription(
           _Safe(TDocVariantData(RequestDoc).Value['params'])^.
             Value['requestId']) then
        Continue;

      // Process the request (era resolved from _meta by the processor)
      InitRequestContext(Ctx);
      Ctx.SessionId := fSessionId;
      ResponseJson := ProcessRequestEx(InputLine, Ctx);

      // Send response (skip if notification returns empty)
      if ResponseJson <> '' then
      begin
        WriteLine(ResponseJson);
        LogToStderr(FormatUtf8('Sent: %', [ResponseJson]));
      end;
    except
      on E: Exception do
      begin
        LogToStderr(FormatUtf8('Error: %', [E.Message]));
        // Send error response
        ResponseJson := CreateJsonRpcError(Null, JSONRPC_INTERNAL_ERROR,
          StringToUtf8(E.Message));
        WriteLine(ResponseJson);
      end;
    end;
  end;

  // Handle graceful shutdown if initiated by signal
  if fShuttingDown then
  begin
    LogToStderr(FormatUtf8('Waiting for % pending requests (timeout: % ms)',
      [GetPendingRequestCount, GRACEFUL_SHUTDOWN_TIMEOUT_MS]));
    WaitForPendingRequests(GRACEFUL_SHUTDOWN_TIMEOUT_MS);
  end;

  // graceful teardown of open subscriptions/listen streams while stdout is
  // still writable (Stop runs after fActive is cleared and would skip it)
  SendSubscriptionTeardowns;

  // Mark as inactive
  fActive := False;
  LogToStderr('Stdio transport stopped (EOF or shutdown)');
end;

function TMCPStdioTransport.WaitForPendingRequests(TimeoutMs: Cardinal): Boolean;
var
  WaitStart: Int64;
  ElapsedMs: Int64;
  PendingCount: Integer;
begin
  Result := False;
  WaitStart := GetTickCount64;

  repeat
    PendingCount := GetPendingRequestCount;
    if PendingCount = 0 then
    begin
      LogToStderr('All pending requests completed');
      Result := True;
      Exit;
    end;

    ElapsedMs := GetTickCount64 - WaitStart;
    if ElapsedMs >= TimeoutMs then
    begin
      LogToStderr(FormatUtf8(
        'Graceful shutdown timeout (% ms) with % pending requests - forcing shutdown',
        [TimeoutMs, PendingCount]));
      Exit;
    end;

    SleepHiRes(GRACEFUL_SHUTDOWN_POLL_MS);
  until False;
end;

procedure TMCPStdioTransport.Start;
begin
  if fActive then
    Exit;

  fActive := True;
  fShuttingDown := False;

  // Register signal handlers for graceful shutdown (SIGTERM/SIGINT)
  RegisterSignalHandlers;

  // Subscribe to EventBus for dynamic tool/resource/prompt changes
  SubscribeToEventBus;

  // For stdio, we run the processing in the main thread
  // This blocks until EOF is received on stdin or shutdown signal
  LogToStderr('Starting stdio transport (graceful shutdown enabled)');
  ProcessLoop;
end;

procedure TMCPStdioTransport.Stop;
begin
  if fActive then
  begin
    // graceful teardown: open subscriptions/listen streams get their final
    // JSON-RPC response before the channel closes (2026-07-28)
    SendSubscriptionTeardowns;
    UnsubscribeFromEventBus;
    fActive := False;
    LogToStderr('Stopping stdio transport');
  end;
end;

procedure TMCPStdioTransport.SendNotification(const Method: RawUtf8;
  const Params: Variant);
var
  NotificationJson: RawUtf8;
begin
  if not fActive then
    Exit;

  NotificationJson := BuildNotification(Method, Params);
  WriteLine(NotificationJson);
  LogToStderr(FormatUtf8('Notification sent: %', [Method]));
end;

{ 2026-07-28 subscriptions/listen support }

procedure TMCPStdioTransport.HandleSubscriptionsListen(
  const RequestDoc: Variant);
var
  ReqId, Params, Agreed, AckParams, Meta, UrisV: Variant;
  FilterDoc, UrisDoc: PDocVariantData;
  Version: RawUtf8;
  Sub: TMCPStdioSubscription;
  i: PtrInt;
begin
  ReqId := TDocVariantData(RequestDoc).Value['id'];
  Params := TDocVariantData(RequestDoc).Value['params'];

  // the method only exists in the stateless 2026-07-28+ protocol
  Version := GetMetaProtocolVersion(Params);
  if not IsSupportedProtocolVersion(Version) then
  begin
    WriteLine(CreateUnsupportedVersionError(ReqId, Version));
    Exit;
  end;
  if not IsModernProtocolVersion(Version) then
  begin
    WriteLine(CreateJsonRpcError(ReqId, JSONRPC_METHOD_NOT_FOUND,
      'Method [subscriptions/listen] not found'));
    Exit;
  end;

  Finalize(Sub);
  FillCharFast(Sub, SizeOf(Sub), 0);
  Sub.Id := ReqId;
  FilterDoc := nil;
  if not VarIsEmptyOrNull(Params) then
    FilterDoc := _Safe(Params)^.O['notifications'];
  if FilterDoc <> nil then
  begin
    Sub.FilterTools := FilterDoc^.B['toolsListChanged'];
    Sub.FilterPrompts := FilterDoc^.B['promptsListChanged'];
    Sub.FilterResources := FilterDoc^.B['resourcesListChanged'];
    UrisDoc := FilterDoc^.A['resourceSubscriptions'];
    if UrisDoc <> nil then
      UrisDoc^.ToRawUtf8DynArray(Sub.FilterUris);
  end;
  Sub.Active := True;

  EnterCriticalSection(fSubsLock);
  try
    SetLength(fSubscriptions, Length(fSubscriptions) + 1);
    fSubscriptions[High(fSubscriptions)] := Sub;
  finally
    LeaveCriticalSection(fSubsLock);
  end;

  // the acknowledged notification MUST be the first message carrying this
  // subscription's id; the JSON-RPC response is only sent on graceful
  // teardown, so none is emitted here
  Agreed := _ObjFast([]); // stays an empty OBJECT when nothing was requested
  if Sub.FilterTools then
    TDocVariantData(Agreed).B['toolsListChanged'] := True;
  if Sub.FilterPrompts then
    TDocVariantData(Agreed).B['promptsListChanged'] := True;
  if Sub.FilterResources then
    TDocVariantData(Agreed).B['resourcesListChanged'] := True;
  if Sub.FilterUris <> nil then
  begin
    TDocVariantData(UrisV).InitArray([], JSON_FAST);
    for i := 0 to High(Sub.FilterUris) do
      TDocVariantData(UrisV).AddItemText(Sub.FilterUris[i]);
    TDocVariantData(Agreed).AddValue('resourceSubscriptions', UrisV);
  end;
  TDocVariantData(Meta).InitFast;
  TDocVariantData(Meta).AddValue(MCP_META_SUBSCRIPTION_ID, ReqId);
  TDocVariantData(AckParams).InitFast;
  TDocVariantData(AckParams).AddValue('notifications', Agreed);
  TDocVariantData(AckParams).AddValue('_meta', Meta);
  SendNotification('notifications/subscriptions/acknowledged', AckParams);

  LogToStderr(FormatUtf8('subscriptions/listen registered (id: %)',
    [VariantToUtf8(ReqId)]));
end;

function TMCPStdioTransport.CancelSubscription(
  const RequestId: Variant): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if VarIsEmptyOrNull(RequestId) then
    Exit;
  EnterCriticalSection(fSubsLock);
  try
    for i := 0 to High(fSubscriptions) do
      if fSubscriptions[i].Active and
         MCPRequestIdEquals(fSubscriptions[i].Id, RequestId) then
      begin
        fSubscriptions[i].Active := False;
        Result := True;
        Break;
      end;
  finally
    LeaveCriticalSection(fSubsLock);
  end;
  if Result then
    LogToStderr(FormatUtf8('subscription cancelled (id: %)',
      [VariantToUtf8(RequestId)]));
end;

procedure TMCPStdioTransport.ForwardEvent(const Method: RawUtf8;
  const Data: Variant);
var
  i, n: Integer;
  Subs: array of TMCPStdioSubscription;
  Uri: RawUtf8;
  Match: Boolean;
begin
  if not fActive then
    Exit;

  // pre-2026 sessions get every notification, unsolicited (legacy behavior)
  if fLegacySession then
    SendNotification(Method, Data);

  // modern subscriptions only receive what they opted in to, tagged with
  // their subscription id
  EnterCriticalSection(fSubsLock);
  try
    SetLength(Subs, Length(fSubscriptions));
    n := 0;
    for i := 0 to High(fSubscriptions) do
      if fSubscriptions[i].Active then
      begin
        Subs[n] := fSubscriptions[i];
        Inc(n);
      end;
  finally
    LeaveCriticalSection(fSubsLock);
  end;

  Uri := '';
  if Method = MCP_EVENT_RESOURCES_UPDATED then
    Uri := _Safe(Data)^.U['uri'];

  for i := 0 to n - 1 do
  begin
    Match := False;
    if Method = MCP_EVENT_TOOLS_LIST_CHANGED then
      Match := Subs[i].FilterTools
    else if Method = MCP_EVENT_PROMPTS_LIST_CHANGED then
      Match := Subs[i].FilterPrompts
    else if Method = MCP_EVENT_RESOURCES_LIST_CHANGED then
      Match := Subs[i].FilterResources
    else if Method = MCP_EVENT_RESOURCES_UPDATED then
      Match := (Uri <> '') and (FindRawUtf8(Subs[i].FilterUris, Uri) >= 0);
    if Match then
      SendNotification(Method, AddSubscriptionMeta(Data, Subs[i].Id));
  end;
end;

procedure TMCPStdioTransport.SendSubscriptionTeardowns;
var
  i: PtrInt;
  Response, ResultV, Meta: Variant;
begin
  EnterCriticalSection(fSubsLock);
  try
    for i := 0 to High(fSubscriptions) do
      if fSubscriptions[i].Active then
      begin
        fSubscriptions[i].Active := False;
        TDocVariantData(Meta).InitFast;
        TDocVariantData(Meta).AddValue(MCP_META_SUBSCRIPTION_ID,
          fSubscriptions[i].Id);
        TDocVariantData(ResultV).InitFast;
        TDocVariantData(ResultV).U['resultType'] := 'complete';
        TDocVariantData(ResultV).AddValue('_meta', Meta);
        Response := CreateJsonRpcResponse(fSubscriptions[i].Id);
        TDocVariantData(Response).AddValue('result', ResultV);
        try
          WriteLine(TDocVariantData(Response).ToJson);
        except
          // stdout may already be closed (EOF-initiated shutdown)
        end;
        VarClear(Response);
        VarClear(ResultV);
        VarClear(Meta);
      end;
  finally
    LeaveCriticalSection(fSubsLock);
  end;
end;

{ EventBus Integration }

procedure TMCPStdioTransport.OnToolsListChanged(const Data: Variant);
begin
  ForwardEvent(MCP_EVENT_TOOLS_LIST_CHANGED, Data);
end;

procedure TMCPStdioTransport.OnResourcesListChanged(const Data: Variant);
begin
  ForwardEvent(MCP_EVENT_RESOURCES_LIST_CHANGED, Data);
end;

procedure TMCPStdioTransport.OnResourcesUpdated(const Data: Variant);
begin
  ForwardEvent(MCP_EVENT_RESOURCES_UPDATED, Data);
end;

procedure TMCPStdioTransport.OnPromptsListChanged(const Data: Variant);
begin
  ForwardEvent(MCP_EVENT_PROMPTS_LIST_CHANGED, Data);
end;

procedure TMCPStdioTransport.OnSendNotification(const Data: Variant);
var
  Doc: PDocVariantData;
begin
  // Generic passthrough: the publisher provides the actual JSON-RPC method
  // and params; forward them verbatim. Used for server-initiated notifications
  // the framework doesn't model directly (e.g. notifications/claude/channel).
  Doc := _Safe(Data);
  SendNotification(Doc^.U['method'], Doc^.GetValueOrNull('params'));
end;

procedure TMCPStdioTransport.SubscribeToEventBus;
var
  EventBus: TMCPEventBus;
begin
  EventBus := MCPEventBus;
  // Clear stale pending events from pre-initialization tool registrations.
  // The client calls tools/list after init to get the full current list,
  // so these queued notifications would be redundant and premature.
  EventBus.ClearPending(MCP_EVENT_TOOLS_LIST_CHANGED);
  EventBus.ClearPending(MCP_EVENT_RESOURCES_LIST_CHANGED);
  EventBus.ClearPending(MCP_EVENT_RESOURCES_UPDATED);
  EventBus.ClearPending(MCP_EVENT_PROMPTS_LIST_CHANGED);
  // Drop any pre-subscription passthrough notifications (premature at startup)
  EventBus.ClearPending(MCP_EVENT_SEND_NOTIFICATION);
  // Subscribe for future changes (app connect/disconnect)
  EventBus.Subscribe(MCP_EVENT_TOOLS_LIST_CHANGED, OnToolsListChanged);
  EventBus.Subscribe(MCP_EVENT_RESOURCES_LIST_CHANGED, OnResourcesListChanged);
  EventBus.Subscribe(MCP_EVENT_RESOURCES_UPDATED, OnResourcesUpdated);
  EventBus.Subscribe(MCP_EVENT_PROMPTS_LIST_CHANGED, OnPromptsListChanged);
  // Generic server-initiated notification passthrough (e.g. channel events)
  EventBus.Subscribe(MCP_EVENT_SEND_NOTIFICATION, OnSendNotification);
  TSynLog.Add.Log(sllInfo, 'Stdio transport subscribed to EventBus notifications');
end;

procedure TMCPStdioTransport.UnsubscribeFromEventBus;
var
  EventBus: TMCPEventBus;
begin
  EventBus := MCPEventBus;
  EventBus.Unsubscribe(MCP_EVENT_TOOLS_LIST_CHANGED, OnToolsListChanged);
  EventBus.Unsubscribe(MCP_EVENT_RESOURCES_LIST_CHANGED, OnResourcesListChanged);
  EventBus.Unsubscribe(MCP_EVENT_RESOURCES_UPDATED, OnResourcesUpdated);
  EventBus.Unsubscribe(MCP_EVENT_PROMPTS_LIST_CHANGED, OnPromptsListChanged);
  EventBus.Unsubscribe(MCP_EVENT_SEND_NOTIFICATION, OnSendNotification);
  TSynLog.Add.Log(sllInfo, 'Stdio transport unsubscribed from EventBus notifications');
end;

end.
