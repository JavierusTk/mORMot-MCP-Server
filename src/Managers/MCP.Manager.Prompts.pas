/// MCP Prompts Manager
// - Manages prompt registration, listing, and message generation
unit MCP.Manager.Prompts;

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
  MCP.Prompt.Base,
  MCP.Events;

type
  /// Prompts capability manager for MCP protocol
  TMCPPromptsManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    fPrompts: array of IMCPPrompt;
    function FindPrompt(const Name: RawUtf8): IMCPPrompt;
  public
    constructor Create;
    destructor Destroy; override;
    /// Register a prompt
    procedure RegisterPrompt(const Prompt: IMCPPrompt); overload;
    /// Register a prompt by class (creates instance)
    procedure RegisterPrompt(PromptClass: TMCPPromptClass); overload;
    /// Unregister a prompt by name
    function UnregisterPrompt(const PromptName: RawUtf8): Boolean;
    /// IMCPCapabilityManager implementation
    function GetCapabilityName: RawUtf8;
    function HandlesMethod(const Method: RawUtf8): Boolean;
    function ExecuteMethod(const Method: RawUtf8; const Params: Variant): Variant;
    /// List all registered prompts
    function ListPrompts: Variant;
    /// Get a specific prompt with messages
    // - Name: prompt name
    // - Arguments: optional arguments for the prompt
    function GetPrompt(const Name: RawUtf8; const Arguments: Variant): Variant;
    /// Get count of registered prompts
    function GetPromptCount: Integer;
  end;

  /// Exception raised when a prompt is not found
  EMCPPromptNotFound = class(EMCPError)
  public
    constructor Create(const Name: RawUtf8);
  end;

implementation

{ EMCPPromptNotFound }

constructor EMCPPromptNotFound.Create(const Name: RawUtf8);
begin
  inherited CreateFmt('Prompt not found: %s', [Name]);
end;

{ TMCPPromptsManager }

constructor TMCPPromptsManager.Create;
begin
  inherited Create;
  SetLength(fPrompts, 0);
end;

destructor TMCPPromptsManager.Destroy;
begin
  SetLength(fPrompts, 0);
  inherited;
end;

function TMCPPromptsManager.FindPrompt(const Name: RawUtf8): IMCPPrompt;
var
  i: PtrInt;
begin
  Result := nil;
  for i := 0 to High(fPrompts) do
    if IdemPropNameU(fPrompts[i].GetName, Name) then
    begin
      Result := fPrompts[i];
      Exit;
    end;
end;

procedure TMCPPromptsManager.RegisterPrompt(const Prompt: IMCPPrompt);
var
  i: PtrInt;
begin
  // Check if already registered
  for i := 0 to High(fPrompts) do
    if IdemPropNameU(fPrompts[i].GetName, Prompt.GetName) then
      Exit;

  // Add to list
  SetLength(fPrompts, Length(fPrompts) + 1);
  fPrompts[High(fPrompts)] := Prompt;

  TSynLog.Add.Log(sllInfo, 'Registered prompt: %', [Prompt.GetName]);

  // Emit prompts/list_changed notification
  MCPEventBus.Publish(MCP_EVENT_PROMPTS_LIST_CHANGED, _ObjFast([]));
end;

procedure TMCPPromptsManager.RegisterPrompt(PromptClass: TMCPPromptClass);
var
  Prompt: TMCPPromptBase;
begin
  Prompt := PromptClass.Create;
  RegisterPrompt(Prompt);
end;

