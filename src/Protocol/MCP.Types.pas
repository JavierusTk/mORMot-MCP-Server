/// MCP Protocol Types using mORMot2 JSON
// - This unit defines core MCP types using TDocVariant for JSON handling
unit MCP.Types;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.rtti;

const
  /// MCP Protocol version supported by this server (latest)
  MCP_PROTOCOL_VERSION = '2026-07-28';

  /// First protocol revision using the stateless per-request model (SEP-2575)
  // - Requests negotiated at this version or later follow the "modern era":
  //   no initialize handshake, no sessions, per-request _meta version and
  //   capabilities, required resultType on results
  MCP_PROTOCOL_VERSION_MODERN = '2026-07-28';

  /// MCP Protocol version assumed when client doesn't provide a version header
  // - Per spec, servers MAY treat requests without MCP-Protocol-Version as
  //   2025-03-26 to support clients predating the header
  MCP_PROTOCOL_VERSION_DEFAULT = '2025-03-26';

  /// Supported MCP Protocol versions (comma-separated for validation)
  // - typed constant so it can be iterated as PUtf8Char
  MCP_SUPPORTED_VERSIONS: RawUtf8 = '2026-07-28,2025-11-25,2025-06-18,2025-03-26,2024-11-05';

  /// JSON-RPC 2.0 Error Codes
  JSONRPC_PARSE_ERROR      = -32700;
  JSONRPC_INVALID_REQUEST  = -32600;
  JSONRPC_METHOD_NOT_FOUND = -32601;
  JSONRPC_INVALID_PARAMS   = -32602;
  JSONRPC_INTERNAL_ERROR   = -32603;

  /// MCP-specific Error Codes
  JSONRPC_SERVER_ERROR     = -32000;
  JSONRPC_REQUEST_CANCELLED = -32800;
  /// resource not found - legacy code (2025-11-25 and earlier)
  // - 2026-07-28 replaced it by JSONRPC_INVALID_PARAMS (-32602); the old code
  //   remains reserved by the spec and is still returned to legacy-era clients
  JSONRPC_RESOURCE_NOT_FOUND = -32002;

  /// 2026-07-28 spec-reserved error codes (allocated from -32020 downward)
  // - HTTP headers do not match the request body, or required headers missing
  JSONRPC_HEADER_MISMATCH = -32020;
  // - server requires a client capability not declared in clientCapabilities
  JSONRPC_MISSING_CLIENT_CAPABILITY = -32021;
  // - the request's protocol version is not supported by this server
  JSONRPC_UNSUPPORTED_PROTOCOL_VERSION = -32022;

  /// reserved _meta keys of the 2026-07-28 stateless protocol
  MCP_META_PROTOCOL_VERSION    = 'io.modelcontextprotocol/protocolVersion';
  MCP_META_CLIENT_INFO         = 'io.modelcontextprotocol/clientInfo';
  MCP_META_CLIENT_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities';
  MCP_META_LOG_LEVEL           = 'io.modelcontextprotocol/logLevel';
  MCP_META_SERVER_INFO         = 'io.modelcontextprotocol/serverInfo';
  MCP_META_SUBSCRIPTION_ID     = 'io.modelcontextprotocol/subscriptionId';

  /// default CacheableResult hints (SEP-2549) emitted on modern-era results
  // - list endpoints: content changes are also signalled via listChanged, so a
  //   short TTL is a safe freshness hint
  MCP_CACHE_TTL_LIST_MS = 60000;
  // - server/discover: capabilities and supported versions are near-static
  MCP_CACHE_TTL_DISCOVER_MS = 300000;
  // - resources/read: content may be dynamic - immediately stale by default
  MCP_CACHE_TTL_READ_MS = 0;
  MCP_CACHE_SCOPE_PUBLIC: RawUtf8 = 'public';
  MCP_CACHE_SCOPE_PRIVATE: RawUtf8 = 'private';

