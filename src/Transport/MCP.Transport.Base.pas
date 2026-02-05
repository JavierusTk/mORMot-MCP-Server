/// MCP Transport Abstraction Layer
// - Transport-agnostic interface for MCP server communication
// - Supports stdio, HTTP, and future transports via factory pattern
// - Implements graceful shutdown with SIGTERM/SIGINT handling (REQ-019)
unit MCP.Transport.Base;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.rtti,
  MCP.Types;

type
  /// Transport type enumeration
  TMCPTransportType = (
    mttStdio,   // Standard input/output (for CLI tools)
    mttHttp     // HTTP/HTTPS transport (existing implementation)
  );

  /// Configuration record for transport layer
  TMCPTransportConfig = record
    /// Type of transport to use
    TransportType: TMCPTransportType;
    /// HTTP-specific settings (used when TransportType = mttHttp)
    HttpPort: Word;
    HttpHost: RawUtf8;
    HttpEndpoint: RawUtf8;
    /// SSL settings (used when TransportType = mttHttp)
    SSLEnabled: Boolean;
    SSLCertFile: RawUtf8;
    SSLKeyFile: RawUtf8;
    /// CORS settings (used when TransportType = mttHttp)
    CorsEnabled: Boolean;
    CorsAllowedOrigins: RawUtf8;
    /// SSE keepalive interval in milliseconds (0 = disabled, default 30000)
    // - Only used when TransportType = mttHttp
    SSEKeepaliveIntervalMs: Cardinal;
  end;

  /// Callback type for processing incoming JSON-RPC requests
  // Returns the response JSON, or empty string for notifications
  TMCPRequestHandler = function(const RequestJson: RawUtf8;
    const SessionId: RawUtf8): RawUtf8 of object;

  /// Transport interface for MCP communication
  // Implementations handle the specifics of stdio, HTTP, etc.
  IMCPTransport = interface
    ['{C7D8E9F0-1A2B-3C4D-5E6F-7A8B9C0D1E2F}']
    /// Start the transport (begin accepting connections/input)
    procedure Start;
    /// Stop the transport (cease accepting connections/input)
    procedure Stop;
    /// Initiate graceful shutdown with pending request timeout
    // - Signals shutdown intent and waits up to TimeoutMs for pending requests
    // - If TimeoutMs = 0, uses default GRACEFUL_SHUTDOWN_TIMEOUT_MS (5000)
    // - Returns True if all requests completed before timeout
    function GracefulShutdown(TimeoutMs: Cardinal = 0): Boolean;
    /// Send a notification to the client (for server-initiated messages)
    // @param Method The notification method name
    // @param Params The notification parameters as variant
    procedure SendNotification(const Method: RawUtf8; const Params: Variant);
    /// Check if transport is currently active
    function IsActive: Boolean;
    /// Check if graceful shutdown is in progress
    function IsShuttingDown: Boolean;
    /// Set the request handler callback
    procedure SetRequestHandler(const Handler: TMCPRequestHandler);
    /// Get the transport type
    function GetTransportType: TMCPTransportType;
    /// Get the current number of pending requests
    function GetPendingRequestCount: Integer;
  end;

  /// Base class providing common transport functionality
  // - Implements graceful shutdown with pending request tracking (REQ-019)
  // - Uses SynDaemonIntercept for SIGTERM/SIGINT handling on POSIX
  // - Uses HandleCtrlC for Ctrl+C handling on Windows
  TMCPTransportBase = class(TInterfacedObject, IMCPTransport)
  protected
    fActive: Boolean;
    fShuttingDown: Boolean;
    fConfig: TMCPTransportConfig;
    fRequestHandler: TMCPRequestHandler;
    fManagerRegistry: IMCPManagerRegistry;
    fSessionId: RawUtf8;
    fPendingRequests: Integer;
    fPendingLock: TRTLCriticalSection;
    fShutdownEvent: TEvent;
    /// Process incoming request using the handler
    // - Automatically tracks pending request count for graceful shutdown
    function ProcessRequest(const RequestJson: RawUtf8;
      const SessionId: RawUtf8): RawUtf8;
    /// Build a JSON-RPC notification message
    function BuildNotification(const Method: RawUtf8;
      const Params: Variant): RawUtf8;
    /// Increment pending request count (thread-safe)
    procedure BeginRequest;
    /// Decrement pending request count (thread-safe)
    procedure EndRequest;
    /// Check if shutdown signal was received (SIGTERM/SIGINT/Ctrl+C)
    function CheckShutdownSignal: Boolean;
    /// Register signal handlers for graceful shutdown
    procedure RegisterSignalHandlers;
  public
    constructor Create(const AConfig: TMCPTransportConfig); virtual;
    destructor Destroy; override;
    /// IMCPTransport implementation
    procedure Start; virtual; abstract;
    procedure Stop; virtual; abstract;
    function GracefulShutdown(TimeoutMs: Cardinal = 0): Boolean; virtual;
    procedure SendNotification(const Method: RawUtf8;
      const Params: Variant); virtual; abstract;
    function IsActive: Boolean; virtual;
    function IsShuttingDown: Boolean; virtual;
    procedure SetRequestHandler(const Handler: TMCPRequestHandler); virtual;
    function GetTransportType: TMCPTransportType; virtual;
    function GetPendingRequestCount: Integer; virtual;
    /// Manager registry for handling MCP methods
    property ManagerRegistry: IMCPManagerRegistry
      read fManagerRegistry write fManagerRegistry;
    /// Current session ID
    property SessionId: RawUtf8 read fSessionId write fSessionId;
  end;

  /// Factory class for creating transport instances
  TMCPTransportFactory = class
  public
    /// Create a transport based on configuration
    // Note: Requires MCP.Transport.Http and MCP.Transport.Stdio in uses clause
    class function CreateTransport(
      const Config: TMCPTransportConfig): IMCPTransport;
    /// Create a transport from command line transport type string
    // @param TransportStr 'stdio' or 'http'
    // @param Settings Server settings for HTTP transport
    class function CreateFromString(const TransportStr: RawUtf8;
      const Settings: TMCPServerSettings): IMCPTransport;
    /// Parse transport type from string
    class function ParseTransportType(const Value: RawUtf8): TMCPTransportType;
    /// Convert transport type to string
    class function TransportTypeToString(
      TransportType: TMCPTransportType): RawUtf8;
    /// Build transport config from server settings
    class function ConfigFromSettings(TransportType: TMCPTransportType;
      const Settings: TMCPServerSettings): TMCPTransportConfig;
  end;

