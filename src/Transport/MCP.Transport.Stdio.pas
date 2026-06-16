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
  /// Stdio Transport for MCP server
  // - Reads JSON-RPC messages from stdin, writes responses to stdout
  // - Messages are newline-delimited JSON
  // - Logs are written to stderr to avoid interfering with the protocol
  // - Handles SIGTERM/SIGINT with graceful shutdown (5s timeout for pending requests)
  TMCPStdioTransport = class(TMCPTransportBase)
  private
    fWriteLock: TRTLCriticalSection;
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
    /// EventBus callbacks (called from background threads)
    procedure OnToolsListChanged(const Data: Variant);
    procedure OnResourcesListChanged(const Data: Variant);
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

{ TMCPStdioTransport }

constructor TMCPStdioTransport.Create(const AConfig: TMCPTransportConfig);
begin
  inherited Create(AConfig);
  InitializeCriticalSection(fWriteLock);
end;

destructor TMCPStdioTransport.Destroy;
begin
  if fActive then
    Stop;
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
begin
  // Thread-safe: EventBus callbacks come from background threads (pipe monitor).
  // Use Write + explicit LF instead of WriteLn. On Windows, WriteLn outputs
  // CRLF (\r\n) but MCP clients expect LF-only (\n) line endings.
  EnterCriticalSection(fWriteLock);
  try
    Write(Utf8ToString(Line));
    Write(#10);
    Flush(Output);
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

      // Process the request
      ResponseJson := ProcessRequest(InputLine, fSessionId);

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

{ EventBus Integration }

procedure TMCPStdioTransport.OnToolsListChanged(const Data: Variant);
begin
  SendNotification(MCP_EVENT_TOOLS_LIST_CHANGED, Data);
end;

procedure TMCPStdioTransport.OnResourcesListChanged(const Data: Variant);
begin
  SendNotification(MCP_EVENT_RESOURCES_LIST_CHANGED, Data);
end;

procedure TMCPStdioTransport.OnPromptsListChanged(const Data: Variant);
begin
  SendNotification(MCP_EVENT_PROMPTS_LIST_CHANGED, Data);
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
  EventBus.ClearPending(MCP_EVENT_PROMPTS_LIST_CHANGED);
  // Drop any pre-subscription passthrough notifications (premature at startup)
  EventBus.ClearPending(MCP_EVENT_SEND_NOTIFICATION);
  // Subscribe for future changes (app connect/disconnect)
  EventBus.Subscribe(MCP_EVENT_TOOLS_LIST_CHANGED, OnToolsListChanged);
  EventBus.Subscribe(MCP_EVENT_RESOURCES_LIST_CHANGED, OnResourcesListChanged);
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
  EventBus.Unsubscribe(MCP_EVENT_PROMPTS_LIST_CHANGED, OnPromptsListChanged);
  EventBus.Unsubscribe(MCP_EVENT_SEND_NOTIFICATION, OnSendNotification);
  TSynLog.Add.Log(sllInfo, 'Stdio transport unsubscribed from EventBus notifications');
end;

end.
