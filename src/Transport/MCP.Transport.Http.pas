/// MCP HTTP Transport Implementation with SSE Support
// - HTTP transport using mORMot2 THttpAsyncServer
// - Implements IMCPTransport for HTTP-based MCP communication
// - Supports Server-Sent Events (SSE) for streaming responses and notifications
// - MCP 2025-06-18 Streamable HTTP transport specification
// - Handles SIGTERM/SIGINT for graceful shutdown with 5s timeout (REQ-019)
// - SSE keepalive: sends `: keepalive` comment every 30s (configurable) (REQ-020)
unit MCP.Transport.Http;

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
  mormot.core.data,
  mormot.core.rtti,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.net.sock,
  mormot.net.http,
  mormot.net.server,
  mormot.net.async,
  mormot.crypt.secure,
  MCP.Types,
  MCP.Transport.Base,
  MCP.Events;

const
  /// Content-Type for Server-Sent Events
  SSE_CONTENT_TYPE: RawUtf8 = 'text/event-stream';

  /// Maximum number of SSE connections to track
  MAX_SSE_CONNECTIONS = 1000;

  /// Maximum number of sessions to track
  MAX_SESSIONS = 10000;

  /// Session timeout in seconds (30 minutes)
  SESSION_TIMEOUT_SECONDS = 1800;

  /// Default SSE keepalive interval in milliseconds (30 seconds)
  DEFAULT_SSE_KEEPALIVE_INTERVAL_MS = 30000;

  /// SSE keepalive comment line sent to clients
  SSE_KEEPALIVE_COMMENT: RawUtf8 = ': keepalive'#13#10#13#10;

type
  /// Record to track an SSE client connection
  // - covers both legacy GET streams (2025-xx eras) and 2026-07-28
  //   subscriptions/listen response streams
  TMCPSSEConnection = record
    /// Async handle for the connection
    Handle: TConnectionAsyncHandle;
    /// Session ID associated with this connection (legacy GET streams)
    SessionId: RawUtf8;
    /// Timestamp when connection was established
    ConnectedAt: TDateTime;
    /// Timestamp of last data sent (for keepalive tracking)
    LastSentAt: Int64;
    /// Whether this connection is active
    Active: Boolean;
    /// True when this is a 2026-07-28 subscriptions/listen stream
    IsSubscription: Boolean;
    /// JSON-RPC id of the subscriptions/listen request (= subscription id)
    SubscriptionId: Variant;
    /// agreed notification filter (subscriptions/listen only)
    FilterTools: Boolean;
    FilterPrompts: Boolean;
    FilterResources: Boolean;
    /// resource URIs subscribed via resourceSubscriptions
    FilterUris: TRawUtf8DynArray;
  end;

  /// Dynamic array of SSE connections
  TMCPSSEConnectionArray = array of TMCPSSEConnection;

  /// Record to track a session
  TMCPSession = record
    /// Cryptographically secure session ID
    SessionId: RawUtf8;
    /// Protocol version negotiated
    ProtocolVersion: RawUtf8;
    /// Timestamp when session was created
    CreatedAt: TDateTime;
    /// Timestamp of last activity
    LastActivityAt: TDateTime;
    /// Whether the session has been initialized (received notifications/initialized)
    Initialized: Boolean;
    /// Whether this session is active
    Active: Boolean;
  end;

  /// Dynamic array of sessions
  TMCPSessionArray = array of TMCPSession;

  // Forward declaration
  TMCPHttpTransport = class;

  /// Thread that sends periodic keepalive comments to SSE connections
  TMCPSSEKeepaliveThread = class(TThread)
  private
    fTransport: TMCPHttpTransport;
    fIntervalMs: Cardinal;
    fTerminated: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ATransport: TMCPHttpTransport; AIntervalMs: Cardinal);
    procedure SignalTerminate;
  end;

  /// HTTP Transport for MCP server with SSE support
  // - Implements MCP 2025-06-18 Streamable HTTP transport
  // - GET /mcp opens SSE stream for server-to-client notifications
  // - POST /mcp processes JSON-RPC requests (JSON or SSE response)
  // - DELETE /mcp terminates session
  // - Handles SIGTERM/SIGINT with graceful shutdown (5s timeout for pending requests)
  TMCPHttpTransport = class(TMCPTransportBase)
  private
    fHttpServer: THttpServerSocketGeneric;
    fSSEConnections: TMCPSSEConnectionArray;
    fSSEConnectionCount: Integer;
    fSSELock: TRTLCriticalSection;
    fSessions: TMCPSessionArray;
    fSessionCount: Integer;
    fSessionLock: TRTLCriticalSection;
    fSSEKeepaliveThread: TMCPSSEKeepaliveThread;
    fSSEKeepaliveIntervalMs: Cardinal;
    /// Main request handler
    function OnRequest(Ctxt: THttpServerRequestAbstract): Cardinal;
    /// Handle GET request - establish SSE stream
    function HandleGetSSE(Ctxt: THttpServerRequestAbstract): Cardinal;
    /// Handle POST request - JSON-RPC processing
    function HandlePost(Ctxt: THttpServerRequestAbstract): Cardinal;
    /// Handle CORS preflight
    procedure SetCorsHeaders(Ctxt: THttpServerRequestAbstract;
      const AllowedOrigin: RawUtf8);
    /// Check if CORS origin is allowed
    function IsOriginAllowed(const Origin: RawUtf8): Boolean;
    /// Extract header value from InHeaders
    function GetHeader(Ctxt: THttpServerRequestAbstract;
      const HeaderName: RawUtf8): RawUtf8;
    /// Check if client accepts SSE
    function AcceptsSSE(Ctxt: THttpServerRequestAbstract): Boolean;
    /// Add a connection record to tracking (shared slot logic)
    function AddSSEConnectionSlot(const Conn: TMCPSSEConnection): Boolean;
    /// Add a legacy GET SSE connection to tracking
    function AddSSEConnection(Handle: TConnectionAsyncHandle;
      const SessionId: RawUtf8): Boolean;
    /// Add a 2026-07-28 subscriptions/listen stream to tracking
    function AddSubscriptionConnection(Handle: TConnectionAsyncHandle;
      const SubscriptionId: Variant;
      AFilterTools, AFilterPrompts, AFilterResources: Boolean;
      const AFilterUris: TRawUtf8DynArray): Boolean;
    /// Remove an SSE connection from tracking
    procedure RemoveSSEConnection(Handle: TConnectionAsyncHandle);
    /// Handle a modern-era POST subscriptions/listen request
    function HandleSubscriptionsListen(Ctxt: THttpServerRequestAbstract;
      const RequestDoc: Variant): Cardinal;
    /// Route a server-to-client notification to the right streams
    // - legacy GET streams receive every notification (pre-2026 behavior)
    // - subscriptions/listen streams only receive the notification types the
    //   client opted in to, tagged with their subscription id in _meta
    procedure BroadcastEvent(const Method: RawUtf8; const Params: Variant);
    /// Send the final SubscriptionsListenResult to every open subscription
    // stream (graceful teardown, 2026-07-28)
    procedure SendSubscriptionTeardowns;
    /// Format a message as SSE data
    function FormatSSEData(const JsonData: RawUtf8): RawUtf8;
    /// Send SSE data to a specific connection
    function SendSSEToConnection(Handle: TConnectionAsyncHandle;
      const Data: RawUtf8): Boolean;
    /// Get the async server instance (for SSE operations)
    function GetAsyncServer: THttpAsyncServer;
    /// Handle DELETE request - terminate session
    function HandleDelete(Ctxt: THttpServerRequestAbstract): Cardinal;
    /// Create a new session with given session ID
    function CreateSession(const SessionId: RawUtf8;
      const ProtocolVersion: RawUtf8): Boolean;
    /// Find a session by ID
    function FindSession(const SessionId: RawUtf8): Integer;
    /// Validate session ID from request
    function ValidateSession(const SessionId: RawUtf8): Boolean;
    /// Mark session as initialized
    procedure SetSessionInitialized(const SessionId: RawUtf8);
    /// Update session last activity timestamp
    procedure TouchSession(const SessionId: RawUtf8);
    /// Terminate a session
    function TerminateSession(const SessionId: RawUtf8): Boolean;
    /// Remove SSE connections for a session
    procedure RemoveSSEConnectionsForSession(const SessionId: RawUtf8);
    /// Clean up expired sessions
    procedure CleanupExpiredSessions;
    /// Check if request requires an active session
    function RequiresSession(const Method: RawUtf8): Boolean;
    /// Validate and return protocol version from request
    // - Returns the protocol version to use (from header or default)
    // - Sets ErrorResponse if version is not supported
    function ValidateProtocolVersion(Ctxt: THttpServerRequestAbstract;
      out ProtocolVersion: RawUtf8; out ErrorResponse: RawUtf8): Boolean;
    /// Send keepalive to all SSE connections that need it
    procedure SendSSEKeepalives;
    /// Send keepalive comment to a specific connection
    // - Returns True if sent successfully
    function SendSSEKeepalive(Handle: TConnectionAsyncHandle): Boolean;
    /// Update the last sent timestamp for a connection
    procedure UpdateSSELastSent(Handle: TConnectionAsyncHandle);
    /// Event bus callback handlers
    procedure OnToolsListChanged(const Data: Variant);
    procedure OnResourcesListChanged(const Data: Variant);
    procedure OnResourcesUpdated(const Data: Variant);
    procedure OnPromptsListChanged(const Data: Variant);
    procedure OnMessage(const Data: Variant);
    procedure OnProgress(const Data: Variant);
    procedure OnCancelled(const Data: Variant);
    /// Subscribe to event bus notifications
    procedure SubscribeToEventBus;
    /// Unsubscribe from event bus notifications
    procedure UnsubscribeFromEventBus;
  public
    /// Create HTTP transport with given configuration
    constructor Create(const AConfig: TMCPTransportConfig); override;
    /// Destroy the transport
    destructor Destroy; override;
    /// Start the HTTP server (registers signal handlers for graceful shutdown)
    procedure Start; override;
    /// Stop the HTTP server
    procedure Stop; override;
    /// Initiate graceful shutdown - waits for pending requests up to timeout
    // - Stops accepting new connections
    // - Waits up to TimeoutMs (default 5000) for pending requests
    // - Closes all SSE connections
    // - Returns True if all requests completed before timeout
    function GracefulShutdown(TimeoutMs: Cardinal = 0): Boolean; override;
    /// Send a notification to all connected SSE clients
    // - Broadcasts the notification to all active SSE connections
    procedure SendNotification(const Method: RawUtf8;
      const Params: Variant); override;
    /// Number of active SSE connections
    property SSEConnectionCount: Integer read fSSEConnectionCount;
    /// SSE keepalive interval in milliseconds (default 30000)
    // - Set to 0 to disable keepalives
    property SSEKeepaliveIntervalMs: Cardinal
      read fSSEKeepaliveIntervalMs write fSSEKeepaliveIntervalMs;
  end;