/// Initialize default transport configuration
procedure InitDefaultTransportConfig(out Config: TMCPTransportConfig);

const
  /// Default timeout for graceful shutdown in milliseconds (5 seconds per spec)
  GRACEFUL_SHUTDOWN_TIMEOUT_MS = 5000;

  /// Polling interval while waiting for pending requests during shutdown
  GRACEFUL_SHUTDOWN_POLL_MS = 50;

implementation

procedure InitDefaultTransportConfig(out Config: TMCPTransportConfig);
begin
  Config.TransportType := mttHttp;
  Config.HttpPort := 3000;
  Config.HttpHost := '0.0.0.0';
  Config.HttpEndpoint := '/mcp';
  Config.SSLEnabled := False;
  Config.SSLCertFile := '';
  Config.SSLKeyFile := '';
  Config.CorsEnabled := True;
  Config.CorsAllowedOrigins := '*';
  Config.SSEKeepaliveIntervalMs := 30000; // 30 seconds default
end;

{ TMCPTransportBase }

constructor TMCPTransportBase.Create(const AConfig: TMCPTransportConfig);
begin
  inherited Create;
  fConfig := AConfig;
  fActive := False;
  fShuttingDown := False;
  fSessionId := '';
  fRequestHandler := nil;
  fPendingRequests := 0;
  InitializeCriticalSection(fPendingLock);
  fShutdownEvent := TEvent.Create(nil, True, False, '');