type
  /// MCP-specific exception class
  EMCPError = class(Exception);

  /// Forward declarations
  IMCPCapabilityManager = interface;

  /// Interface for capability managers that handle MCP methods
  IMCPCapabilityManager = interface
    ['{E5F7C3A1-8B4D-4F6E-9C2A-1D3E5F7A9B8C}']
    /// Returns the name of this capability (e.g., 'core', 'tools', 'resources')
    function GetCapabilityName: RawUtf8;
    /// Returns True if this manager handles the given method
    function HandlesMethod(const Method: RawUtf8): Boolean;
    /// Executes the method with given parameters, returns result as variant
    function ExecuteMethod(const Method: RawUtf8; const Params: Variant): Variant;
  end;

  /// Interface for the manager registry
  IMCPManagerRegistry = interface
    ['{A2B4C6D8-1E3F-5A7B-9C8D-2F4E6A8C0B2D}']
    /// Register a capability manager
    procedure RegisterManager(const Manager: IMCPCapabilityManager);
    /// Get the manager that handles a specific method
    function GetManagerForMethod(const Method: RawUtf8): IMCPCapabilityManager;
  end;

  /// Thread-safe tracker for cancelled request IDs
  // - Used by servers to track which requests have been cancelled by clients
  // - Request IDs are stored as variants to support both string and integer IDs
  TMCPCancelledRequests = class
  private
    fLock: TRTLCriticalSection;
    fCancelled: array of Variant;
    fReasons: array of RawUtf8;
  public
    constructor Create;
    destructor Destroy; override;
    /// Add a request ID to the cancelled set
    // - RequestId: The ID of the request to cancel (string or integer)
    // - Reason: Optional reason for cancellation
    procedure AddCancelledRequest(const RequestId: Variant; const Reason: RawUtf8 = '');
    /// Check if a request has been cancelled
    // - Returns True if the request ID is in the cancelled set
    function IsCancelled(const RequestId: Variant): Boolean;
    /// Remove a request ID from the cancelled set (called after handling)
    procedure RemoveCancelledRequest(const RequestId: Variant);
    /// Get the reason for a cancelled request
    function GetCancellationReason(const RequestId: Variant): RawUtf8;
    /// Clear all cancelled requests
    procedure Clear;
    /// Get count of cancelled requests
    function GetCount: Integer;
  end;

  /// Per-request context exchanged between a transport and the processor
  // - The transport fills the input fields (HTTP headers, legacy session);
  //   the request processor resolves the protocol era and suggests an HTTP
  //   status code for the response (2026-07-28 mandates 400/404 for some
  //   protocol-level errors)
  TMCPRequestContext = record
    /// True when the request arrived over HTTP (header fields are meaningful)
    IsHttp: Boolean;
    /// MCP-Protocol-Version header value ('' when absent or non-HTTP)
    HeaderProtocolVersion: RawUtf8;
    /// Mcp-Method header value ('' when absent)
    HeaderMcpMethod: RawUtf8;
    /// Mcp-Name header value, still sentinel-encoded ('' when absent)
    HeaderMcpName: RawUtf8;
    /// legacy session id (initialize-based eras only)
    SessionId: RawUtf8;
    /// OUT: effective protocol version resolved for this request
    ProtocolVersion: RawUtf8;
    /// OUT: True when the request follows the stateless 2026-07-28+ model
    Modern: Boolean;
    /// OUT: suggested HTTP status for the response (0 = transport default)
    HttpStatus: Integer;
  end;

  /// MCP Server settings
  TMCPServerSettings = record
    /// Server name reported to clients
    ServerName: RawUtf8;
    /// Server version reported to clients
    ServerVersion: RawUtf8;
    /// Port to listen on
    Port: Word;
    /// Host/bind address
    Host: RawUtf8;
    /// MCP endpoint path (e.g., '/mcp')
    Endpoint: RawUtf8;
    /// Enable SSL/TLS
    SSLEnabled: Boolean;
    /// Path to SSL certificate file
    SSLCertFile: RawUtf8;
    /// Path to SSL private key file
    SSLKeyFile: RawUtf8;
    /// Password for SSL private key (if encrypted)
    SSLKeyPassword: RawUtf8;
    /// Use self-signed certificate (auto-generate if no cert files provided)
    SSLSelfSigned: Boolean;
    /// Enable CORS
    CorsEnabled: Boolean;
    /// Allowed CORS origins ('*' for all)
    CorsAllowedOrigins: RawUtf8;
    /// SSE keepalive interval in milliseconds (0 = disabled, default 30000)
    SSEKeepaliveIntervalMs: Cardinal;
    /// Optional free-text usage hint returned to clients in the initialize
    /// result (MCP 'instructions' field). Empty = omitted. Domain-specific
    /// hosts set this to guide clients on how to use their tools effectively.
    Instructions: RawUtf8;
    /// Optional JSON object merged into the initialize result's
    /// capabilities.experimental field. Empty = omitted. Host apps set this
    /// to advertise non-standard capabilities (e.g. '{"claude/channel":{}}')
    /// without the generic framework having to know about them.
    ExperimentalCapabilities: RawUtf8;
  end;

