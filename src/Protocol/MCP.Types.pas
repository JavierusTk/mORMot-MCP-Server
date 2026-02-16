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
  mormot.core.variants,
  mormot.core.json,
  mormot.core.rtti;

const
  /// MCP Protocol version supported by this server (latest)
  MCP_PROTOCOL_VERSION = '2025-06-18';

  /// MCP Protocol version assumed when client doesn't provide a version header
  MCP_PROTOCOL_VERSION_DEFAULT = '2025-03-26';

  /// Supported MCP Protocol versions (comma-separated for validation)
  MCP_SUPPORTED_VERSIONS = '2025-06-18,2025-03-26';

  /// JSON-RPC 2.0 Error Codes
  JSONRPC_PARSE_ERROR      = -32700;
  JSONRPC_INVALID_REQUEST  = -32600;
  JSONRPC_METHOD_NOT_FOUND = -32601;
  JSONRPC_INVALID_PARAMS   = -32602;
  JSONRPC_INTERNAL_ERROR   = -32603;

  /// MCP-specific Error Codes
  JSONRPC_SERVER_ERROR     = -32000;
  JSONRPC_REQUEST_CANCELLED = -32800;
  JSONRPC_RESOURCE_NOT_FOUND = -32002;

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
    /// Enable CORS
    CorsEnabled: Boolean;
    /// Allowed CORS origins ('*' for all)
    CorsAllowedOrigins: RawUtf8;
    /// SSE keepalive interval in milliseconds (0 = disabled, default 30000)
    SSEKeepaliveIntervalMs: Cardinal;
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

function VariantEquals(const V1, V2: Variant): Boolean;
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
      if VariantEquals(fCancelled[i], RequestId) then
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
      if VariantEquals(fCancelled[i], RequestId) then
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
      if VariantEquals(fCancelled[i], RequestId) then
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
      if VariantEquals(fCancelled[i], RequestId) then
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
  Settings.CorsEnabled := True;
  Settings.CorsAllowedOrigins := '*';
  Settings.SSEKeepaliveIntervalMs := 30000; // 30 seconds default
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
begin
  // Check if version matches one of the supported versions
  Result := (Version <> '') and
    (IdemPropNameU(Version, MCP_PROTOCOL_VERSION) or
     IdemPropNameU(Version, MCP_PROTOCOL_VERSION_DEFAULT));
end;

end.