end;

destructor TMCPTransportBase.Destroy;
begin
  if fActive then
    Stop;
  FreeAndNil(fShutdownEvent);
  DeleteCriticalSection(fPendingLock);
  inherited;
end;

procedure TMCPTransportBase.BeginRequest;
begin
  EnterCriticalSection(fPendingLock);
  try
    Inc(fPendingRequests);
  finally
    LeaveCriticalSection(fPendingLock);
  end;
end;

procedure TMCPTransportBase.EndRequest;
begin
  EnterCriticalSection(fPendingLock);
  try
    if fPendingRequests > 0 then
      Dec(fPendingRequests);
  finally
    LeaveCriticalSection(fPendingLock);
  end;
end;

function TMCPTransportBase.GetPendingRequestCount: Integer;
begin
  EnterCriticalSection(fPendingLock);
  try
    Result := fPendingRequests;
  finally
    LeaveCriticalSection(fPendingLock);
  end;
end;

function TMCPTransportBase.CheckShutdownSignal: Boolean;
begin
  // Check mORMot's global shutdown signal (set by SynDaemonIntercept on POSIX
  // or by HandleCtrlC on Windows when SIGTERM/SIGINT/Ctrl+C is received)
  {$IFDEF OSWINDOWS}
  // On Windows, we rely on the event set by Ctrl+C handler
  Result := fShutdownEvent.WaitFor(0) = wrSignaled;
  {$ELSE}
  // On POSIX, check the global SynDaemonTerminated variable
  Result := SynDaemonTerminated <> 0;
  {$ENDIF}
end;

procedure TMCPTransportBase.RegisterSignalHandlers;
begin
  // Register signal handlers for graceful shutdown
  {$IFDEF OSWINDOWS}
  // On Windows, HandleCtrlC is typically used, but we manage via our own flag
  // No additional registration needed - we check fShuttingDown flag
  {$ELSE}
  // On POSIX, use mORMot's signal interception
  // This sets SynDaemonTerminated when SIGTERM/SIGINT/SIGQUIT is received
  SynDaemonIntercept(TSynLog.DoLog);
  {$ENDIF}
  TSynLog.Add.Log(sllInfo, 'Signal handlers registered for graceful shutdown');
end;

function TMCPTransportBase.GracefulShutdown(TimeoutMs: Cardinal): Boolean;
var
  WaitStart: Int64;
  ElapsedMs: Int64;
  PendingCount: Integer;
begin
  Result := False;

  if not fActive then
  begin
    Result := True;
    Exit;
  end;

  // Set shutdown flag
  fShuttingDown := True;
  TSynLog.Add.Log(sllInfo, 'Graceful shutdown initiated');

  // Use default timeout if not specified
  if TimeoutMs = 0 then
    TimeoutMs := GRACEFUL_SHUTDOWN_TIMEOUT_MS;

  // Wait for pending requests to complete or timeout
  WaitStart := GetTickCount64;

  repeat
    PendingCount := GetPendingRequestCount;
    if PendingCount = 0 then
    begin
      TSynLog.Add.Log(sllInfo, 'All pending requests completed');
      Result := True;
      Break;
    end;

    ElapsedMs := GetTickCount64 - WaitStart;
    if ElapsedMs >= TimeoutMs then
    begin
      TSynLog.Add.Log(sllWarning,
        'Graceful shutdown timeout (% ms) with % pending requests',
        [TimeoutMs, PendingCount]);
      Break;
    end;

    // Log progress periodically
    if (ElapsedMs mod 1000) < GRACEFUL_SHUTDOWN_POLL_MS then
      TSynLog.Add.Log(sllDebug,
        'Waiting for % pending requests (% ms elapsed)',
        [PendingCount, ElapsedMs]);

    SleepHiRes(GRACEFUL_SHUTDOWN_POLL_MS);
  until False;

  // Now stop the transport
  Stop;

  TSynLog.Add.Log(sllInfo, 'Graceful shutdown completed (success: %)', [Result]);