implementation

uses
  mormot.core.datetime;

const
  HTTP_OK = 200;
  HTTP_ACCEPTED_202 = 202;
  HTTP_NO_CONTENT = 204;
  HTTP_BAD_REQUEST = 400;
  HTTP_FORBIDDEN = 403;
  HTTP_NOT_FOUND = 404;
  HTTP_METHOD_NOT_ALLOWED = 405;
  HTTP_INTERNAL_SERVER_ERROR = 500;

{ TMCPSSEKeepaliveThread }

constructor TMCPSSEKeepaliveThread.Create(ATransport: TMCPHttpTransport;
  AIntervalMs: Cardinal);
begin
  fTransport := ATransport;
  fIntervalMs := AIntervalMs;
  fTerminated := False;
  FreeOnTerminate := False;
  inherited Create(False); // Start immediately
end;

procedure TMCPSSEKeepaliveThread.SignalTerminate;
begin
  fTerminated := True;
end;

procedure TMCPSSEKeepaliveThread.Execute;
var
  WaitMs: QWord;
  WaitStart: QWord;
begin
  TSynLog.Add.Log(sllDebug, 'SSE keepalive thread started (interval: % ms)',
    [fIntervalMs]);

  while not fTerminated do
  begin
    // Sleep in small intervals to allow quick termination
    WaitStart := GetTickCount64;
    WaitMs := 0;
    while (not fTerminated) and (WaitMs < fIntervalMs) do
    begin
      SleepHiRes(100);  // Check termination every 100ms
      WaitMs := GetTickCount64 - WaitStart;
    end;

    // Send keepalives if not terminating
    if not fTerminated then
      fTransport.SendSSEKeepalives;
  end;

  TSynLog.Add.Log(sllDebug, 'SSE keepalive thread terminated');
end;

{ TMCPHttpTransport }

constructor TMCPHttpTransport.Create(const AConfig: TMCPTransportConfig);
begin
  inherited Create(AConfig);
  InitializeCriticalSection(fSSELock);
  InitializeCriticalSection(fSessionLock);
  SetLength(fSSEConnections, 0);
  SetLength(fSessions, 0);
  fSSEConnectionCount := 0;
  fSessionCount := 0;
  // Use configured keepalive interval, or default if not set
  if AConfig.SSEKeepaliveIntervalMs > 0 then
    fSSEKeepaliveIntervalMs := AConfig.SSEKeepaliveIntervalMs
  else
    fSSEKeepaliveIntervalMs := DEFAULT_SSE_KEEPALIVE_INTERVAL_MS;
  fSSEKeepaliveThread := nil;
end;

destructor TMCPHttpTransport.Destroy;
begin
  if fActive then
    Stop;
  DeleteCriticalSection(fSSELock);
  DeleteCriticalSection(fSessionLock);
  inherited;
end;

procedure TMCPHttpTransport.Start;
var
  Port: RawUtf8;
  Options: THttpServerOptions;
  Scheme: RawUtf8;
begin
  if fActive then
    Exit;

  fShuttingDown := False;

  // Register signal handlers for graceful shutdown (SIGTERM/SIGINT)
  RegisterSignalHandlers;

  Port := UInt32ToUtf8(fConfig.HttpPort);

  // Build server options
  Options := [hsoNoXPoweredHeader];
  if fConfig.SSLEnabled then
    Include(Options, hsoEnableTls);

  fHttpServer := THttpAsyncServer.Create(
    Port,
    nil,
    nil,
    'MCP Server',
    SystemInfo.dwNumberOfProcessors + 1,
    30000,  // 30 second keep-alive for SSE connections
    Options
  );

  fHttpServer.OnRequest := OnRequest;

  // Wait for server to start, with TLS configuration if enabled
  // WaitStarted/WaitStartedHttps are procedures that raise exceptions on failure
  if fConfig.SSLSelfSigned then
  begin
    fHttpServer.WaitStartedHttps;
    Scheme := 'https';
  end
  else if fConfig.SSLEnabled then
  begin
    fHttpServer.WaitStarted(30,
      Utf8ToString(fConfig.SSLCertFile),
      Utf8ToString(fConfig.SSLKeyFile),
      fConfig.SSLKeyPassword);
    Scheme := 'https';
  end
  else
  begin
    fHttpServer.WaitStarted;
    Scheme := 'http';
  end;

  fActive := True;

  // Start SSE keepalive thread if interval > 0
  if fSSEKeepaliveIntervalMs > 0 then
  begin
    fSSEKeepaliveThread := TMCPSSEKeepaliveThread.Create(Self,
      fSSEKeepaliveIntervalMs);
    TSynLog.Add.Log(sllDebug, 'SSE keepalive enabled (interval: % ms)',
      [fSSEKeepaliveIntervalMs]);
  end;

  // Subscribe to event bus for notifications
  SubscribeToEventBus;

  TSynLog.Add.Log(sllInfo,
    'MCP HTTP Transport started on %://%:% (SSE enabled, graceful shutdown enabled)',
    [Scheme, fConfig.HttpHost, fConfig.HttpPort]);
