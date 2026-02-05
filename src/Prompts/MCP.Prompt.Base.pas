/// MCP Prompt Base Classes
// - Base classes and interfaces for implementing MCP prompts
// - Supports text, image, audio, and resource content types
unit MCP.Prompt.Base;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.buffers,
  mormot.core.variants,
  mormot.core.json;

type
  /// Role of a message in a prompt conversation
  TMCPPromptRole = (
    prUser,      // User message
    prAssistant  // Assistant message
  );

  /// Content type for prompt message content items
  TMCPPromptContentType = (
    pctText,     // Plain text content
    pctImage,    // Image with mimeType and base64 data
    pctAudio,    // Audio with mimeType and base64 data
    pctResource  // Resource reference by URI
  );

  /// Prompt argument definition
  TMCPPromptArgument = record
    /// Argument name
    Name: RawUtf8;
    /// Argument description
    Description: RawUtf8;
    /// Whether the argument is required
    Required: Boolean;
  end;

  TMCPPromptArgumentArray = array of TMCPPromptArgument;

  /// Interface for MCP prompts
  IMCPPrompt = interface
    ['{A1B2C3D4-E5F6-4789-9012-ABCDEF012345}']
    /// Get the unique name of the prompt
    function GetName: RawUtf8;
    /// Get the description of what this prompt does
    function GetDescription: RawUtf8;
    /// Get the prompt arguments definition
    function GetArguments: TMCPPromptArgumentArray;
    /// Get the prompt messages given the arguments
    // - Arguments: Variant object with argument name-value pairs
    // - Returns: Array of message objects with role and content
    function GetMessages(const Arguments: Variant): Variant;
  end;

  /// Base class for MCP prompts
  TMCPPromptBase = class(TInterfacedObject, IMCPPrompt)
  protected
    fName: RawUtf8;
    fDescription: RawUtf8;
    fArguments: TMCPPromptArgumentArray;
    /// Build the messages array - override in derived classes
    function BuildMessages(const Arguments: Variant): Variant; virtual; abstract;
  public
    constructor Create; virtual;
    /// IMCPPrompt implementation
    function GetName: RawUtf8;
    function GetDescription: RawUtf8;
    function GetArguments: TMCPPromptArgumentArray;
    function GetMessages(const Arguments: Variant): Variant;
    /// Add an argument definition
    procedure AddArgument(const ArgName, ArgDescription: RawUtf8;
      IsRequired: Boolean = False);
    /// Properties for configuration
    property Name: RawUtf8 read fName write fName;
    property Description: RawUtf8 read fDescription write fDescription;
  end;

  TMCPPromptClass = class of TMCPPromptBase;

/// Create a text content item
function PromptContentText(const Text: RawUtf8): Variant;

/// Create an image content item
// - MimeType: e.g., 'image/png', 'image/jpeg'
// - Data: base64 encoded image data
function PromptContentImage(const MimeType, Data: RawUtf8): Variant;

/// Create an image content item from raw binary data
// - MimeType: e.g., 'image/png', 'image/jpeg'
// - RawData: raw binary image data (will be base64 encoded)
function PromptContentImageRaw(const MimeType: RawUtf8;
  const RawData: RawByteString): Variant;

/// Create an audio content item
// - MimeType: e.g., 'audio/wav', 'audio/mp3'
// - Data: base64 encoded audio data
function PromptContentAudio(const MimeType, Data: RawUtf8): Variant;

/// Create an audio content item from raw binary data
// - MimeType: e.g., 'audio/wav', 'audio/mp3'
// - RawData: raw binary audio data (will be base64 encoded)
function PromptContentAudioRaw(const MimeType: RawUtf8;
  const RawData: RawByteString): Variant;

/// Create a resource content item
// - Uri: URI of the resource
// - MimeType: optional MIME type hint
// - Text: optional text content (for embedded text resources)
function PromptContentResource(const Uri: RawUtf8;
  const MimeType: RawUtf8 = ''; const Text: RawUtf8 = ''): Variant;