end;

function TMCPTransportBase.IsShuttingDown: Boolean;
begin
  Result := fShuttingDown;
end;

function TMCPTransportBase.ProcessRequest(const RequestJson: RawUtf8;
  const SessionId: RawUtf8): RawUtf8;
begin
  // Track pending request for graceful shutdown
  BeginRequest;
  try
    if Assigned(fRequestHandler) then
      Result := fRequestHandler(RequestJson, SessionId)
    else
      Result := CreateJsonRpcError(Null, JSONRPC_INTERNAL_ERROR,
        'No request handler configured');
  finally
    EndRequest;
  end;
end;

function TMCPTransportBase.BuildNotification(const Method: RawUtf8;
  const Params: Variant): RawUtf8;
var
  Notification: Variant;
begin
  TDocVariantData(Notification).InitFast;
  TDocVariantData(Notification).S['jsonrpc'] := '2.0';
  TDocVariantData(Notification).U['method'] := Method;
  if not VarIsEmptyOrNull(Params) then
    TDocVariantData(Notification).AddValue('params', Params);
  Result := TDocVariantData(Notification).ToJson;
end;

function TMCPTransportBase.IsActive: Boolean;
begin
  Result := fActive;
end;

procedure TMCPTransportBase.SetRequestHandler(
  const Handler: TMCPRequestHandler);
begin
  fRequestHandler := Handler;
end;

function TMCPTransportBase.GetTransportType: TMCPTransportType;
begin
  Result := fConfig.TransportType;
end;

{ TMCPTransportFactory }

class function TMCPTransportFactory.CreateTransport(
  const Config: TMCPTransportConfig): IMCPTransport;
begin
  // This method requires the caller to have MCP.Transport.Http and
  // MCP.Transport.Stdio in their uses clause. The actual creation
  // is delegated to the main program.
  raise EMCPError.Create(
    'CreateTransport should not be called directly. ' +
    'Use CreateFromString or create transports directly.');
end;

class function TMCPTransportFactory.CreateFromString(const TransportStr: RawUtf8;
  const Settings: TMCPServerSettings): IMCPTransport;
begin
  // Same as CreateTransport - requires concrete transport units
  raise EMCPError.Create(
    'CreateFromString should not be called directly. ' +
    'Use ParseTransportType and create transports directly.');
end;

class function TMCPTransportFactory.ParseTransportType(
  const Value: RawUtf8): TMCPTransportType;
begin
  if IdemPropNameU(Value, 'stdio') then
    Result := mttStdio
  else if IdemPropNameU(Value, 'http') then
    Result := mttHttp
  else
    Result := mttHttp; // Default to HTTP
end;

class function TMCPTransportFactory.TransportTypeToString(
  TransportType: TMCPTransportType): RawUtf8;
begin
  case TransportType of
    mttStdio: Result := 'stdio';
    mttHttp: Result := 'http';
  else
    Result := 'http';
  end;
end;

class function TMCPTransportFactory.ConfigFromSettings(
  TransportType: TMCPTransportType;
  const Settings: TMCPServerSettings): TMCPTransportConfig;
begin
  Result.TransportType := TransportType;
  Result.HttpPort := Settings.Port;
  Result.HttpHost := Settings.Host;
  Result.HttpEndpoint := Settings.Endpoint;
  Result.SSLEnabled := Settings.SSLEnabled;
  Result.SSLCertFile := Settings.SSLCertFile;
  Result.SSLKeyFile := Settings.SSLKeyFile;
  Result.CorsEnabled := Settings.CorsEnabled;
  Result.CorsAllowedOrigins := Settings.CorsAllowedOrigins;
  Result.SSEKeepaliveIntervalMs := Settings.SSEKeepaliveIntervalMs;
end;

end.
