/// MCP Core Manager
// - Handles initialize, ping, and other core MCP methods
unit MCP.Manager.Core;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.rtti,
  mormot.crypt.core,
  MCP.Types;

type
  /// Custom exception for MCP errors
  EMCPError = class(ESynException);

  /// Core capability manager for MCP protocol
  TMCPCoreManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    fSettings: TMCPServerSettings;
    fSessionId: RawUtf8;
    fCancelledRequests: TMCPCancelledRequests;
  public
    constructor Create(const ASettings: TMCPServerSettings);
    destructor Destroy; override;
    /// IMCPCapabilityManager implementation
    function GetCapabilityName: RawUtf8;
    function HandlesMethod(const Method: RawUtf8): Boolean;
    function ExecuteMethod(const Method: RawUtf8; const Params: Variant): Variant;
    /// Core methods
    function Initialize(const Params: Variant): Variant;
    function Ping: Variant;
    /// Handle cancellation notification
    procedure HandleCancellation(const Params: Variant);
    /// Current session ID
    property SessionId: RawUtf8 read fSessionId;
    /// Access to cancelled requests tracker
    property CancelledRequests: TMCPCancelledRequests read fCancelledRequests;
  end;

implementation

uses
  mormot.core.datetime,
  MCP.Events;

{ TMCPCoreManager }

constructor TMCPCoreManager.Create(const ASettings: TMCPServerSettings);
begin
  inherited Create;
  fSettings := ASettings;
  fSessionId := '';
  fCancelledRequests := TMCPCancelledRequests.Create;
end;

destructor TMCPCoreManager.Destroy;
begin
  FreeAndNil(fCancelledRequests);
  inherited;
end;

function TMCPCoreManager.GetCapabilityName: RawUtf8;
begin
  Result := 'core';
end;

function TMCPCoreManager.HandlesMethod(const Method: RawUtf8): Boolean;
begin
  Result := IdemPropNameU(Method, 'initialize') or
            IdemPropNameU(Method, 'notifications/initialized') or
            IdemPropNameU(Method, 'notifications/cancelled') or
            IdemPropNameU(Method, 'ping');
end;

function TMCPCoreManager.ExecuteMethod(const Method: RawUtf8;
  const Params: Variant): Variant;
begin
  if IdemPropNameU(Method, 'initialize') then
    Result := Initialize(Params)
  else if IdemPropNameU(Method, 'notifications/initialized') then
  begin
    TSynLog.Add.Log(sllInfo, 'MCP Initialized notification received');
    VarClear(Result);
  end
  else if IdemPropNameU(Method, 'notifications/cancelled') then
  begin
    HandleCancellation(Params);
    VarClear(Result);
  end
  else if IdemPropNameU(Method, 'ping') then
    Result := Ping
  else
    raise EMCPError.CreateFmt('Method %s not handled by %s',
      [Method, GetCapabilityName]);
end;

function TMCPCoreManager.Initialize(const Params: Variant): Variant;
var
  ParamsDoc, ClientInfo: PDocVariantData;
  ClientName, ClientVersion: RawUtf8;
  Capabilities, Tools, Resources, Prompts, Logging, Completions, ServerInfo: Variant;
begin
  TSynLog.Add.Log(sllInfo, 'MCP Initialize called');

  // Extract client info if present
  if not VarIsEmptyOrNull(Params) then
  begin
    ParamsDoc := _Safe(Params);
    ClientInfo := ParamsDoc^.O['clientInfo'];
    if ClientInfo <> nil then
    begin
      ClientName := ClientInfo^.U['name'];
      ClientVersion := ClientInfo^.U['version'];
      if (ClientName <> '') and (ClientVersion <> '') then
        TSynLog.Add.Log(sllInfo, 'Client: % v%', [ClientName, ClientVersion]);
    end;
  end;

  // Generate cryptographically secure session ID (128 bits of entropy)
  // Using TAesPrng for cryptographic random number generation
  fSessionId := TAesPrng.Main.FillRandomHex(16);

  // Build response
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['protocolVersion'] := MCP_PROTOCOL_VERSION;

  // Capabilities
  TDocVariantData(Capabilities).InitFast;

  // Tools capability
  TDocVariantData(Tools).InitFast;
  TDocVariantData(Tools).B['supportsProgress'] := True;
  TDocVariantData(Tools).B['supportsCancellation'] := True;
  TDocVariantData(Tools).B['listChanged'] := True;
  TDocVariantData(Capabilities).AddValue('tools', Tools);

  // Resources capability
  TDocVariantData(Resources).InitFast;
  TDocVariantData(Resources).B['subscribe'] := True;
  TDocVariantData(Resources).B['listChanged'] := True;
  TDocVariantData(Capabilities).AddValue('resources', Resources);

  // Prompts capability
  TDocVariantData(Prompts).InitFast;
  TDocVariantData(Prompts).B['listChanged'] := True;
  TDocVariantData(Capabilities).AddValue('prompts', Prompts);

  // Logging capability (empty object indicates support)
  TDocVariantData(Logging).InitFast;
  TDocVariantData(Capabilities).AddValue('logging', Logging);

  // Completions capability (empty object indicates support)
  TDocVariantData(Completions).InitFast;
  TDocVariantData(Capabilities).AddValue('completions', Completions);

  TDocVariantData(Result).AddValue('capabilities', Capabilities);

  // Session ID
  TDocVariantData(Result).U['sessionId'] := fSessionId;

  // Server info
  TDocVariantData(ServerInfo).InitFast;
  TDocVariantData(ServerInfo).U['name'] := fSettings.ServerName;
  TDocVariantData(ServerInfo).U['version'] := fSettings.ServerVersion;
  TDocVariantData(Result).AddValue('serverInfo', ServerInfo);

  TSynLog.Add.Log(sllInfo, 'Created new MCP session: %', [fSessionId]);
end;

function TMCPCoreManager.Ping: Variant;
begin
  TSynLog.Add.Log(sllInfo, 'MCP Ping called');
  // MCP spec: ping returns empty object {}
  Result := _ObjFast([]);
end;

procedure TMCPCoreManager.HandleCancellation(const Params: Variant);
var
  ParamsDoc: PDocVariantData;
  RequestId: Variant;
  Reason: RawUtf8;
begin
  // Extract cancellation parameters
  // MCP spec: notifications/cancelled has params with requestId and optional reason
  ParamsDoc := _Safe(Params);

  RequestId := ParamsDoc^.Value['requestId'];
  if VarIsEmptyOrNull(RequestId) then
  begin
    TSynLog.Add.Log(sllWarning,
      'MCP notifications/cancelled received without requestId');
    Exit;
  end;

  Reason := ParamsDoc^.U['reason'];

  // Add to cancelled requests tracker
  fCancelledRequests.AddCancelledRequest(RequestId, Reason);

  if Reason <> '' then
    TSynLog.Add.Log(sllInfo, 'MCP Request % cancelled: %', [RequestId, Reason])
  else
    TSynLog.Add.Log(sllInfo, 'MCP Request % cancelled', [RequestId]);

  // Publish cancellation event to event bus for any interested handlers
  MCPEventBus.Publish(MCP_EVENT_CANCELLED, Params);
end;

end.
