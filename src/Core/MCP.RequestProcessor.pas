/// MCP Request Processor
// - JSON-RPC dispatch shared by the Delphi (.dpr) and FPC (.lpr) entry points
// - Implements the dual-era protocol model:
//   legacy eras (2024-11-05 .. 2025-11-25): initialize handshake + sessions
//   modern era (2026-07-28+): stateless per-request _meta protocol version,
//   required resultType on results, serverInfo in result _meta, CacheableResult
//   hints, header/body validation for Streamable HTTP, spec error codes
unit MCP.RequestProcessor;

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
  mormot.core.log,
  mormot.core.rtti,
  MCP.Types,
  MCP.Manager.Resources;

type
  /// Processes JSON-RPC requests by dispatching to the manager registry
  // - Owns the protocol-era resolution: a request carrying a 2026-07-28+
  //   version in _meta (or the MCP-Protocol-Version header) is handled
  //   statelessly; anything else follows the legacy initialize/session flow
  TMCPRequestProcessor = class
  private
    fRegistry: IMCPManagerRegistry;
    fSettings: TMCPServerSettings;
    /// SEP-2243 header/body validation for modern-era HTTP requests
    // - returns False and fills ErrorJson with a HeaderMismatch (-32020) error
    function ValidateModernHttpRequest(const Ctx: TMCPRequestContext;
      const RequestId: Variant; const Method: RawUtf8;
      const Params: Variant; out ErrorJson: RawUtf8): Boolean;
    /// add resultType, _meta.serverInfo and CacheableResult hints to a result
    procedure DecorateModernResult(var MethodResult: Variant;
      const Method: RawUtf8);
  public
    constructor Create(ARegistry: IMCPManagerRegistry;
      const ASettings: TMCPServerSettings);
    /// legacy entry point (kept for embedders wiring SetRequestHandler)
    function HandleRequest(const RequestJson: RawUtf8;
      const SessionId: RawUtf8): RawUtf8;
    /// era-aware entry point - transports fill Ctx inputs, read Ctx outputs
    function HandleRequestEx(const RequestJson: RawUtf8;
      var Ctx: TMCPRequestContext): RawUtf8;
    property Registry: IMCPManagerRegistry read fRegistry;
  end;

/// True for RPC methods that no longer exist in the 2026-07-28 protocol
// - initialize/ping were removed with the stateless redesign (SEP-2575)
// - logging/setLevel was replaced by the per-request _meta logLevel key
// - resources/subscribe|unsubscribe were replaced by subscriptions/listen
function IsMethodRemovedInModern(const Method: RawUtf8): Boolean;

implementation

function IsMethodRemovedInModern(const Method: RawUtf8): Boolean;
begin
  Result := IdemPropNameU(Method, 'initialize') or
            IdemPropNameU(Method, 'ping') or
            IdemPropNameU(Method, 'logging/setLevel') or
            IdemPropNameU(Method, 'resources/subscribe') or
            IdemPropNameU(Method, 'resources/unsubscribe');
end;

{ TMCPRequestProcessor }

constructor TMCPRequestProcessor.Create(ARegistry: IMCPManagerRegistry;
  const ASettings: TMCPServerSettings);
begin
  inherited Create;
  fRegistry := ARegistry;
  fSettings := ASettings;
end;

function TMCPRequestProcessor.HandleRequest(const RequestJson: RawUtf8;
  const SessionId: RawUtf8): RawUtf8;
var
  Ctx: TMCPRequestContext;
begin
  InitRequestContext(Ctx);
  Ctx.SessionId := SessionId;
  Result := HandleRequestEx(RequestJson, Ctx);
end;

function TMCPRequestProcessor.ValidateModernHttpRequest(
  const Ctx: TMCPRequestContext; const RequestId: Variant;
  const Method: RawUtf8; const Params: Variant;
  out ErrorJson: RawUtf8): Boolean;
var
  Expected, Decoded: RawUtf8;
  NeedsName: Boolean;