/// Initialize default MCP server settings
procedure InitDefaultSettings(out Settings: TMCPServerSettings);

/// Create a JSON-RPC 2.0 response object
function CreateJsonRpcResponse(const RequestId: Variant): Variant;

/// Create a JSON-RPC 2.0 error response
function CreateJsonRpcError(const RequestId: Variant;
  ErrorCode: Integer; const ErrorMessage: RawUtf8): RawUtf8;

/// Check if a protocol version is supported
function IsSupportedProtocolVersion(const Version: RawUtf8): Boolean;

/// True when Version uses the stateless 2026-07-28+ protocol model
// - ISO date version strings compare correctly as plain bytes
function IsModernProtocolVersion(const Version: RawUtf8): Boolean;

/// Supported protocol versions as a TDocVariant array
// - used by server/discover and UnsupportedProtocolVersionError data
function SupportedProtocolVersionsArray: Variant;

/// Create a JSON-RPC 2.0 error response with an additional data payload
function CreateJsonRpcErrorWithData(const RequestId: Variant;
  ErrorCode: Integer; const ErrorMessage: RawUtf8;
  const Data: Variant): RawUtf8;

/// Build an UnsupportedProtocolVersionError (-32022) response
// - data carries {supported, requested} so the client can retry with a
//   mutually supported version
function CreateUnsupportedVersionError(const RequestId: Variant;
  const Requested: RawUtf8): RawUtf8;

/// Decode the '=?base64?...?=' sentinel format of Mcp-Name / Mcp-Param-*
// HTTP header values (2026-07-28 Streamable HTTP value encoding)
// - returns the value unchanged when it does not carry the sentinel markers
function DecodeMcpHeaderValue(const Value: RawUtf8): RawUtf8;

/// Return the _meta object of a request's params, or nil if absent
function GetRequestMeta(const Params: Variant): PDocVariantData;

/// Return _meta['io.modelcontextprotocol/protocolVersion'] ('' if absent)
function GetMetaProtocolVersion(const Params: Variant): RawUtf8;

/// Initialize a request context with non-HTTP defaults
procedure InitRequestContext(out Ctx: TMCPRequestContext);

/// Compare two JSON-RPC request ids (string or integer variants)
function MCPRequestIdEquals(const V1, V2: Variant): Boolean;

/// Build a copy of notification params carrying the subscription id in _meta
// - notifications delivered on a subscriptions/listen stream MUST carry
//   'io.modelcontextprotocol/subscriptionId'; the copy avoids mutating the
//   shared event-bus payload
function AddSubscriptionMeta(const Params: Variant;
  const SubscriptionId: Variant): Variant;

implementation

{ TMCPCancelledRequests }

constructor TMCPCancelledRequests.Create;
begin
  inherited Create;
  InitializeCriticalSection(fLock);
  SetLength(fCancelled, 0);
  SetLength(fReasons, 0);
end;

destructor TMCPCancelledRequests.Destroy;
begin
  EnterCriticalSection(fLock);
  try
    SetLength(fCancelled, 0);
    SetLength(fReasons, 0);
  finally
    LeaveCriticalSection(fLock);
  end;
  DeleteCriticalSection(fLock);
  inherited;
end;

function MCPRequestIdEquals(const V1, V2: Variant): Boolean;
begin
  // Compare variants handling both string and integer IDs
  Result := (VarType(V1) = VarType(V2)) and (V1 = V2);
end;

procedure TMCPCancelledRequests.AddCancelledRequest(const RequestId: Variant;
  const Reason: RawUtf8);
var
  i, n: PtrInt;
begin
  if VarIsEmptyOrNull(RequestId) then
    Exit;

  EnterCriticalSection(fLock);
  try
    // Check if already in list
    for i := 0 to High(fCancelled) do
      if MCPRequestIdEquals(fCancelled[i], RequestId) then
        Exit;

    // Add to list
    n := Length(fCancelled);
    SetLength(fCancelled, n + 1);
    SetLength(fReasons, n + 1);
    fCancelled[n] := RequestId;
    fReasons[n] := Reason;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TMCPCancelledRequests.IsCancelled(const RequestId: Variant): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if VarIsEmptyOrNull(RequestId) then
    Exit;

  EnterCriticalSection(fLock);
  try
    for i := 0 to High(fCancelled) do
      if MCPRequestIdEquals(fCancelled[i], RequestId) then
      begin
        Result := True;
        Exit;
      end;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