end;

function TMCPHttpTransport.GracefulShutdown(TimeoutMs: Cardinal): Boolean;
var
  WaitStart: Int64;
  ElapsedMs: Int64;
  PendingCount: Integer;
  SSECount: Integer;
  NotifyParams: Variant;
begin
  Result := False;

  if not fActive then
  begin
    Result := True;
    Exit;
  end;

  // Set shutdown flag - new requests will be rejected
  fShuttingDown := True;
  TSynLog.Add.Log(sllInfo, 'HTTP Transport graceful shutdown initiated');

  // Use default timeout if not specified
  if TimeoutMs = 0 then
    TimeoutMs := GRACEFUL_SHUTDOWN_TIMEOUT_MS;

  // Send shutdown notification to legacy SSE clients (non-spec, historical)
  TDocVariantData(NotifyParams).InitFast;
  TDocVariantData(NotifyParams).S['reason'] := 'server_shutdown';
  try
    SendNotification('notifications/shutdown', NotifyParams);
  except
    // Ignore errors during shutdown notification
  end;

  // 2026-07-28: a subscriptions/listen stream torn down gracefully receives
  // its JSON-RPC response (SubscriptionsListenResult) as the final message
  try
    SendSubscriptionTeardowns;
  except
    // Ignore errors during shutdown teardown
  end;

  // Wait for pending requests to complete or timeout
  WaitStart := GetTickCount64;

  repeat
    PendingCount := GetPendingRequestCount;
    if PendingCount = 0 then
    begin
      TSynLog.Add.Log(sllInfo, 'All pending HTTP requests completed');
      Result := True;
      Break;
    end;

    ElapsedMs := GetTickCount64 - WaitStart;
    if ElapsedMs >= TimeoutMs then
    begin
      TSynLog.Add.Log(sllWarning,
        'HTTP graceful shutdown timeout (% ms) with % pending requests',
        [TimeoutMs, PendingCount]);
      Break;
    end;

    // Log progress periodically (every second)
    if (ElapsedMs mod 1000) < GRACEFUL_SHUTDOWN_POLL_MS then
      TSynLog.Add.Log(sllDebug,
        'Waiting for % pending HTTP requests (% ms elapsed)',
        [PendingCount, ElapsedMs]);

    SleepHiRes(GRACEFUL_SHUTDOWN_POLL_MS);
  until False;

  // Log SSE connection count before closing
  EnterCriticalSection(fSSELock);
  try
    SSECount := fSSEConnectionCount;
  finally
    LeaveCriticalSection(fSSELock);
  end;
  if SSECount > 0 then
    TSynLog.Add.Log(sllInfo, 'Closing % active SSE connections', [SSECount]);

  // Now stop the transport
  Stop;

  TSynLog.Add.Log(sllInfo, 'HTTP Transport graceful shutdown completed (success: %)',
    [Result]);
end;

procedure TMCPHttpTransport.Stop;
var
  i: Integer;
begin
  if not fActive then
    Exit;

  // Unsubscribe from event bus first
  UnsubscribeFromEventBus;

  // Stop keepalive thread first
  if Assigned(fSSEKeepaliveThread) then
  begin
    fSSEKeepaliveThread.SignalTerminate;
    fSSEKeepaliveThread.WaitFor;
    FreeAndNil(fSSEKeepaliveThread);
    TSynLog.Add.Log(sllDebug, 'SSE keepalive thread stopped');
  end;

  // Clear all SSE connections
  EnterCriticalSection(fSSELock);
  try
    for i := 0 to High(fSSEConnections) do
      fSSEConnections[i].Active := False;
    fSSEConnectionCount := 0;
    SetLength(fSSEConnections, 0);
  finally
    LeaveCriticalSection(fSSELock);
  end;

  // Clear all sessions
  EnterCriticalSection(fSessionLock);
  try
    for i := 0 to High(fSessions) do
      fSessions[i].Active := False;
    fSessionCount := 0;
    SetLength(fSessions, 0);
  finally
    LeaveCriticalSection(fSessionLock);
  end;

  FreeAndNil(fHttpServer);
  fActive := False;
  fShuttingDown := False;
  TSynLog.Add.Log(sllInfo, 'MCP HTTP Transport stopped');
end;

function TMCPHttpTransport.GetAsyncServer: THttpAsyncServer;
begin
  if fHttpServer is THttpAsyncServer then
    Result := THttpAsyncServer(fHttpServer)
  else
    Result := nil;
end;

function TMCPHttpTransport.FormatSSEData(const JsonData: RawUtf8): RawUtf8;
begin
  // SSE format: data: {json}\n\n
  Result := 'data: ' + JsonData + #13#10#13#10;
end;

function TMCPHttpTransport.SendSSEToConnection(Handle: TConnectionAsyncHandle;
  const Data: RawUtf8): Boolean;
var
  AsyncServer: THttpAsyncServer;
  Connection: TAsyncConnection;
  SSEData: RawUtf8;
begin
  Result := False;
  AsyncServer := GetAsyncServer;
  if AsyncServer = nil then
    Exit;

  SSEData := FormatSSEData(Data);

  // Use the async connections to write directly to the socket
  try
    Connection := AsyncServer.Async.ConnectionFind(Handle);
    if Connection = nil then
    begin
      // Connection no longer exists - remove from tracking
      TSynLog.Add.Log(sllDebug, 'SSE connection #% no longer exists', [Handle]);
      RemoveSSEConnection(Handle);
      Exit;
    end;

    Result := AsyncServer.Async.WriteString(
      Connection,
      SSEData,
      1000  // 1 second timeout
    );
    if Result then
    begin
      UpdateSSELastSent(Handle);
      TSynLog.Add.Log(sllTrace, 'SSE sent to #%: %', [Handle, Data]);
    end
    else
    begin
      TSynLog.Add.Log(sllWarning, 'SSE send failed to #%', [Handle]);
      RemoveSSEConnection(Handle);
    end;
  except
    on E: Exception do
    begin
      TSynLog.Add.Log(sllError, 'SSE send exception to #%: %', [Handle, E.Message]);
      RemoveSSEConnection(Handle);
    end;
  end;
end;

function TMCPHttpTransport.AddSSEConnectionSlot(
  const Conn: TMCPSSEConnection): Boolean;
var
  i: Integer;
begin
  Result := False;
  EnterCriticalSection(fSSELock);
  try
    // Check if already exists
    for i := 0 to High(fSSEConnections) do
      if fSSEConnections[i].Active and
         (fSSEConnections[i].Handle = Conn.Handle) then
        Exit;

    // Check limit
    if fSSEConnectionCount >= MAX_SSE_CONNECTIONS then
    begin
      TSynLog.Add.Log(sllWarning, 'SSE connection limit reached (%)',
        [MAX_SSE_CONNECTIONS]);
      Exit;
    end;

    // Find empty slot or extend array
    for i := 0 to Length(fSSEConnections) do
    begin
      if i = Length(fSSEConnections) then
        SetLength(fSSEConnections, i + 1)
      else if fSSEConnections[i].Active then
        Continue;
      fSSEConnections[i] := Conn;
      fSSEConnections[i].ConnectedAt := Now;
      fSSEConnections[i].LastSentAt := GetTickCount64;
      fSSEConnections[i].Active := True;
      Inc(fSSEConnectionCount);
      Result := True;
      TSynLog.Add.Log(sllDebug, 'SSE connection added #% (total: %)',
        [Conn.Handle, fSSEConnectionCount]);
      Exit;
    end;
  finally
    LeaveCriticalSection(fSSELock);
  end;
end;

function TMCPHttpTransport.AddSSEConnection(Handle: TConnectionAsyncHandle;
  const SessionId: RawUtf8): Boolean;
var
  Conn: TMCPSSEConnection;