function TMCPPromptsManager.UnregisterPrompt(const PromptName: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  for i := 0 to High(fPrompts) do
    if IdemPropNameU(fPrompts[i].GetName, PromptName) then
    begin
      // Remove by shifting remaining elements
      if i < High(fPrompts) then
        Move(fPrompts[i + 1], fPrompts[i],
          (High(fPrompts) - i) * SizeOf(IMCPPrompt));
      SetLength(fPrompts, Length(fPrompts) - 1);

      TSynLog.Add.Log(sllInfo, 'Unregistered prompt: %', [PromptName]);

      // Emit prompts/list_changed notification
      MCPEventBus.Publish(MCP_EVENT_PROMPTS_LIST_CHANGED, _ObjFast([]));

      Result := True;
      Exit;
    end;
end;

function TMCPPromptsManager.GetCapabilityName: RawUtf8;
begin
  Result := 'prompts';
end;

function TMCPPromptsManager.HandlesMethod(const Method: RawUtf8): Boolean;
begin
  Result := IdemPropNameU(Method, 'prompts/list') or
            IdemPropNameU(Method, 'prompts/get');
end;

function TMCPPromptsManager.ExecuteMethod(const Method: RawUtf8;
  const Params: Variant): Variant;
var
  ParamsDoc: PDocVariantData;
  Name: RawUtf8;
  Arguments: Variant;
begin
  ParamsDoc := _Safe(Params);

  if IdemPropNameU(Method, 'prompts/list') then
  begin
    Result := ListPrompts;
  end
  else if IdemPropNameU(Method, 'prompts/get') then
  begin
    Name := ParamsDoc^.U['name'];
    if Name = '' then
      raise Exception.Create('[name] property not found');
    Arguments := ParamsDoc^.Value['arguments'];
    Result := GetPrompt(Name, Arguments);
  end
  else
    raise Exception.CreateFmt('Method %s not handled by %s',
      [Method, GetCapabilityName]);
end;

function TMCPPromptsManager.ListPrompts: Variant;
var
  Prompts, PromptInfo, ArgsArray, ArgInfo: Variant;
  PromptArgs: TMCPPromptArgumentArray;
  i, j: PtrInt;
begin
  TSynLog.Add.Log(sllInfo, 'MCP prompts/list called');

  TDocVariantData(Result).InitFast;
  TDocVariantData(Prompts).InitArray([], JSON_FAST);

  for i := 0 to High(fPrompts) do
  begin
    TDocVariantData(PromptInfo).InitFast;
    TDocVariantData(PromptInfo).U['name'] := fPrompts[i].GetName;
    if fPrompts[i].GetDescription <> '' then
      TDocVariantData(PromptInfo).U['description'] := fPrompts[i].GetDescription;

    // Add arguments if any
    PromptArgs := fPrompts[i].GetArguments;
    if Length(PromptArgs) > 0 then
    begin
      TDocVariantData(ArgsArray).InitArray([], JSON_FAST);
      for j := 0 to High(PromptArgs) do
      begin
        TDocVariantData(ArgInfo).InitFast;
        TDocVariantData(ArgInfo).U['name'] := PromptArgs[j].Name;
        if PromptArgs[j].Description <> '' then
          TDocVariantData(ArgInfo).U['description'] := PromptArgs[j].Description;
        TDocVariantData(ArgInfo).B['required'] := PromptArgs[j].Required;
        TDocVariantData(ArgsArray).AddItem(ArgInfo);
      end;
      TDocVariantData(PromptInfo).AddValue('arguments', ArgsArray);
    end;

    TDocVariantData(Prompts).AddItem(PromptInfo);
  end;

  TDocVariantData(Result).AddValue('prompts', Prompts);
end;

function TMCPPromptsManager.GetPrompt(const Name: RawUtf8;
  const Arguments: Variant): Variant;
var
  Prompt: IMCPPrompt;
  Messages: Variant;
begin
  TSynLog.Add.Log(sllInfo, 'MCP prompts/get called for: %', [Name]);

  Prompt := FindPrompt(Name);
  if Prompt = nil then
  begin
    TSynLog.Add.Log(sllWarning, 'Prompt not found: %', [Name]);
    raise EMCPPromptNotFound.Create(Name);
  end;

  // Get messages from the prompt
  Messages := Prompt.GetMessages(Arguments);

  // Build result
  TDocVariantData(Result).InitFast;
  if VarIsEmptyOrNull(Messages) then
  begin
    TDocVariantData(Messages).InitArray([], JSON_FAST);
  end;
  TDocVariantData(Result).AddValue('messages', Messages);

  // Optionally add description
  if Prompt.GetDescription <> '' then
    TDocVariantData(Result).U['description'] := Prompt.GetDescription;
end;

function TMCPPromptsManager.GetPromptCount: Integer;
begin
  Result := Length(fPrompts);
end;

end.