procedure TMCPCancelledRequests.RemoveCancelledRequest(const RequestId: Variant);
var
  i: PtrInt;
begin
  if VarIsEmptyOrNull(RequestId) then
    Exit;

  EnterCriticalSection(fLock);
  try
    for i := High(fCancelled) downto 0 do
      if MCPRequestIdEquals(fCancelled[i], RequestId) then
      begin
        // Remove by shifting
        if i < High(fCancelled) then
        begin
          Move(fCancelled[i + 1], fCancelled[i],
            (High(fCancelled) - i) * SizeOf(Variant));
          Move(fReasons[i + 1], fReasons[i],
            (High(fReasons) - i) * SizeOf(RawUtf8));
        end;
        SetLength(fCancelled, Length(fCancelled) - 1);
        SetLength(fReasons, Length(fReasons) - 1);
        Exit;
      end;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TMCPCancelledRequests.GetCancellationReason(const RequestId: Variant): RawUtf8;
var
  i: PtrInt;
begin
  Result := '';
  if VarIsEmptyOrNull(RequestId) then
    Exit;

  EnterCriticalSection(fLock);
  try
    for i := 0 to High(fCancelled) do
      if MCPRequestIdEquals(fCancelled[i], RequestId) then
      begin
        Result := fReasons[i];
        Exit;
      end;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

procedure TMCPCancelledRequests.Clear;
begin
  EnterCriticalSection(fLock);
  try
    SetLength(fCancelled, 0);
    SetLength(fReasons, 0);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TMCPCancelledRequests.GetCount: Integer;
begin
  EnterCriticalSection(fLock);
  try
    Result := Length(fCancelled);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

procedure InitDefaultSettings(out Settings: TMCPServerSettings);
begin
  Settings.ServerName := 'mORMot-MCP-Server';
  Settings.ServerVersion := '1.0.0';
  Settings.Port := 3000;
  Settings.Host := '0.0.0.0';
  Settings.Endpoint := '/mcp';
  Settings.SSLEnabled := False;
  Settings.SSLCertFile := '';
  Settings.SSLKeyFile := '';
  Settings.SSLKeyPassword := '';
  Settings.SSLSelfSigned := False;
  Settings.CorsEnabled := True;
  Settings.CorsAllowedOrigins := '*';
  Settings.SSEKeepaliveIntervalMs := 30000; // 30 seconds default
  Settings.Instructions := ''; // omitted from initialize unless set by host app
  Settings.ExperimentalCapabilities := ''; // omitted unless set by host app
end;

function CreateJsonRpcResponse(const RequestId: Variant): Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['jsonrpc'] := '2.0';
  if not VarIsEmptyOrNull(RequestId) then
    TDocVariantData(Result).AddValue('id', RequestId);
end;

function CreateJsonRpcError(const RequestId: Variant;
  ErrorCode: Integer; const ErrorMessage: RawUtf8): RawUtf8;
var
  Response, Error: Variant;
begin
  TDocVariantData(Response).InitFast;
  TDocVariantData(Response).S['jsonrpc'] := '2.0';
  if not VarIsEmptyOrNull(RequestId) then
    TDocVariantData(Response).AddValue('id', RequestId);

  TDocVariantData(Error).InitFast;
  TDocVariantData(Error).I['code'] := ErrorCode;
  TDocVariantData(Error).U['message'] := ErrorMessage;
  TDocVariantData(Response).AddValue('error', Error);

  Result := TDocVariantData(Response).ToJson;
end;

function IsSupportedProtocolVersion(const Version: RawUtf8): Boolean;
var
  p: PUtf8Char;
  v: RawUtf8;
begin
  Result := False;
  if Version = '' then
    Exit;
  p := pointer(MCP_SUPPORTED_VERSIONS);
  while p <> nil do
  begin
    GetNextItem(p, ',', v);
    if v = Version then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function IsModernProtocolVersion(const Version: RawUtf8): Boolean;