begin
  Result := False;
  ErrorJson := '';
  // MCP-Protocol-Version header is REQUIRED on every modern POST
  if Ctx.HeaderProtocolVersion = '' then
  begin
    ErrorJson := CreateJsonRpcError(RequestId, JSONRPC_HEADER_MISMATCH,
      'Missing required MCP-Protocol-Version header');
    Exit;
  end;
  // Mcp-Method is REQUIRED and must match the body method (case-sensitive)
  if Ctx.HeaderMcpMethod = '' then
  begin
    ErrorJson := CreateJsonRpcError(RequestId, JSONRPC_HEADER_MISMATCH,
      'Missing required Mcp-Method header');
    Exit;
  end;
  if Ctx.HeaderMcpMethod <> Method then
  begin
    ErrorJson := CreateJsonRpcError(RequestId, JSONRPC_HEADER_MISMATCH,
      FormatUtf8('Header mismatch: Mcp-Method header value ''%'' does not ' +
        'match body value ''%''', [Ctx.HeaderMcpMethod, Method]));
    Exit;
  end;
  // Mcp-Name is REQUIRED for tools/call, prompts/get (params.name) and
  // resources/read (params.uri), possibly Base64-sentinel encoded
  NeedsName := True;
  if IdemPropNameU(Method, 'tools/call') or
     IdemPropNameU(Method, 'prompts/get') then
    Expected := _Safe(Params)^.U['name']
  else if IdemPropNameU(Method, 'resources/read') then
    Expected := _Safe(Params)^.U['uri']
  else
    NeedsName := False;
  if NeedsName then
  begin
    if Ctx.HeaderMcpName = '' then
    begin
      ErrorJson := CreateJsonRpcError(RequestId, JSONRPC_HEADER_MISMATCH,
        FormatUtf8('Missing required Mcp-Name header for %', [Method]));
      Exit;
    end;
    Decoded := DecodeMcpHeaderValue(Ctx.HeaderMcpName);
    if Decoded <> Expected then
    begin
      ErrorJson := CreateJsonRpcError(RequestId, JSONRPC_HEADER_MISMATCH,
        FormatUtf8('Header mismatch: Mcp-Name header value ''%'' does not ' +
          'match body value ''%''', [Decoded, Expected]));
      Exit;
    end;
  end;
  Result := True;
end;

procedure TMCPRequestProcessor.DecorateModernResult(var MethodResult: Variant;
  const Method: RawUtf8);
var
  Doc, MetaDoc: PDocVariantData;
  Meta, ServerInfo: Variant;
  MetaIdx: Integer;
  Cacheable: Boolean;
  TtlMs: Integer;
  Scope: RawUtf8;
begin
  Doc := _Safe(MethodResult);
  if not Doc^.IsObject then
    Exit;
  // resultType is REQUIRED on every 2026-07-28 result (SEP-2322)
  if Doc^.GetValueIndex('resultType') < 0 then
    Doc^.U['resultType'] := 'complete';
  // servers SHOULD identify themselves in each result's _meta (SEP-2575)
  TDocVariantData(ServerInfo).InitFast;
  TDocVariantData(ServerInfo).U['name'] := fSettings.ServerName;
  TDocVariantData(ServerInfo).U['version'] := fSettings.ServerVersion;
  MetaIdx := Doc^.GetValueIndex('_meta');
  if MetaIdx >= 0 then
  begin
    MetaDoc := _Safe(Doc^.Values[MetaIdx]);
    if MetaDoc^.GetValueIndex(MCP_META_SERVER_INFO) < 0 then
      MetaDoc^.AddValue(MCP_META_SERVER_INFO, ServerInfo);
  end
  else
  begin
    TDocVariantData(Meta).InitFast;
    TDocVariantData(Meta).AddValue(MCP_META_SERVER_INFO, ServerInfo);
    Doc^.AddValue('_meta', Meta);
  end;
  // CacheableResult hints are REQUIRED on list/read/discover results
  // (SEP-2549) - managers may set their own values, defaults added here
  Cacheable := True;
  TtlMs := MCP_CACHE_TTL_LIST_MS;
  Scope := MCP_CACHE_SCOPE_PUBLIC;
  if IdemPropNameU(Method, 'resources/read') then
  begin
    TtlMs := MCP_CACHE_TTL_READ_MS;
    Scope := MCP_CACHE_SCOPE_PRIVATE;
  end
  else if IdemPropNameU(Method, 'server/discover') then
    TtlMs := MCP_CACHE_TTL_DISCOVER_MS
  else if not (IdemPropNameU(Method, 'tools/list') or
               IdemPropNameU(Method, 'prompts/list') or
               IdemPropNameU(Method, 'resources/list') or
               IdemPropNameU(Method, 'resources/templates/list')) then
    Cacheable := False;
  if Cacheable then
  begin
    if Doc^.GetValueIndex('ttlMs') < 0 then
      Doc^.I['ttlMs'] := TtlMs;
    if Doc^.GetValueIndex('cacheScope') < 0 then
      Doc^.U['cacheScope'] := Scope;
  end;
end;

function TMCPRequestProcessor.HandleRequestEx(const RequestJson: RawUtf8;
  var Ctx: TMCPRequestContext): RawUtf8;
var
  Request, Response: Variant;
  RequestId: Variant;
  Method, MetaVersion: RawUtf8;
  Params: Variant;
  Manager: IMCPCapabilityManager;
  MethodResult: Variant;
  IsNotification: Boolean;
