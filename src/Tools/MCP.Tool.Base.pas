/// MCP Tool Base Classes
// - Base classes for implementing MCP tools
unit MCP.Tool.Base;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.variants,
  mormot.core.json;

type
  /// Interface for MCP tools
  IMCPTool = interface
    ['{F1E2D3C4-B5A6-4798-8901-234567890ABC}']
    function GetName: RawUtf8;
    function GetDescription: RawUtf8;
    function GetInputSchema: Variant;
    function Execute(const Arguments: Variant): Variant;
  end;

  /// Base class for MCP tools
  TMCPToolBase = class(TInterfacedObject, IMCPTool)
  protected
    fName: RawUtf8;
    fDescription: RawUtf8;
    function BuildInputSchema: Variant; virtual;
  public
    constructor Create; virtual;
    function GetName: RawUtf8;
    function GetDescription: RawUtf8;
    function GetInputSchema: Variant;
    function Execute(const Arguments: Variant): Variant; virtual; abstract;
    property Name: RawUtf8 read fName write fName;
    property Description: RawUtf8 read fDescription write fDescription;
  end;

  TMCPToolClass = class of TMCPToolBase;

/// Create a tool result with text content
function ToolResultText(const Text: RawUtf8; IsError: Boolean = False): Variant;

/// Create a tool result with JSON content
function ToolResultJson(const Json: Variant; IsError: Boolean = False): Variant;

implementation

function ToolResultText(const Text: RawUtf8; IsError: Boolean): Variant;
var
  Content, ContentItem: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Content).InitArray([], JSON_FAST);
  TDocVariantData(ContentItem).InitFast;
  TDocVariantData(ContentItem).U['type'] := 'text';
  TDocVariantData(ContentItem).U['text'] := Text;
  TDocVariantData(Content).AddItem(ContentItem);
  TDocVariantData(Result).AddValue('content', Content);
  TDocVariantData(Result).B['isError'] := IsError;
end;

function ToolResultJson(const Json: Variant; IsError: Boolean): Variant;
var
  Content, ContentItem: Variant;
  JsonText: RawUtf8;
begin
  TDocVariantData(Result).InitFast;
  if VarIsEmptyOrNull(Json) then
    JsonText := '{}'
  else
    JsonText := TDocVariantData(Json).ToJson;
  TDocVariantData(Content).InitArray([], JSON_FAST);
  TDocVariantData(ContentItem).InitFast;
  TDocVariantData(ContentItem).U['type'] := 'text';
  TDocVariantData(ContentItem).U['text'] := JsonText;
  TDocVariantData(Content).AddItem(ContentItem);
  TDocVariantData(Result).AddValue('content', Content);
  TDocVariantData(Result).B['isError'] := IsError;
end;

{ TMCPToolBase }

constructor TMCPToolBase.Create;
begin
  inherited Create;
end;

function TMCPToolBase.GetName: RawUtf8;
begin
  Result := fName;
end;

function TMCPToolBase.GetDescription: RawUtf8;
begin
  Result := fDescription;
end;

function TMCPToolBase.GetInputSchema: Variant;
begin
  Result := BuildInputSchema;
end;

function TMCPToolBase.BuildInputSchema: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';
end;

end.
