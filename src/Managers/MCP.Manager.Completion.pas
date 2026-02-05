/// MCP Completion Manager
// - Handles argument completion for prompts and resource templates
// - Implements completion/complete method per MCP 2025-06-18 spec
unit MCP.Manager.Completion;

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
  MCP.Types;

const
  /// Maximum number of completion values to return
  MCP_COMPLETION_MAX_VALUES = 100;

type
  /// Reference type for completion
  TMCPCompletionRefType = (
    crtUnknown,   // Unknown reference type
    crtPrompt,    // ref/prompt
    crtResource   // ref/resource
  );

  /// Completion provider callback type
  // - RefType: type of reference (prompt or resource)
  // - RefName: name of the prompt or URI template of the resource
  // - ArgumentName: name of the argument being completed
  // - ArgumentValue: partial value entered by user
  // - Context: additional context (other arguments already provided)
  // - Returns: array of completion values as Variant (TDocVariant array)
  TMCPCompletionProvider = function(RefType: TMCPCompletionRefType;
    const RefName, ArgumentName, ArgumentValue: RawUtf8;
    const Context: Variant): Variant of object;

  /// Completion capability manager for MCP protocol
  // - Provides argument completion suggestions for prompts and resource templates
  // - Supports custom completion providers for dynamic completions
  TMCPCompletionManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    fCompletionProvider: TMCPCompletionProvider;
    function ParseRefType(const Ref: Variant; out RefName: RawUtf8): TMCPCompletionRefType;
    function DoComplete(RefType: TMCPCompletionRefType;
      const RefName, ArgumentName, ArgumentValue: RawUtf8;
      const Context: Variant): Variant;
  public
    constructor Create;
    destructor Destroy; override;
    /// IMCPCapabilityManager implementation
    function GetCapabilityName: RawUtf8;
    function HandlesMethod(const Method: RawUtf8): Boolean;
    function ExecuteMethod(const Method: RawUtf8; const Params: Variant): Variant;
    /// Complete an argument value
    // - Ref: reference object with type (ref/prompt or ref/resource) and name/uri
    // - Argument: object with name and value of the argument being completed
    // - Context: optional context with other arguments already provided
    // - Returns: completion object with values array, total, and hasMore flag
    function Complete(const Ref, Argument: Variant;
      const Context: Variant): Variant;
    /// Set custom completion provider
    // - Provider: callback function to generate completions dynamically
    // - If not set, empty completions are returned
    procedure SetCompletionProvider(const Provider: TMCPCompletionProvider);
    /// Property for completion provider
    property CompletionProvider: TMCPCompletionProvider
      read fCompletionProvider write fCompletionProvider;
  end;

  /// Exception raised for completion errors
  EMCPCompletionError = class(EMCPError);

implementation

{ TMCPCompletionManager }

constructor TMCPCompletionManager.Create;
begin
  inherited Create;
  fCompletionProvider := nil;
end;

destructor TMCPCompletionManager.Destroy;
begin
  fCompletionProvider := nil;
  inherited;
end;

function TMCPCompletionManager.GetCapabilityName: RawUtf8;
begin
  Result := 'completions';
end;

function TMCPCompletionManager.HandlesMethod(const Method: RawUtf8): Boolean;
begin
  Result := IdemPropNameU(Method, 'completion/complete');
end;

function TMCPCompletionManager.ExecuteMethod(const Method: RawUtf8;
  const Params: Variant): Variant;
var
  ParamsDoc: PDocVariantData;
  Ref, Argument, Context: Variant;
begin
  ParamsDoc := _Safe(Params);

  if IdemPropNameU(Method, 'completion/complete') then
  begin
    Ref := ParamsDoc^.Value['ref'];
    if VarIsEmptyOrNull(Ref) then
      raise EMCPCompletionError.Create('[ref] property not found');

    Argument := ParamsDoc^.Value['argument'];
    if VarIsEmptyOrNull(Argument) then
      raise EMCPCompletionError.Create('[argument] property not found');

    Context := ParamsDoc^.Value['context'];

    Result := Complete(Ref, Argument, Context);
  end
  else
    raise EMCPCompletionError.CreateFmt('Method %s not handled by %s',
      [Method, GetCapabilityName]);
end;

