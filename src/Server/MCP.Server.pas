/// MCP HTTP Server using mORMot2 THttpAsyncServer
// - High-performance HTTP server for MCP protocol
unit MCP.Server;

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
  MCP.Types;

type
  /// MCP HTTP Server using mORMot's THttpAsyncServer
  TMCPHttpServer = class
  private
    fHttpServer: THttpServerSocketGeneric;
    fManagerRegistry: IMCPManagerRegistry;
    fSettings: TMCPServerSettings;
    fSessionId: RawUtf8;
    fActive: Boolean;

    /// Main request handler
    function OnRequest(Ctxt: THttpServerRequestAbstract): Cardinal;
    /// Process JSON-RPC request
    function ProcessJsonRpc(const RequestBody: RawUtf8;
      const SessionId: RawUtf8): RawUtf8;
    /// Handle CORS preflight
    procedure SetCorsHeaders(Ctxt: THttpServerRequestAbstract;
      const AllowedOrigin: RawUtf8);
    /// Check if CORS origin is allowed
    function IsOriginAllowed(const Origin: RawUtf8): Boolean;
    /// Extract header value from InHeaders
    function GetHeader(Ctxt: THttpServerRequestAbstract;
      const HeaderName: RawUtf8): RawUtf8;
  public
    /// Create the MCP server with given settings
    constructor Create(const ASettings: TMCPServerSettings);
    /// Destroy the server
    destructor Destroy; override;
    /// Start listening for connections
    procedure Start;
    /// Stop the server
    procedure Stop;
    /// Manager registry for handling MCP methods
    property ManagerRegistry: IMCPManagerRegistry
      read fManagerRegistry write fManagerRegistry;
    /// Server settings
    property Settings: TMCPServerSettings read fSettings;
    /// Whether the server is active
    property Active: Boolean read fActive;
  end;

implementation

uses
  mormot.core.datetime;

const
  HTTP_OK = 200;
  HTTP_NO_CONTENT = 204;
  HTTP_NOT_FOUND = 404;
  HTTP_METHOD_NOT_ALLOWED = 405;
  HTTP_FORBIDDEN = 403;

{ TMCPHttpServer }

constructor TMCPHttpServer.Create(const ASettings: TMCPServerSettings);
begin
  inherited Create;
  fSettings := ASettings;
  fActive := False;
  fSessionId := '';
end;

destructor TMCPHttpServer.Destroy;
begin
  if fActive then
    Stop;
  inherited;
end;

procedure TMCPHttpServer.Start;
var
  Port: RawUtf8;
begin
  if fActive then
    Exit;

  // Port as string
  Port := UInt32ToUtf8(fSettings.Port);

  // Create async HTTP server
  fHttpServer := THttpAsyncServer.Create(
    Port,
    nil,  // OnStart
    nil,  // OnStop
    'MCP Server',
    SystemInfo.dwNumberOfProcessors + 1,  // Thread count
    30000,  // Keep-alive timeout (ms)
    [hsoNoXPoweredHeader]
  );

  fHttpServer.OnRequest := OnRequest;

  // Start and wait for binding
  fHttpServer.WaitStarted;
  fActive := True;

  TSynLog.Add.Log(sllInfo, 'MCP Server started on http://%:%',
    [fSettings.Host, fSettings.Port]);
end;

procedure TMCPHttpServer.Stop;
begin
  if not fActive then
    Exit;

  FreeAndNil(fHttpServer);
  fActive := False;
  TSynLog.Add.Log(sllInfo, 'MCP Server stopped');
end;

function TMCPHttpServer.GetHeader(Ctxt: THttpServerRequestAbstract;
  const HeaderName: RawUtf8): RawUtf8;
var
  UpperName: RawUtf8;
begin
  UpperName := UpperCase(HeaderName) + ': ';
  FindNameValue(Ctxt.InHeaders, pointer(UpperName), Result, False, ':');
end;

function TMCPHttpServer.OnRequest(Ctxt: THttpServerRequestAbstract): Cardinal;
var
  Origin: RawUtf8;
  AllowedOrigin: RawUtf8;
  ResponseBody: RawUtf8;
  SessionId: RawUtf8;