begin
  Result := '';
  Ctx.HttpStatus := 0;
  RequestId := Null;

  try
    TDocVariantData(Request).InitJson(RequestJson, JSON_FAST_FLOAT);
    RequestId := TDocVariantData(Request).Value['id'];
    Method := TDocVariantData(Request).U['method'];
    Params := TDocVariantData(Request).Value['params'];
    IsNotification := VarIsEmptyOrNull(RequestId);

    // ---- protocol era resolution (SEP-2575) ----
    MetaVersion := GetMetaProtocolVersion(Params);
    if Ctx.IsHttp and (Ctx.HeaderProtocolVersion <> '') and
       (MetaVersion <> '') and (Ctx.HeaderProtocolVersion <> MetaVersion) then
    begin
      Ctx.HttpStatus := HTTP_BADREQUEST;
      Result := CreateJsonRpcError(RequestId, JSONRPC_HEADER_MISMATCH,
        FormatUtf8('Header mismatch: MCP-Protocol-Version header value ''%'' ' +
          'does not match _meta value ''%''',
          [Ctx.HeaderProtocolVersion, MetaVersion]));
      Exit;
    end;
    if MetaVersion <> '' then
      Ctx.ProtocolVersion := MetaVersion
    else if Ctx.HeaderProtocolVersion <> '' then
      Ctx.ProtocolVersion := Ctx.HeaderProtocolVersion
    else
      Ctx.ProtocolVersion := MCP_PROTOCOL_VERSION_DEFAULT;
    Ctx.Modern := IsModernProtocolVersion(Ctx.ProtocolVersion);

    // version support gate - server/discover is always answered so clients
    // can probe the supported list without guessing a version first
    if not IdemPropNameU(Method, 'server/discover') and
       not IsSupportedProtocolVersion(Ctx.ProtocolVersion) then
    begin
      Ctx.HttpStatus := HTTP_BADREQUEST;
      Result := CreateUnsupportedVersionError(RequestId, Ctx.ProtocolVersion);
      Exit;
    end;

    // modern-era Streamable HTTP header/body validation (SEP-2243)
    if Ctx.Modern and Ctx.IsHttp then
      if not ValidateModernHttpRequest(Ctx, RequestId, Method, Params,
        Result) then
      begin
        Ctx.HttpStatus := HTTP_BADREQUEST;
        Exit;
      end;

    // legacy handshake notification (no response)
    if IdemPropNameU(Method, 'notifications/initialized') then
    begin
      TSynLog.Add.Log(sllInfo, 'MCP Initialized notification received');
      Exit;
    end;

    if fRegistry = nil then
    begin
      Result := CreateJsonRpcError(RequestId, JSONRPC_INTERNAL_ERROR,
        'Manager registry not initialized');
      Exit;
    end;

    // methods removed by 2026-07-28 are not visible to modern-era requests
    if Ctx.Modern and IsMethodRemovedInModern(Method) then
      Manager := nil
    else
      Manager := fRegistry.GetManagerForMethod(Method);
    if Manager = nil then
    begin
      if IsNotification then
        Exit; // unknown notifications are ignored, never answered
      if Ctx.Modern then
        Ctx.HttpStatus := HTTP_NOTFOUND;
      Result := CreateJsonRpcError(RequestId, JSONRPC_METHOD_NOT_FOUND,
        FormatUtf8('Method [%] not found', [Method]));
      Exit;
    end;

    MethodResult := Manager.ExecuteMethod(Method, Params);

    if IsNotification then
      Exit; // notifications MUST NOT be answered (JSON-RPC 2.0)

    if Ctx.Modern then
    begin
      if VarIsEmptyOrNull(MethodResult) then
        MethodResult := _ObjFast([]);
      DecorateModernResult(MethodResult, Method);
    end;

    Response := CreateJsonRpcResponse(RequestId);
    if not VarIsEmptyOrNull(MethodResult) then
      TDocVariantData(Response).AddValue('result', MethodResult);

    Result := TDocVariantData(Response).ToJson;

  except
    on E: EMCPResourceNotFound do
    begin
      TSynLog.Add.Log(sllWarning, 'Resource not found: %', [E.Message]);
      if Ctx.Modern then
        // 2026-07-28 aligned resource-not-found with JSON-RPC Invalid Params
        Result := CreateJsonRpcError(RequestId, JSONRPC_INVALID_PARAMS,
          StringToUtf8(E.Message))
      else
        Result := CreateJsonRpcError(RequestId, JSONRPC_RESOURCE_NOT_FOUND,
          StringToUtf8(E.Message));
    end;
    on E: Exception do
    begin
      TSynLog.Add.Log(sllError, 'Error processing request: %', [E.Message]);
      Result := CreateJsonRpcError(RequestId, JSONRPC_INTERNAL_ERROR,
        StringToUtf8(E.Message));
    end;
  end;
end;

end.