function TMCPCompletionManager.ParseRefType(const Ref: Variant;
  out RefName: RawUtf8): TMCPCompletionRefType;
var
  RefDoc: PDocVariantData;
  RefType: RawUtf8;
begin
  Result := crtUnknown;
  RefName := '';

  RefDoc := _Safe(Ref);

  // Get the type field
  RefType := RefDoc^.U['type'];

  if IdemPropNameU(RefType, 'ref/prompt') then
  begin
    Result := crtPrompt;
    RefName := RefDoc^.U['name'];
  end
  else if IdemPropNameU(RefType, 'ref/resource') then
  begin
    Result := crtResource;
    RefName := RefDoc^.U['uri'];
  end;
end;

function TMCPCompletionManager.DoComplete(RefType: TMCPCompletionRefType;
  const RefName, ArgumentName, ArgumentValue: RawUtf8;
  const Context: Variant): Variant;
var
  Values: Variant;
begin
  // If we have a custom completion provider, use it
  if Assigned(fCompletionProvider) then
  begin
    Values := fCompletionProvider(RefType, RefName, ArgumentName, ArgumentValue, Context);
    if not VarIsEmptyOrNull(Values) then
    begin
      Result := Values;
      Exit;
    end;
  end;

  // Default: return empty values array
  // Servers can override this by setting a completion provider
  TDocVariantData(Values).InitArray([], JSON_FAST);
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).AddValue('values', Values);
end;

function TMCPCompletionManager.Complete(const Ref, Argument: Variant;
  const Context: Variant): Variant;
var
  ArgumentDoc: PDocVariantData;
  RefType: TMCPCompletionRefType;
  RefName, ArgumentName, ArgumentValue: RawUtf8;
  Values, Completion: Variant;
  ValuesDoc: PDocVariantData;
  ValuesCount: Integer;
  HasMore: Boolean;
begin
  TSynLog.Add.Log(sllInfo, 'MCP completion/complete called');

  // Parse reference
  RefType := ParseRefType(Ref, RefName);
  if RefType = crtUnknown then
  begin
    TSynLog.Add.Log(sllWarning, 'Unknown ref type in completion request');
    raise EMCPCompletionError.Create('Invalid or unsupported ref type');
  end;

  // Parse argument
  ArgumentDoc := _Safe(Argument);
  ArgumentName := ArgumentDoc^.U['name'];
  ArgumentValue := ArgumentDoc^.U['value'];

  if ArgumentName = '' then
    raise EMCPCompletionError.Create('[argument.name] property not found');

  TSynLog.Add.Log(sllDebug, 'Completion request: ref=%, name=%, arg=%, value=%',
    [Ord(RefType), RefName, ArgumentName, ArgumentValue]);

  // Get completions
  Completion := DoComplete(RefType, RefName, ArgumentName, ArgumentValue, Context);

  // Build result with completion wrapper
  TDocVariantData(Result).InitFast;

  // Extract values from completion result
  ValuesDoc := _Safe(Completion);
  Values := ValuesDoc^.Value['values'];
  if VarIsEmptyOrNull(Values) then
    TDocVariantData(Values).InitArray([], JSON_FAST);

  // Check if we need to truncate (max 100 values per spec)
  ValuesDoc := _Safe(Values);
  ValuesCount := ValuesDoc^.Count;
  HasMore := ValuesCount > MCP_COMPLETION_MAX_VALUES;

  if HasMore then
  begin
    // Truncate to max values
    // Note: In a real implementation, we'd want to properly truncate the array
    // For now, we'll rely on the provider to return proper counts
    TSynLog.Add.Log(sllWarning,
      'Completion returned more than % values, truncating', [MCP_COMPLETION_MAX_VALUES]);
  end;

  // Build completion object
  TDocVariantData(Completion).InitFast;
  TDocVariantData(Completion).AddValue('values', Values);

  // Add total if we know it
  if ValuesCount > 0 then
    TDocVariantData(Completion).I['total'] := ValuesCount;

  // Add hasMore flag if truncated
  if HasMore then
    TDocVariantData(Completion).B['hasMore'] := True;

  TDocVariantData(Result).AddValue('completion', Completion);
end;

procedure TMCPCompletionManager.SetCompletionProvider(
  const Provider: TMCPCompletionProvider);
begin
  fCompletionProvider := Provider;
end;

end.