begin
  Finalize(Conn);
  FillCharFast(Conn, SizeOf(Conn), 0);
  Conn.Handle := Handle;
  Conn.SessionId := SessionId;
  Result := AddSSEConnectionSlot(Conn);
end;

function TMCPHttpTransport.AddSubscriptionConnection(
  Handle: TConnectionAsyncHandle; const SubscriptionId: Variant;
  AFilterTools, AFilterPrompts, AFilterResources: Boolean;
  const AFilterUris: TRawUtf8DynArray): Boolean;
var
  Conn: TMCPSSEConnection;
begin
  Finalize(Conn);
  FillCharFast(Conn, SizeOf(Conn), 0);
  Conn.Handle := Handle;
  Conn.IsSubscription := True;
  Conn.SubscriptionId := SubscriptionId;
  Conn.FilterTools := AFilterTools;
  Conn.FilterPrompts := AFilterPrompts;
  Conn.FilterResources := AFilterResources;
  Conn.FilterUris := AFilterUris;
  Result := AddSSEConnectionSlot(Conn);
end;

procedure TMCPHttpTransport.RemoveSSEConnection(Handle: TConnectionAsyncHandle);
var
  i: Integer;
begin
  EnterCriticalSection(fSSELock);
  try
    for i := 0 to High(fSSEConnections) do
      if fSSEConnections[i].Active and (fSSEConnections[i].Handle = Handle) then
      begin
        fSSEConnections[i].Active := False;
        fSSEConnections[i].Handle := 0;
        fSSEConnections[i].SessionId := '';
        Dec(fSSEConnectionCount);
        TSynLog.Add.Log(sllDebug, 'SSE connection removed #% (total: %)',
          [Handle, fSSEConnectionCount]);
        Exit;
      end;
  finally
    LeaveCriticalSection(fSSELock);
  end;
end;

procedure TMCPHttpTransport.SendNotification(const Method: RawUtf8;
  const Params: Variant);
begin
  // route through the filter-aware dispatcher (legacy streams get every
  // notification; subscriptions/listen streams only what they opted in to)
  BroadcastEvent(Method, Params);
end;

procedure TMCPHttpTransport.BroadcastEvent(const Method: RawUtf8;
  const Params: Variant);
var
  i, n: Integer;
  Targets: array of TMCPSSEConnection;
  LegacyJson, Uri: RawUtf8;
  Match: Boolean;
begin
  // snapshot active connections under lock (records are copied)
  EnterCriticalSection(fSSELock);
  try
    SetLength(Targets, fSSEConnectionCount);
    n := 0;
    for i := 0 to High(fSSEConnections) do
      if fSSEConnections[i].Active then
      begin
        Targets[n] := fSSEConnections[i];
        Inc(n);
      end;
  finally
    LeaveCriticalSection(fSSELock);
  end;

  if n = 0 then
  begin
    TSynLog.Add.Log(sllTrace, 'No SSE clients for notification %', [Method]);
    Exit;
  end;

  Uri := '';
  if Method = MCP_EVENT_RESOURCES_UPDATED then
    Uri := _Safe(Params)^.U['uri'];

  LegacyJson := '';
  TSynLog.Add.Log(sllDebug, 'Broadcasting notification % to % SSE clients',
    [Method, n]);
  for i := 0 to n - 1 do
    if Targets[i].IsSubscription then
    begin
      // 2026-07-28: only opted-in notification types, tagged with the
      // subscription id; request-scoped notifications (progress, message,
      // cancelled) MUST NOT flow on a subscriptions/listen stream
      Match := False;
      if Method = MCP_EVENT_TOOLS_LIST_CHANGED then
        Match := Targets[i].FilterTools
      else if Method = MCP_EVENT_PROMPTS_LIST_CHANGED then
        Match := Targets[i].FilterPrompts
      else if Method = MCP_EVENT_RESOURCES_LIST_CHANGED then
        Match := Targets[i].FilterResources
      else if Method = MCP_EVENT_RESOURCES_UPDATED then
        Match := (Uri <> '') and
          (FindRawUtf8(Targets[i].FilterUris, Uri) >= 0);
      if Match then
        SendSSEToConnection(Targets[i].Handle, BuildNotification(Method,
          AddSubscriptionMeta(Params, Targets[i].SubscriptionId)));
    end
    else
    begin
      if LegacyJson = '' then
        LegacyJson := BuildNotification(Method, Params);
      SendSSEToConnection(Targets[i].Handle, LegacyJson);
    end;
end;

function TMCPHttpTransport.GetHeader(Ctxt: THttpServerRequestAbstract;
  const HeaderName: RawUtf8): RawUtf8;
var
  UpperName: RawUtf8;
begin
  // FindNameValue expects the header name in uppercase with colon suffix
  // The second parameter is PAnsiChar, not RawUtf8
  UpperName := UpperCase(HeaderName) + ':';
  Result := '';
  FindNameValue(Ctxt.InHeaders, PAnsiChar(UpperName), Result);
end;

function TMCPHttpTransport.AcceptsSSE(Ctxt: THttpServerRequestAbstract): Boolean;
var
  Accept: RawUtf8;
begin
  Accept := GetHeader(Ctxt, 'Accept');
  Result := (Accept <> '') and
    (PosEx('text/event-stream', Accept) > 0);
end;

function TMCPHttpTransport.HandleGetSSE(Ctxt: THttpServerRequestAbstract): Cardinal;
begin
  // GET /mcp establishes an SSE stream for receiving server notifications
  // Per MCP spec: Response uses Content-Type: text/event-stream

  // Check if client accepts SSE
  if not AcceptsSSE(Ctxt) then
  begin
    // Return server info for non-SSE GET requests (backwards compatibility)
    Ctxt.OutContent := FormatUtf8(
      '{"url":"http://%:%","transport":"http","sse":true}',
      [fConfig.HttpHost, fConfig.HttpPort]);
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    Result := HTTP_OK;
    Exit;
  end;

  // Track the connection so event-bus notifications reach this stream
  AddSSEConnection(TConnectionAsyncHandle(Ctxt.ConnectionID),
    GetHeader(Ctxt, 'Mcp-Session-Id'));

  // Return SSE response
  Ctxt.OutContentType := SSE_CONTENT_TYPE;
  Ctxt.OutContent := ': sse accepted'#13#10#13#10;
  Ctxt.OutCustomHeaders := Ctxt.OutCustomHeaders +
    'Cache-Control: no-cache'#13#10'X-Accel-Buffering: no'#13#10;
  Result := HTTP_OK;
end;

function TMCPHttpTransport.HandleSubscriptionsListen(
  Ctxt: THttpServerRequestAbstract; const RequestDoc: Variant): Cardinal;
var
  ReqId, Params, Agreed, AckParams, Meta, UrisV: Variant;
  FilterDoc, UrisDoc: PDocVariantData;
  WantTools, WantPrompts, WantResources: Boolean;
  Uris: TRawUtf8DynArray;
  McpMethod: RawUtf8;
  i: PtrInt;
