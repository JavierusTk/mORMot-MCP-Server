/// MCP Echo Tool
// - Simple echo tool for testing
unit MCP.Tool.Echo;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.text,
  mormot.core.variants,
  mormot.core.json,
  MCP.Tool.Base;

type
  /// Echo tool - returns the input message
  TMCPToolEcho = class(TMCPToolBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant): Variant; override;
  end;

implementation

{ TMCPToolEcho }

constructor TMCPToolEcho.Create;
begin
  inherited Create;
  fName := 'echo';
  fDescription := 'Echoes the input message back to the caller';
end;

function TMCPToolEcho.BuildInputSchema: Variant;
var
  Properties, MessageProp, Required: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';

  // Properties
  TDocVariantData(Properties).InitFast;

  TDocVariantData(MessageProp).InitFast;
  TDocVariantData(MessageProp).S['type'] := 'string';
  TDocVariantData(MessageProp).S['description'] := 'The message to echo back';
  TDocVariantData(Properties).AddValue('message', MessageProp);

  TDocVariantData(Result).AddValue('properties', Properties);

  // Required
  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Required).AddItem('message');
  TDocVariantData(Result).AddValue('required', Required);
end;

function TMCPToolEcho.Execute(const Arguments: Variant): Variant;
var
  ArgsDoc: PDocVariantData;
  Message: RawUtf8;
begin
  ArgsDoc := _Safe(Arguments);
  Message := ArgsDoc^.U['message'];

  if Message = '' then
    Result := ToolResultText('No message provided', True)
  else
    Result := ToolResultText(FormatUtf8('Echo: %', [Message]));
end;

end.