begin
  // Check endpoint
  if not IdemPropNameU(Ctxt.Url, fSettings.Endpoint) then
  begin
    Ctxt.OutContent := '{"error":"Not Found"}';
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    Result := HTTP_NOT_FOUND;
    Exit;
  end;

  // Handle CORS
  if fSettings.CorsEnabled then
  begin
    Origin := GetHeader(Ctxt, 'Origin');
    if (Origin <> '') and not IsOriginAllowed(Origin) then
    begin
      Result := HTTP_FORBIDDEN;
      Exit;
    end;
    if fSettings.CorsAllowedOrigins = '*' then
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

  // Handle GET - return server info
  if Ctxt.Method = 'GET' then
  begin
    Ctxt.OutContent := FormatUtf8(
      '{"url":"http://%:%","transport":"http"}',
      [fSettings.Host, fSettings.Port]);
    Ctxt.OutContentType := JSON_CONTENT_TYPE;
    Result := HTTP_OK;
    Exit;
  end;

  // Handle POST - JSON-RPC
  if Ctxt.Method = 'POST' then
  begin
    SessionId := GetHeader(Ctxt, 'Mcp-Session-Id');

    TSynLog.Add.Log(sllDebug, 'Request: %', [Ctxt.InContent]);

    ResponseBody := ProcessJsonRpc(Ctxt.InContent, SessionId);

    if ResponseBody = '' then
    begin
      Result := HTTP_NO_CONTENT;
      Exit;
    end;

    Ctxt.OutContent := ResponseBody;
    Ctxt.OutContentType := JSON_CONTENT_TYPE;

    // Set session ID header
    if fSessionId <> '' then
      Ctxt.OutCustomHeaders := FormatUtf8('%Mcp-Session-Id: %',
        [Ctxt.OutCustomHeaders, fSessionId]);

    TSynLog.Add.Log(sllDebug, 'Response: %', [ResponseBody]);

    Result := HTTP_OK;
    Exit;
  end;

  // Other methods not allowed
  Result := HTTP_METHOD_NOT_ALLOWED;
end;

function TMCPHttpServer.ProcessJsonRpc(const RequestBody: RawUtf8;
  const SessionId: RawUtf8): RawUtf8;
var
  Request, Response: Variant;
  RequestId: Variant;
  Method: RawUtf8;
  Params: Variant;
  Manager: IMCPCapabilityManager;
  MethodResult: Variant;
begin
  Result := '';

  try
    // Parse JSON request
    TDocVariantData(Request).InitJson(RequestBody, JSON_FAST_FLOAT);

    // Extract request ID
    RequestId := TDocVariantData(Request).Value['id'];

    // Extract method
    Method := TDocVariantData(Request).U['method'];

    // Handle notifications (no response needed)
    if Method = 'notifications/initialized' then
    begin
      TSynLog.Add.Log(sllInfo, 'MCP Initialized notification received');
      Exit;
    end;

    // Check for manager registry
    if fManagerRegistry = nil then
    begin
      Result := CreateJsonRpcError(RequestId, JSONRPC_INTERNAL_ERROR,
        'Manager registry not initialized');
      Exit;
    end;

    // Find manager for method
    Manager := fManagerRegistry.GetManagerForMethod(Method);
    if Manager = nil then
    begin
      Result := CreateJsonRpcError(RequestId, JSONRPC_METHOD_NOT_FOUND,
        FormatUtf8('Method [%] not found', [Method]));
      Exit;
    end;

    // Extract parameters
    Params := TDocVariantData(Request).Value['params'];

    // Execute method
    MethodResult := Manager.ExecuteMethod(Method, Params);

    // Check if initialize returned a session ID
    if (Method = 'initialize') and not VarIsEmptyOrNull(MethodResult) then
    begin
      fSessionId := TDocVariantData(MethodResult).U['sessionId'];
    end;

    // Build response
    Response := CreateJsonRpcResponse(RequestId);
    if not VarIsEmptyOrNull(MethodResult) then
      TDocVariantData(Response).AddValue('result', MethodResult);

    Result := TDocVariantData(Response).ToJson;

  except
    on E: Exception do
    begin
      TSynLog.Add.Log(sllError, 'Error processing request: %', [E.Message]);
      Result := CreateJsonRpcError(RequestId, JSONRPC_INTERNAL_ERROR,
        StringToUtf8(E.Message));
    end;
  end;
end;

procedure TMCPHttpServer.SetCorsHeaders(Ctxt: THttpServerRequestAbstract;
  const AllowedOrigin: RawUtf8);
begin
  Ctxt.OutCustomHeaders := FormatUtf8(
    'Access-Control-Allow-Origin: %'#13#10 +
    'Access-Control-Allow-Methods: POST, GET, OPTIONS'#13#10 +
    'Access-Control-Allow-Headers: Content-Type, Mcp-Session-Id'#13#10 +
    'Access-Control-Max-Age: 86400',
    [AllowedOrigin]);
end;

function TMCPHttpServer.IsOriginAllowed(const Origin: RawUtf8): Boolean;
var
  AllowedOrigins: TRawUtf8DynArray;
  i: PtrInt;
begin
  if fSettings.CorsAllowedOrigins = '*' then
  begin
    Result := True;
    Exit;
  end;

  CsvToRawUtf8DynArray(pointer(fSettings.CorsAllowedOrigins),
    AllowedOrigins, ',');

  for i := 0 to High(AllowedOrigins) do
    if IdemPropNameU(TrimU(AllowedOrigins[i]), Origin) then
    begin
      Result := True;
      Exit;
    end;

  Result := False;
end;

end.