begin
  ReqId := TDocVariantData(RequestDoc).Value['id'];

  // SEP-2243: Mcp-Method header is required and must match the body method
  McpMethod := GetHeader(Ctxt, 'Mcp-Method');
  if McpMethod <> 'subscriptions/listen' then
  begin
    Ctxt.OutContent := CreateJsonRpcError(ReqId, JSONRPC_HEADER_MISMATCH,
      'Missing or mismatching Mcp-Method header for subscriptions/listen');
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    Result := HTTP_BAD_REQUEST;
    Exit;
  end;

  // requested filter - this server supports all four notification types,
  // so the agreed set simply echoes what the client opted in to
  WantTools := False;
  WantPrompts := False;
  WantResources := False;
  Uris := nil;
  Params := TDocVariantData(RequestDoc).Value['params'];
  FilterDoc := nil;
  if not VarIsEmptyOrNull(Params) then
    FilterDoc := _Safe(Params)^.O['notifications'];
  if FilterDoc <> nil then
  begin
    WantTools := FilterDoc^.B['toolsListChanged'];
    WantPrompts := FilterDoc^.B['promptsListChanged'];
    WantResources := FilterDoc^.B['resourcesListChanged'];
    UrisDoc := FilterDoc^.A['resourceSubscriptions'];
    if UrisDoc <> nil then
      UrisDoc^.ToRawUtf8DynArray(Uris);
  end;

  AddSubscriptionConnection(TConnectionAsyncHandle(Ctxt.ConnectionID),
    ReqId, WantTools, WantPrompts, WantResources, Uris);

  // the acknowledged notification MUST be the first message on the stream,
  // carrying the subscription id in _meta
  Agreed := _ObjFast([]); // stays an empty OBJECT when nothing was requested
  if WantTools then
    TDocVariantData(Agreed).B['toolsListChanged'] := True;
  if WantPrompts then
    TDocVariantData(Agreed).B['promptsListChanged'] := True;
  if WantResources then
    TDocVariantData(Agreed).B['resourcesListChanged'] := True;
  if Uris <> nil then
  begin
    TDocVariantData(UrisV).InitArray([], JSON_FAST);
    for i := 0 to High(Uris) do
      TDocVariantData(UrisV).AddItemText(Uris[i]);
    TDocVariantData(Agreed).AddValue('resourceSubscriptions', UrisV);
  end;
  TDocVariantData(Meta).InitFast;
  TDocVariantData(Meta).AddValue(MCP_META_SUBSCRIPTION_ID, ReqId);
  TDocVariantData(AckParams).InitFast;
  TDocVariantData(AckParams).AddValue('notifications', Agreed);
  TDocVariantData(AckParams).AddValue('_meta', Meta);

  Ctxt.OutContent := FormatSSEData(BuildNotification(
    'notifications/subscriptions/acknowledged', AckParams));
  Ctxt.OutContentType := SSE_CONTENT_TYPE;
  Ctxt.OutCustomHeaders := Ctxt.OutCustomHeaders +
    'Cache-Control: no-cache'#13#10'X-Accel-Buffering: no'#13#10;
  Result := HTTP_OK;

  TSynLog.Add.Log(sllInfo,
    'subscriptions/listen stream opened #% (tools=% prompts=% resources=% uris=%)',
    [Ctxt.ConnectionID, WantTools, WantPrompts, WantResources, Length(Uris)]);
end;

function TMCPHttpTransport.HandlePost(Ctxt: THttpServerRequestAbstract): Cardinal;
var
  IncomingSessionId: RawUtf8;
  ResponseBody: RawUtf8;
  RequestDoc, ResponseDoc: Variant;
  Method: RawUtf8;
  NewSessionId: RawUtf8;
  ProtocolVersion: RawUtf8;
  HeaderVersion, MetaVersion: RawUtf8;
  Ctx: TMCPRequestContext;
