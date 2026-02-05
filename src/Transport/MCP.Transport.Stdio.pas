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
  MCP.Transport.Base;

type
  /// Stdio Transport for MCP server
  // - Reads JSON-RPC messages from stdin, writes responses to stdout
  // - Messages are newline-delimited JSON
  // - Logs are written to stderr to avoid interfering with the protocol
  // - Handles SIGTERM/SIGINT with graceful shutdown (5s timeout for pending requests)
  TMCPStdioTransport = class(TMCPTransportBase)
  private
    /// Read a line from stdin
    function ReadLine: RawUtf8;
    /// Write a line to stdout (JSON-RPC responses)
    procedure WriteLine(const Line: RawUtf8);
    /// Write a log message to stderr (NOT stdout)
    procedure LogToStderr(const Msg: RawUtf8);
    /// Process incoming messages in a loop
    procedure ProcessLoop;
    /// Wait for pending requests to complete (for graceful shutdown)
    // - Returns True if all requests completed within timeout
    function WaitForPendingRequests(TimeoutMs: Cardinal): Boolean;
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
end;

destructor TMCPStdioTransport.Destroy;
begin
  if fActive then
    Stop;
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
  WriteLn(Utf8ToString(Line));
  Flush(Output);
end;

procedure TMCPStdioTransport.LogToStderr(const Msg: RawUtf8);
begin
  // Write log to stderr to avoid interfering with JSON-RPC protocol on stdout
  // MCP clients expect only JSON-RPC messages on stdout; logs go to stderr
  WriteLn(ErrOutput, '[MCP] ', Utf8ToString(Msg));
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

  // For stdio, we run the processing in the main thread
  // This blocks until EOF is received on stdin or shutdown signal
  LogToStderr('Starting stdio transport (graceful shutdown enabled)');
  ProcessLoop;
end;

procedure TMCPStdioTransport.Stop;
begin
  if fActive then
  begin
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

end.