begin
  // ISO 'YYYY-MM-DD' version strings order correctly as plain bytes
  Result := (Version <> '') and (Version >= MCP_PROTOCOL_VERSION_MODERN);
end;

function SupportedProtocolVersionsArray: Variant;
var
  p: PUtf8Char;
  v: RawUtf8;
begin
  TDocVariantData(Result).InitArray([], JSON_FAST);
  p := pointer(MCP_SUPPORTED_VERSIONS);
  while p <> nil do
  begin
    GetNextItem(p, ',', v);
    TDocVariantData(Result).AddItemText(v);
  end;
end;

function CreateJsonRpcErrorWithData(const RequestId: Variant;
  ErrorCode: Integer; const ErrorMessage: RawUtf8;
  const Data: Variant): RawUtf8;
var
  Response, Error: Variant;
begin
  TDocVariantData(Response).InitFast;
  TDocVariantData(Response).S['jsonrpc'] := '2.0';
  if not VarIsEmptyOrNull(RequestId) then
    TDocVariantData(Response).AddValue('id', RequestId);
  TDocVariantData(Error).InitFast;
  TDocVariantData(Error).I['code'] := ErrorCode;
  TDocVariantData(Error).U['message'] := ErrorMessage;
  if not VarIsEmptyOrNull(Data) then
    TDocVariantData(Error).AddValue('data', Data);
  TDocVariantData(Response).AddValue('error', Error);
  Result := TDocVariantData(Response).ToJson;
end;

function CreateUnsupportedVersionError(const RequestId: Variant;
  const Requested: RawUtf8): RawUtf8;
var
  Data: Variant;
begin
  TDocVariantData(Data).InitFast;
  TDocVariantData(Data).AddValue('supported', SupportedProtocolVersionsArray);
  TDocVariantData(Data).U['requested'] := Requested;
  Result := CreateJsonRpcErrorWithData(RequestId,
    JSONRPC_UNSUPPORTED_PROTOCOL_VERSION,
    FormatUtf8('Unsupported protocol version: %', [Requested]), Data);
end;

function DecodeMcpHeaderValue(const Value: RawUtf8): RawUtf8;
const
  B64_PREFIX = '=?base64?';
  B64_SUFFIX = '?=';
var
  Decoded: RawByteString;
begin
  // markers are case-sensitive lowercase per spec
  if (Length(Value) > Length(B64_PREFIX) + Length(B64_SUFFIX)) and
     (Copy(Value, 1, Length(B64_PREFIX)) = B64_PREFIX) and
     (Copy(Value, Length(Value) - Length(B64_SUFFIX) + 1, Length(B64_SUFFIX)) =
       B64_SUFFIX) then
  begin
    Decoded := Base64ToBinSafe(
      Copy(Value, Length(B64_PREFIX) + 1,
        Length(Value) - Length(B64_PREFIX) - Length(B64_SUFFIX)));
    Result := RawUtf8(Decoded);
  end
  else
    Result := Value;
end;

function GetRequestMeta(const Params: Variant): PDocVariantData;
begin
  Result := nil;
  if VarIsEmptyOrNull(Params) then
    Exit;
  Result := _Safe(Params)^.O['_meta'];
end;

function GetMetaProtocolVersion(const Params: Variant): RawUtf8;
var
  Meta: PDocVariantData;
begin
  Result := '';
  Meta := GetRequestMeta(Params);
  if Meta <> nil then
    Result := Meta^.U[MCP_META_PROTOCOL_VERSION];
end;

function AddSubscriptionMeta(const Params: Variant;
  const SubscriptionId: Variant): Variant;
var
  Meta: Variant;
begin
  if VarIsEmptyOrNull(Params) then
    TDocVariantData(Result).InitFast
  else
    Result := _CopyFast(Params);
  TDocVariantData(Meta).InitFast;
  TDocVariantData(Meta).AddValue(MCP_META_SUBSCRIPTION_ID, SubscriptionId);
  _Safe(Result)^.AddOrUpdateValue('_meta', Meta);
end;

procedure InitRequestContext(out Ctx: TMCPRequestContext);
begin
  Ctx.IsHttp := False;
  Ctx.HeaderProtocolVersion := '';
  Ctx.HeaderMcpMethod := '';
  Ctx.HeaderMcpName := '';
  Ctx.SessionId := '';
  Ctx.ProtocolVersion := '';
  Ctx.Modern := False;
  Ctx.HttpStatus := 0;
end;

end.