begin
  // Reject new requests during graceful shutdown
  if fShuttingDown then
  begin
    Ctxt.OutContent := CreateJsonRpcError(Null, JSONRPC_SERVER_ERROR,
      'Server is shutting down');
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    Result := HTTP_OK; // JSON-RPC errors return 200 with error in body
    TSynLog.Add.Log(sllDebug, 'Request rejected during shutdown');
    Exit;
  end;

  IncomingSessionId := GetHeader(Ctxt, 'Mcp-Session-Id');

  TSynLog.Add.Log(sllDebug, 'HTTP POST Request: %', [Ctxt.InContent]);

  // Parse the request to extract method
  try
    TDocVariantData(RequestDoc).InitJson(Ctxt.InContent, JSON_FAST_FLOAT);
    Method := TDocVariantData(RequestDoc).U['method'];
  except
    Method := '';
  end;

  // ---- modern era (2026-07-28+): stateless, no sessions ----
  // The request declares its version in _meta (authoritative) and/or the
  // MCP-Protocol-Version header; any Mcp-Session-Id header is ignored
  HeaderVersion := GetHeader(Ctxt, 'Mcp-Protocol-Version');
  MetaVersion := GetMetaProtocolVersion(
    TDocVariantData(RequestDoc).Value['params']);
  if IsModernProtocolVersion(MetaVersion) or
     ((MetaVersion = '') and IsModernProtocolVersion(HeaderVersion)) then
  begin
    if IdemPropNameU(Method, 'subscriptions/listen') then
    begin
      Result := HandleSubscriptionsListen(Ctxt, RequestDoc);
      Exit;
    end;
    InitRequestContext(Ctx);
    Ctx.IsHttp := True;
    Ctx.HeaderProtocolVersion := HeaderVersion;
    Ctx.HeaderMcpMethod := GetHeader(Ctxt, 'Mcp-Method');
    Ctx.HeaderMcpName := GetHeader(Ctxt, 'Mcp-Name');
    ResponseBody := ProcessRequestEx(Ctxt.InContent, Ctx);
    if ResponseBody = '' then
    begin
      // notifications are accepted with 202 and no body
      Result := HTTP_ACCEPTED_202;
      Exit;
    end;
    Ctxt.OutContent := ResponseBody;
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    if Ctx.HttpStatus <> 0 then
      Result := Ctx.HttpStatus
    else
      Result := HTTP_OK;
    TSynLog.Add.Log(sllDebug, 'HTTP Response (modern, status %): %',
      [Result, ResponseBody]);
    Exit;
  end;

  // ---- legacy eras (initialize handshake + sessions) ----
  // Validate session for methods that require it
  if RequiresSession(Method) then
  begin
    if IncomingSessionId = '' then
    begin
      TSynLog.Add.Log(sllWarning, 'Request without session ID for method: %', [Method]);
      Ctxt.OutContent := CreateJsonRpcError(
        TDocVariantData(RequestDoc).Value['id'],
        JSONRPC_INVALID_REQUEST,
        'Mcp-Session-Id header required');
      Ctxt.OutContentType := JSON_CONTENT_TYPE;
      Result := HTTP_OK;
      Exit;
    end;

    if not ValidateSession(IncomingSessionId) then
    begin
      TSynLog.Add.Log(sllWarning, 'Invalid session ID: %', [IncomingSessionId]);
      Ctxt.OutContent := CreateJsonRpcError(
        TDocVariantData(RequestDoc).Value['id'],
        JSONRPC_INVALID_REQUEST,
        'Invalid or expired session ID');
      Ctxt.OutContentType := JSON_CONTENT_TYPE;
      Result := HTTP_OK;
      Exit;
    end;

    // Update session activity
    TouchSession(IncomingSessionId);
  end;

  // Handle notifications/initialized - mark session as initialized
  if IdemPropNameU(Method, 'notifications/initialized') then
  begin
    if IncomingSessionId <> '' then
      SetSessionInitialized(IncomingSessionId);
    TSynLog.Add.Log(sllInfo, 'Session % initialized', [IncomingSessionId]);
    Result := HTTP_NO_CONTENT;
    Exit;
  end;

  ResponseBody := ProcessRequest(Ctxt.InContent, IncomingSessionId);

  if ResponseBody = '' then
  begin
    Result := HTTP_NO_CONTENT;
    Exit;
  end;

  // If this was an initialize request, register the session from the response
  if IdemPropNameU(Method, 'initialize') then
  begin
    try
      TDocVariantData(ResponseDoc).InitJson(ResponseBody, JSON_FAST_FLOAT);
      NewSessionId := TDocVariantData(ResponseDoc).O['result']^.U['sessionId'];
      ProtocolVersion := TDocVariantData(ResponseDoc).O['result']^.U['protocolVersion'];
      if NewSessionId <> '' then
      begin
        CreateSession(NewSessionId, ProtocolVersion);
        fSessionId := NewSessionId;
        TSynLog.Add.Log(sllInfo, 'Session created: %', [NewSessionId]);
      end;
    except
      // Ignore parsing errors, session may not be in response
    end;
  end;

  // Check if client accepts SSE for streaming response
  if AcceptsSSE(Ctxt) then
  begin
    // Return response as SSE event
    Ctxt.OutContent := FormatSSEData(ResponseBody);
    Ctxt.OutContentType := SSE_CONTENT_TYPE;
    Ctxt.OutCustomHeaders := 'Cache-Control: no-cache'#13#10;
  end
  else
  begin
    // Regular JSON response
    Ctxt.OutContent := ResponseBody;
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
  end;

  if fSessionId <> '' then
    Ctxt.OutCustomHeaders := Ctxt.OutCustomHeaders +
      FormatUtf8('Mcp-Session-Id: %'#13#10, [fSessionId]);

  TSynLog.Add.Log(sllDebug, 'HTTP Response: %', [ResponseBody]);

  Result := HTTP_OK;
end;

function TMCPHttpTransport.OnRequest(Ctxt: THttpServerRequestAbstract): Cardinal;
var
  Origin: RawUtf8;
  AllowedOrigin: RawUtf8;
  ProtocolVersion: RawUtf8;
  ErrorResponse: RawUtf8;
begin
  // Check endpoint
  if not IdemPropNameU(Ctxt.Url, fConfig.HttpEndpoint) then
  begin
    Ctxt.OutContent := '{"error":"Not Found"}';
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    Result := HTTP_NOT_FOUND;
    Exit;
  end;

  // Handle CORS
  if fConfig.CorsEnabled then
  begin
    Origin := GetHeader(Ctxt, 'Origin');
    if (Origin <> '') and not IsOriginAllowed(Origin) then
    begin
      Result := HTTP_FORBIDDEN;
      Exit;
    end;
    if fConfig.CorsAllowedOrigins = '*' then
      AllowedOrigin := '*'
    else if Origin <> '' then
      AllowedOrigin := Origin
    else
      AllowedOrigin := '*';
    SetCorsHeaders(Ctxt, AllowedOrigin);
  end;

  // Handle OPTIONS (CORS preflight)
  if Ctxt.Method = 'OPTIONS' then
  begin
    Result := HTTP_OK;
    Exit;
  end;

  // Validate protocol version for non-OPTIONS requests
  // MCP spec: Mcp-Protocol-Version header MUST be validated
  // If not provided, default to 2025-03-26
  if not ValidateProtocolVersion(Ctxt, ProtocolVersion, ErrorResponse) then
  begin
    Ctxt.OutContent := ErrorResponse;
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    Result := HTTP_BAD_REQUEST; // spec: unsupported version -> 400
    Exit;
  end;

  // 2026-07-28 removed the GET stream endpoint and protocol-level sessions:
  // a modern client sending GET or DELETE gets 405 Method Not Allowed;
  // legacy clients (no version header, or a pre-2026 version) keep the old
  // session/SSE behavior of the corresponding revision
  if ((Ctxt.Method = 'GET') or (Ctxt.Method = 'DELETE')) and
     IsModernProtocolVersion(GetHeader(Ctxt, 'Mcp-Protocol-Version')) then
  begin
    Result := HTTP_METHOD_NOT_ALLOWED;
    Exit;
  end;

  // Handle DELETE - terminate session (legacy eras)
  if Ctxt.Method = 'DELETE' then
  begin
    Result := HandleDelete(Ctxt);
    Exit;
  end;

  // Handle GET - SSE stream or server info (legacy eras)
  if Ctxt.Method = 'GET' then
  begin
    Result := HandleGetSSE(Ctxt);
    Exit;
  end;

  // Handle POST - JSON-RPC
  if Ctxt.Method = 'POST' then
  begin
    Result := HandlePost(Ctxt);
    Exit;
  end;

  Result := HTTP_METHOD_NOT_ALLOWED;
end;

procedure TMCPHttpTransport.SetCorsHeaders(Ctxt: THttpServerRequestAbstract;
  const AllowedOrigin: RawUtf8);
begin
  Ctxt.OutCustomHeaders := FormatUtf8(
    'Access-Control-Allow-Origin: %'#13#10 +
    'Access-Control-Allow-Methods: POST, GET, DELETE, OPTIONS'#13#10 +
    'Access-Control-Allow-Headers: Content-Type, Accept, Mcp-Session-Id, Mcp-Protocol-Version, Mcp-Method, Mcp-Name'#13#10 +
    'Access-Control-Expose-Headers: Mcp-Session-Id, Mcp-Protocol-Version'#13#10 +
    'Access-Control-Max-Age: 86400'#13#10,
    [AllowedOrigin]);
end;

function TMCPHttpTransport.IsOriginAllowed(const Origin: RawUtf8): Boolean;
var
  AllowedOrigins: TRawUtf8DynArray;
  i: PtrInt;
begin
  if fConfig.CorsAllowedOrigins = '*' then
  begin
    Result := True;
    Exit;
  end;

  CsvToRawUtf8DynArray(pointer(fConfig.CorsAllowedOrigins),
    AllowedOrigins, ',');

  for i := 0 to High(AllowedOrigins) do
    if IdemPropNameU(TrimU(AllowedOrigins[i]), Origin) then
    begin
      Result := True;
      Exit;
    end;

  Result := False;
end;

function TMCPHttpTransport.HandleDelete(Ctxt: THttpServerRequestAbstract): Cardinal;
var
  IncomingSessionId: RawUtf8;
begin
  IncomingSessionId := GetHeader(Ctxt, 'Mcp-Session-Id');

  if IncomingSessionId = '' then
  begin
    TSynLog.Add.Log(sllWarning, 'DELETE without session ID');
    Ctxt.OutContent := '{"error":"Mcp-Session-Id header required"}';
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    Result := HTTP_FORBIDDEN;
    Exit;
  end;

  if not ValidateSession(IncomingSessionId) then
  begin
    TSynLog.Add.Log(sllWarning, 'DELETE for invalid session: %', [IncomingSessionId]);
    Ctxt.OutContent := '{"error":"Invalid session ID"}';
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    Result := HTTP_NOT_FOUND;
    Exit;
  end;

  // Terminate the session
  if TerminateSession(IncomingSessionId) then
  begin
    TSynLog.Add.Log(sllInfo, 'Session terminated: %', [IncomingSessionId]);
    Ctxt.OutContent := '';
    Result := HTTP_NO_CONTENT;
  end
  else
  begin
    TSynLog.Add.Log(sllWarning, 'Failed to terminate session: %', [IncomingSessionId]);
    Ctxt.OutContent := '{"error":"Failed to terminate session"}';
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    Result := HTTP_INTERNAL_SERVER_ERROR;
  end;
end;

function TMCPHttpTransport.CreateSession(const SessionId: RawUtf8;
  const ProtocolVersion: RawUtf8): Boolean;
var
  i: Integer;
begin
  Result := False;

  if SessionId = '' then
    Exit;

  EnterCriticalSection(fSessionLock);
  try
    // Check if session already exists
    for i := 0 to High(fSessions) do
      if fSessions[i].Active and (fSessions[i].SessionId = SessionId) then
        Exit; // Already exists

    // Check limit
    if fSessionCount >= MAX_SESSIONS then
    begin
      TSynLog.Add.Log(sllWarning, 'Session limit reached (%)', [MAX_SESSIONS]);
      // Clean up expired sessions and try again
      CleanupExpiredSessions;
      if fSessionCount >= MAX_SESSIONS then
        Exit;
    end;

    // Find empty slot or extend array
    for i := 0 to High(fSessions) do
      if not fSessions[i].Active then
      begin
        fSessions[i].SessionId := SessionId;
        fSessions[i].ProtocolVersion := ProtocolVersion;
        fSessions[i].CreatedAt := Now;
        fSessions[i].LastActivityAt := Now;
        fSessions[i].Initialized := False;
        fSessions[i].Active := True;
        Inc(fSessionCount);
        Result := True;
        TSynLog.Add.Log(sllDebug, 'Session created: % (total: %)',
          [SessionId, fSessionCount]);
        Exit;
      end;

    // Extend array
    i := Length(fSessions);
    SetLength(fSessions, i + 1);
    fSessions[i].SessionId := SessionId;
    fSessions[i].ProtocolVersion := ProtocolVersion;
    fSessions[i].CreatedAt := Now;
    fSessions[i].LastActivityAt := Now;
    fSessions[i].Initialized := False;
    fSessions[i].Active := True;
    Inc(fSessionCount);
    Result := True;
    TSynLog.Add.Log(sllDebug, 'Session created: % (total: %)',
      [SessionId, fSessionCount]);
  finally
    LeaveCriticalSection(fSessionLock);
  end;
end;

function TMCPHttpTransport.FindSession(const SessionId: RawUtf8): Integer;
var
  i: Integer;
begin
  Result := -1;
  if SessionId = '' then
    Exit;

  // Note: Caller must hold fSessionLock
  for i := 0 to High(fSessions) do
    if fSessions[i].Active and (fSessions[i].SessionId = SessionId) then
    begin
      Result := i;
      Exit;
    end;
end;

function TMCPHttpTransport.ValidateSession(const SessionId: RawUtf8): Boolean;
var
  idx: Integer;
  ElapsedSeconds: Double;
begin
  Result := False;

  if SessionId = '' then
    Exit;

  EnterCriticalSection(fSessionLock);
  try
    idx := FindSession(SessionId);
    if idx < 0 then
      Exit;

    // Check if session has expired
    ElapsedSeconds := (Now - fSessions[idx].LastActivityAt) * 86400.0;
    if ElapsedSeconds > SESSION_TIMEOUT_SECONDS then
    begin
      TSynLog.Add.Log(sllInfo, 'Session expired: % (inactive for % seconds)',
        [SessionId, Round(ElapsedSeconds)]);
      fSessions[idx].Active := False;
      Dec(fSessionCount);
      RemoveSSEConnectionsForSession(SessionId);
      Exit;
    end;

    Result := True;
  finally
    LeaveCriticalSection(fSessionLock);
  end;
end;

procedure TMCPHttpTransport.SetSessionInitialized(const SessionId: RawUtf8);
var
  idx: Integer;
begin
  if SessionId = '' then
    Exit;

  EnterCriticalSection(fSessionLock);
  try
    idx := FindSession(SessionId);
    if idx >= 0 then
    begin
      fSessions[idx].Initialized := True;
      fSessions[idx].LastActivityAt := Now;
      TSynLog.Add.Log(sllDebug, 'Session marked as initialized: %', [SessionId]);
    end;
  finally
    LeaveCriticalSection(fSessionLock);
  end;
end;

procedure TMCPHttpTransport.TouchSession(const SessionId: RawUtf8);
var
  idx: Integer;
begin
  if SessionId = '' then
    Exit;

  EnterCriticalSection(fSessionLock);
  try
    idx := FindSession(SessionId);
    if idx >= 0 then
      fSessions[idx].LastActivityAt := Now;
  finally
    LeaveCriticalSection(fSessionLock);
  end;
end;

function TMCPHttpTransport.TerminateSession(const SessionId: RawUtf8): Boolean;
var
  idx: Integer;
begin
  Result := False;

  if SessionId = '' then
    Exit;

  EnterCriticalSection(fSessionLock);
  try
    idx := FindSession(SessionId);
    if idx < 0 then
      Exit;

    fSessions[idx].Active := False;
    fSessions[idx].SessionId := '';
    fSessions[idx].ProtocolVersion := '';
    Dec(fSessionCount);
    Result := True;
    TSynLog.Add.Log(sllDebug, 'Session terminated: % (remaining: %)',
      [SessionId, fSessionCount]);
  finally
    LeaveCriticalSection(fSessionLock);
  end;

  // Remove any SSE connections associated with this session
  if Result then
    RemoveSSEConnectionsForSession(SessionId);

  // Clear transport session ID if it matches
  if fSessionId = SessionId then
    fSessionId := '';
end;

procedure TMCPHttpTransport.RemoveSSEConnectionsForSession(const SessionId: RawUtf8);
var
  i: Integer;
  RemovedCount: Integer;
begin
  if SessionId = '' then
    Exit;

  RemovedCount := 0;
  EnterCriticalSection(fSSELock);
  try
    for i := 0 to High(fSSEConnections) do
      if fSSEConnections[i].Active and (fSSEConnections[i].SessionId = SessionId) then
      begin
        fSSEConnections[i].Active := False;
        fSSEConnections[i].Handle := 0;
        fSSEConnections[i].SessionId := '';
        Dec(fSSEConnectionCount);
        Inc(RemovedCount);
      end;
  finally
    LeaveCriticalSection(fSSELock);
  end;

  if RemovedCount > 0 then
    TSynLog.Add.Log(sllDebug, 'Removed % SSE connections for session %',
      [RemovedCount, SessionId]);
end;

procedure TMCPHttpTransport.CleanupExpiredSessions;
var
  i: Integer;
  ElapsedSeconds: Double;
  CleanedCount: Integer;
  CurrentTime: TDateTime;
begin
  // Note: Caller must hold fSessionLock
  CleanedCount := 0;
  CurrentTime := Now;

  for i := 0 to High(fSessions) do
    if fSessions[i].Active then
    begin
      ElapsedSeconds := (CurrentTime - fSessions[i].LastActivityAt) * 86400.0;
      if ElapsedSeconds > SESSION_TIMEOUT_SECONDS then
      begin
        TSynLog.Add.Log(sllDebug, 'Cleaning up expired session: %',
          [fSessions[i].SessionId]);
        RemoveSSEConnectionsForSession(fSessions[i].SessionId);
        fSessions[i].Active := False;
        fSessions[i].SessionId := '';
        Dec(fSessionCount);
        Inc(CleanedCount);
      end;
    end;

  if CleanedCount > 0 then
    TSynLog.Add.Log(sllInfo, 'Cleaned up % expired sessions', [CleanedCount]);
end;

function TMCPHttpTransport.RequiresSession(const Method: RawUtf8): Boolean;
begin
  // Initialize is the only method that doesn't require an existing session
  // notifications/initialized also doesn't require validation (it comes right after initialize)
  Result := (Method <> '') and
            not IdemPropNameU(Method, 'initialize') and
            not IdemPropNameU(Method, 'notifications/initialized');
end;

function TMCPHttpTransport.ValidateProtocolVersion(
  Ctxt: THttpServerRequestAbstract;
  out ProtocolVersion: RawUtf8;
  out ErrorResponse: RawUtf8): Boolean;
var
  HeaderVersion: RawUtf8;
begin
  Result := True;
  ErrorResponse := '';

  // Get protocol version from header
  HeaderVersion := GetHeader(Ctxt, 'Mcp-Protocol-Version');

  if HeaderVersion = '' then
  begin
    // No header provided - use default version per MCP spec
    ProtocolVersion := MCP_PROTOCOL_VERSION_DEFAULT;
    TSynLog.Add.Log(sllDebug,
      'No Mcp-Protocol-Version header, defaulting to %', [ProtocolVersion]);
  end
  else
  begin
    // Validate the provided version
    if IsSupportedProtocolVersion(HeaderVersion) then
    begin
      ProtocolVersion := HeaderVersion;
      TSynLog.Add.Log(sllDebug,
        'Mcp-Protocol-Version header: %', [ProtocolVersion]);
    end
    else
    begin
      // Unsupported version - 400 Bad Request with the spec error (-32022)
      // whose data lists the supported versions for client retry
      Result := False;
      ProtocolVersion := '';
      ErrorResponse := CreateUnsupportedVersionError(Null, HeaderVersion);
      TSynLog.Add.Log(sllWarning,
        'Unsupported Mcp-Protocol-Version: %', [HeaderVersion]);
    end;
  end;
end;

procedure TMCPHttpTransport.UpdateSSELastSent(Handle: TConnectionAsyncHandle);
var
  i: Integer;
begin
  EnterCriticalSection(fSSELock);
  try
    for i := 0 to High(fSSEConnections) do
      if fSSEConnections[i].Active and (fSSEConnections[i].Handle = Handle) then
      begin
        fSSEConnections[i].LastSentAt := GetTickCount64;
        Exit;
      end;
  finally
    LeaveCriticalSection(fSSELock);
  end;
end;

function TMCPHttpTransport.SendSSEKeepalive(Handle: TConnectionAsyncHandle): Boolean;
var
  AsyncServer: THttpAsyncServer;
  Connection: TAsyncConnection;
begin
  Result := False;
  AsyncServer := GetAsyncServer;
  if AsyncServer = nil then
    Exit;

  // Send SSE comment (keepalive ping)
  try
    Connection := AsyncServer.Async.ConnectionFind(Handle);
    if Connection = nil then
    begin
      // Connection no longer exists - remove from tracking
      TSynLog.Add.Log(sllDebug, 'SSE connection #% no longer exists, removing', [Handle]);
      RemoveSSEConnection(Handle);
      Exit;
    end;

    Result := AsyncServer.Async.WriteString(
      Connection,
      SSE_KEEPALIVE_COMMENT,
      1000  // 1 second timeout
    );
    if Result then
    begin
      UpdateSSELastSent(Handle);
      TSynLog.Add.Log(sllTrace, 'SSE keepalive sent to #%', [Handle]);
    end
    else
    begin
      TSynLog.Add.Log(sllDebug, 'SSE keepalive send failed to #%, removing', [Handle]);
      RemoveSSEConnection(Handle);
    end;
  except
    on E: Exception do
    begin
      TSynLog.Add.Log(sllDebug, 'SSE keepalive exception to #%: %',
        [Handle, E.Message]);
      RemoveSSEConnection(Handle);
    end;
  end;
end;

procedure TMCPHttpTransport.SendSSEKeepalives;
var
  i: Integer;
  CurrentTick: Int64;
  ElapsedMs: Int64;
  Handles: array of TConnectionAsyncHandle;
  HandleCount: Integer;
  SentCount: Integer;
begin
  if fShuttingDown then
    Exit;

  CurrentTick := GetTickCount64;

  // Collect handles that need keepalive under lock
  EnterCriticalSection(fSSELock);
  try
    SetLength(Handles, fSSEConnectionCount);
    HandleCount := 0;
    for i := 0 to High(fSSEConnections) do
      if fSSEConnections[i].Active then
      begin
        ElapsedMs := CurrentTick - fSSEConnections[i].LastSentAt;
        // Send keepalive if elapsed time >= interval
        if ElapsedMs >= fSSEKeepaliveIntervalMs then
        begin
          Handles[HandleCount] := fSSEConnections[i].Handle;
          Inc(HandleCount);
        end;
      end;
  finally
    LeaveCriticalSection(fSSELock);
  end;

  // Send keepalives outside lock to avoid deadlock
  SentCount := 0;
  for i := 0 to HandleCount - 1 do
    if SendSSEKeepalive(Handles[i]) then
      Inc(SentCount);

  if SentCount > 0 then
    TSynLog.Add.Log(sllDebug, 'SSE keepalive sent to % of % connections',
      [SentCount, HandleCount]);
end;

procedure TMCPHttpTransport.SendSubscriptionTeardowns;
var
  i, n: Integer;
  Targets: array of TMCPSSEConnection;
  Response, ResultV, Meta: Variant;
begin
  EnterCriticalSection(fSSELock);
  try
    SetLength(Targets, fSSEConnectionCount);
    n := 0;
    for i := 0 to High(fSSEConnections) do
      if fSSEConnections[i].Active and fSSEConnections[i].IsSubscription then
      begin
        Targets[n] := fSSEConnections[i];
        Inc(n);
      end;
  finally
    LeaveCriticalSection(fSSELock);
  end;

  for i := 0 to n - 1 do
  begin
    TDocVariantData(Meta).InitFast;
    TDocVariantData(Meta).AddValue(MCP_META_SUBSCRIPTION_ID,
      Targets[i].SubscriptionId);
    TDocVariantData(ResultV).InitFast;
    TDocVariantData(ResultV).U['resultType'] := 'complete';
    TDocVariantData(ResultV).AddValue('_meta', Meta);
    Response := CreateJsonRpcResponse(Targets[i].SubscriptionId);
    TDocVariantData(Response).AddValue('result', ResultV);
    SendSSEToConnection(Targets[i].Handle,
      TDocVariantData(Response).ToJson);
  end;

  if n > 0 then
    TSynLog.Add.Log(sllInfo,
      'Sent graceful teardown to % subscription streams', [n]);
end;

{ Event Bus Integration }

procedure TMCPHttpTransport.OnToolsListChanged(const Data: Variant);
begin
  SendNotification(MCP_EVENT_TOOLS_LIST_CHANGED, Data);
end;

procedure TMCPHttpTransport.OnResourcesListChanged(const Data: Variant);
begin
  SendNotification(MCP_EVENT_RESOURCES_LIST_CHANGED, Data);
end;

procedure TMCPHttpTransport.OnResourcesUpdated(const Data: Variant);
begin
  SendNotification(MCP_EVENT_RESOURCES_UPDATED, Data);
end;

procedure TMCPHttpTransport.OnPromptsListChanged(const Data: Variant);
begin
  SendNotification(MCP_EVENT_PROMPTS_LIST_CHANGED, Data);
end;

procedure TMCPHttpTransport.OnMessage(const Data: Variant);
begin
  SendNotification(MCP_EVENT_MESSAGE, Data);
end;

procedure TMCPHttpTransport.OnProgress(const Data: Variant);
begin
  SendNotification(MCP_EVENT_PROGRESS, Data);
end;

procedure TMCPHttpTransport.OnCancelled(const Data: Variant);
begin
  SendNotification(MCP_EVENT_CANCELLED, Data);
end;

procedure TMCPHttpTransport.SubscribeToEventBus;
var
  EventBus: TMCPEventBus;
begin
  EventBus := MCPEventBus;

  EventBus.Subscribe(MCP_EVENT_TOOLS_LIST_CHANGED, OnToolsListChanged);
  EventBus.Subscribe(MCP_EVENT_RESOURCES_LIST_CHANGED, OnResourcesListChanged);
  EventBus.Subscribe(MCP_EVENT_RESOURCES_UPDATED, OnResourcesUpdated);
  EventBus.Subscribe(MCP_EVENT_PROMPTS_LIST_CHANGED, OnPromptsListChanged);
  EventBus.Subscribe(MCP_EVENT_MESSAGE, OnMessage);
  EventBus.Subscribe(MCP_EVENT_PROGRESS, OnProgress);
  EventBus.Subscribe(MCP_EVENT_CANCELLED, OnCancelled);

  TSynLog.Add.Log(sllDebug, 'HTTP Transport subscribed to event bus notifications');
end;

procedure TMCPHttpTransport.UnsubscribeFromEventBus;
var
  EventBus: TMCPEventBus;
begin
  EventBus := MCPEventBus;

  EventBus.Unsubscribe(MCP_EVENT_TOOLS_LIST_CHANGED, OnToolsListChanged);
  EventBus.Unsubscribe(MCP_EVENT_RESOURCES_LIST_CHANGED, OnResourcesListChanged);
  EventBus.Unsubscribe(MCP_EVENT_RESOURCES_UPDATED, OnResourcesUpdated);
  EventBus.Unsubscribe(MCP_EVENT_PROMPTS_LIST_CHANGED, OnPromptsListChanged);
  EventBus.Unsubscribe(MCP_EVENT_MESSAGE, OnMessage);
  EventBus.Unsubscribe(MCP_EVENT_PROGRESS, OnProgress);
  EventBus.Unsubscribe(MCP_EVENT_CANCELLED, OnCancelled);

  TSynLog.Add.Log(sllDebug, 'HTTP Transport unsubscribed from event bus notifications');
end;

end.