/// Create a message object with role and content array
// - Role: user or assistant
// - Content: array of content items
function PromptMessage(Role: TMCPPromptRole; const Content: Variant): Variant;

/// Create a simple text message
// - Role: user or assistant
// - Text: plain text content
function PromptMessageText(Role: TMCPPromptRole; const Text: RawUtf8): Variant;

/// Convert role enum to string
function PromptRoleToStr(Role: TMCPPromptRole): RawUtf8;

implementation

function PromptRoleToStr(Role: TMCPPromptRole): RawUtf8;
begin
  case Role of
    prUser:      Result := 'user';
    prAssistant: Result := 'assistant';
  else
    Result := 'user';
  end;
end;

function PromptContentText(const Text: RawUtf8): Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).U['type'] := 'text';
  TDocVariantData(Result).U['text'] := Text;
end;

function PromptContentImage(const MimeType, Data: RawUtf8): Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).U['type'] := 'image';
  TDocVariantData(Result).U['mimeType'] := MimeType;
  TDocVariantData(Result).U['data'] := Data;
end;

function PromptContentImageRaw(const MimeType: RawUtf8;
  const RawData: RawByteString): Variant;
begin
  Result := PromptContentImage(MimeType, BinToBase64(RawData));
end;

function PromptContentAudio(const MimeType, Data: RawUtf8): Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).U['type'] := 'audio';
  TDocVariantData(Result).U['mimeType'] := MimeType;
  TDocVariantData(Result).U['data'] := Data;
end;

function PromptContentAudioRaw(const MimeType: RawUtf8;
  const RawData: RawByteString): Variant;
begin
  Result := PromptContentAudio(MimeType, BinToBase64(RawData));
end;

function PromptContentResource(const Uri: RawUtf8;
  const MimeType: RawUtf8; const Text: RawUtf8): Variant;
var
  ResourceObj: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).U['type'] := 'resource';

  TDocVariantData(ResourceObj).InitFast;
  TDocVariantData(ResourceObj).U['uri'] := Uri;
  if MimeType <> '' then
    TDocVariantData(ResourceObj).U['mimeType'] := MimeType;
  if Text <> '' then
    TDocVariantData(ResourceObj).U['text'] := Text;

  TDocVariantData(Result).AddValue('resource', ResourceObj);
end;

function PromptMessage(Role: TMCPPromptRole; const Content: Variant): Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).U['role'] := PromptRoleToStr(Role);
  TDocVariantData(Result).AddValue('content', Content);
end;

function PromptMessageText(Role: TMCPPromptRole; const Text: RawUtf8): Variant;
var
  Content, ContentItem: Variant;
begin
  TDocVariantData(Content).InitArray([], JSON_FAST);
  ContentItem := PromptContentText(Text);
  TDocVariantData(Content).AddItem(ContentItem);
  Result := PromptMessage(Role, Content);
end;

{ TMCPPromptBase }

constructor TMCPPromptBase.Create;
begin
  inherited Create;
  SetLength(fArguments, 0);
end;

function TMCPPromptBase.GetName: RawUtf8;
begin
  Result := fName;
end;

function TMCPPromptBase.GetDescription: RawUtf8;
begin
  Result := fDescription;
end;

function TMCPPromptBase.GetArguments: TMCPPromptArgumentArray;
begin
  Result := fArguments;
end;

function TMCPPromptBase.GetMessages(const Arguments: Variant): Variant;
begin
  Result := BuildMessages(Arguments);
end;

procedure TMCPPromptBase.AddArgument(const ArgName, ArgDescription: RawUtf8;
  IsRequired: Boolean);
var
  n: PtrInt;
begin
  n := Length(fArguments);
  SetLength(fArguments, n + 1);
  fArguments[n].Name := ArgName;
  fArguments[n].Description := ArgDescription;
  fArguments[n].Required := IsRequired;
end;

end.
