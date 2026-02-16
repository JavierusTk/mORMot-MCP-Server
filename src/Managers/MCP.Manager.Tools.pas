/// MCP Tools Manager
// - Manages tool registration and execution
unit MCP.Manager.Tools;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.rtti,
  MCP.Types,
  MCP.Tool.Base,
  MCP.Events;

type
  /// Tools capability manager for MCP protocol
  TMCPToolsManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    fTools: array of IMCPTool;
    function FindTool(const Name: RawUtf8): IMCPTool;
  public
    constructor Create;
    destructor Destroy; override;
    /// Register a tool
    procedure RegisterTool(const Tool: IMCPTool); overload;
    /// Register a tool by class
    procedure RegisterTool(ToolClass: TMCPToolClass); overload;
    /// Unregister a tool by name
    function UnregisterTool(const ToolName: RawUtf8): Boolean;
    /// IMCPCapabilityManager implementation
    function GetCapabilityName: RawUtf8;
    function HandlesMethod(const Method: RawUtf8): Boolean;
    function ExecuteMethod(const Method: RawUtf8; const Params: Variant): Variant;
    /// List all registered tools
    function ListTools: Variant;
    /// Call a specific tool
    function CallTool(const Params: Variant): Variant;
  end;

implementation

{ TMCPToolsManager }

constructor TMCPToolsManager.Create;
begin
  inherited Create;
  SetLength(fTools, 0);
end;

destructor TMCPToolsManager.Destroy;
begin
  SetLength(fTools, 0);
  inherited;
end;

procedure TMCPToolsManager.RegisterTool(const Tool: IMCPTool);
var
  i: PtrInt;
begin
  // Check if already registered
  for i := 0 to High(fTools) do
    if IdemPropNameU(fTools[i].GetName, Tool.GetName) then
      Exit;

  // Add to list
  SetLength(fTools, Length(fTools) + 1);
  fTools[High(fTools)] := Tool;

  TSynLog.Add.Log(sllInfo, 'Registered tool: %', [Tool.GetName]);

  // Emit tools/list_changed notification
  MCPEventBus.Publish(MCP_EVENT_TOOLS_LIST_CHANGED, _ObjFast([]));
end;

procedure TMCPToolsManager.RegisterTool(ToolClass: TMCPToolClass);
var
  Tool: TMCPToolBase;
begin
  Tool := ToolClass.Create;
  RegisterTool(Tool);
end;

function TMCPToolsManager.UnregisterTool(const ToolName: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  for i := 0 to High(fTools) do
    if IdemPropNameU(fTools[i].GetName, ToolName) then
    begin
      // Remove by shifting remaining elements
      if i < High(fTools) then
        Move(fTools[i + 1], fTools[i],
          (High(fTools) - i) * SizeOf(IMCPTool));
      SetLength(fTools, Length(fTools) - 1);

      TSynLog.Add.Log(sllInfo, 'Unregistered tool: %', [ToolName]);

      // Emit tools/list_changed notification
      MCPEventBus.Publish(MCP_EVENT_TOOLS_LIST_CHANGED, _ObjFast([]));

      Result := True;
      Exit;
    end;
end;

function TMCPToolsManager.FindTool(const Name: RawUtf8): IMCPTool;
var
  i: PtrInt;
begin
  Result := nil;
  for i := 0 to High(fTools) do
    if IdemPropNameU(fTools[i].GetName, Name) then
    begin
      Result := fTools[i];
      Exit;
    end;
end;

function TMCPToolsManager.GetCapabilityName: RawUtf8;
begin
  Result := 'tools';
end;

function TMCPToolsManager.HandlesMethod(const Method: RawUtf8): Boolean;
begin
  Result := IdemPropNameU(Method, 'tools/list') or
            IdemPropNameU(Method, 'tools/call');
end;

function TMCPToolsManager.ExecuteMethod(const Method: RawUtf8;
  const Params: Variant): Variant;
begin
  if IdemPropNameU(Method, 'tools/list') then
    Result := ListTools
  else if IdemPropNameU(Method, 'tools/call') then
    Result := CallTool(Params)
  else
    raise Exception.CreateFmt('Method %s not handled by %s',
      [Method, GetCapabilityName]);
end;

function TMCPToolsManager.ListTools: Variant;
var
  Tools, ToolInfo: Variant;
  i: PtrInt;
begin
  TSynLog.Add.Log(sllInfo, 'MCP tools/list called');

  TDocVariantData(Result).InitFast;
  TDocVariantData(Tools).InitArray([], JSON_FAST);

  for i := 0 to High(fTools) do
  begin
    TDocVariantData(ToolInfo).InitFast;
    TDocVariantData(ToolInfo).U['name'] := fTools[i].GetName;
    TDocVariantData(ToolInfo).U['description'] := fTools[i].GetDescription;
    TDocVariantData(ToolInfo).AddValue('inputSchema', fTools[i].GetInputSchema);
    TDocVariantData(Tools).AddItem(ToolInfo);
  end;

  TDocVariantData(Result).AddValue('tools', Tools);
end;

function TMCPToolsManager.CallTool(const Params: Variant): Variant;
var
  ParamsDoc: PDocVariantData;
  ToolName: RawUtf8;
  Tool: IMCPTool;
  Arguments: Variant;
begin
  // Safe access to params
  ParamsDoc := _Safe(Params);

  // Extract tool name
  ToolName := ParamsDoc^.U['name'];
  if ToolName = '' then
    raise Exception.Create('[name] property not found');

  TSynLog.Add.Log(sllInfo, 'MCP tools/call: %', [ToolName]);

  // Find tool
  Tool := FindTool(ToolName);
  if Tool = nil then
    raise Exception.CreateFmt('Tool not found: %s', [ToolName]);

  // Extract arguments
  Arguments := ParamsDoc^.Value['arguments'];

  // Execute tool
  try
    Result := Tool.Execute(Arguments);
  except
    on E: Exception do
    begin
      TSynLog.Add.Log(sllError, 'Tool % error: %', [ToolName, E.Message]);
      Result := ToolResultText(StringToUtf8(E.Message), True);
    end;
  end;
end;

end.
