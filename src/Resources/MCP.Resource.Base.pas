/// MCP Resource Base Classes
// - Base classes and interfaces for implementing MCP resources
unit MCP.Resource.Base;

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
  /// Content type returned by a resource
  TMCPResourceContentType = (
    rctText,    // Text content (returned as 'text' field)
    rctBlob     // Binary content (returned as 'blob' field, base64 encoded)
  );

  /// Interface for MCP resources
  IMCPResource = interface
    ['{C1D2E3F4-A5B6-4789-9012-345678901234}']
    /// Get the unique URI identifying this resource
    function GetUri: RawUtf8;
    /// Get the human-readable name of the resource
    function GetName: RawUtf8;
    /// Get the description of what this resource provides
    function GetDescription: RawUtf8;
    /// Get the MIME type of the resource content
    function GetMimeType: RawUtf8;
    /// Get the content type (text or blob)
    function GetContentType: TMCPResourceContentType;
    /// Get the resource content
    // - For text resources, returns UTF-8 text
    // - For blob resources, returns raw binary data (not yet base64 encoded)
    function GetContent: RawByteString;
  end;

  /// Base class for MCP resources
  TMCPResourceBase = class(TInterfacedObject, IMCPResource)
  protected
    fUri: RawUtf8;
    fName: RawUtf8;
    fDescription: RawUtf8;
    fMimeType: RawUtf8;
  public
    constructor Create; virtual;
    /// IMCPResource implementation
    function GetUri: RawUtf8;
    function GetName: RawUtf8;
    function GetDescription: RawUtf8;
    function GetMimeType: RawUtf8;
    function GetContentType: TMCPResourceContentType; virtual;
    function GetContent: RawByteString; virtual; abstract;
    /// Properties for configuration
    property Uri: RawUtf8 read fUri write fUri;
    property Name: RawUtf8 read fName write fName;
    property Description: RawUtf8 read fDescription write fDescription;
    property MimeType: RawUtf8 read fMimeType write fMimeType;
  end;

  TMCPResourceClass = class of TMCPResourceBase;

  /// Simple text resource with static content
  TMCPTextResource = class(TMCPResourceBase)
  protected
    fContent: RawUtf8;
  public
    function GetContentType: TMCPResourceContentType; override;
    function GetContent: RawByteString; override;
    property Content: RawUtf8 read fContent write fContent;
  end;

  /// Simple blob resource with static binary content
  TMCPBlobResource = class(TMCPResourceBase)
  protected
    fContent: RawByteString;
  public
    function GetContentType: TMCPResourceContentType; override;
    function GetContent: RawByteString; override;
    property Content: RawByteString read fContent write fContent;
  end;

implementation

{ TMCPResourceBase }

constructor TMCPResourceBase.Create;
begin
  inherited Create;
  fMimeType := 'text/plain';
end;

function TMCPResourceBase.GetUri: RawUtf8;
begin
  Result := fUri;
end;

function TMCPResourceBase.GetName: RawUtf8;
begin
  Result := fName;
end;

function TMCPResourceBase.GetDescription: RawUtf8;
begin
  Result := fDescription;
end;

function TMCPResourceBase.GetMimeType: RawUtf8;
begin
  Result := fMimeType;
end;

function TMCPResourceBase.GetContentType: TMCPResourceContentType;
begin
  Result := rctText;  // Default to text
end;

{ TMCPTextResource }

function TMCPTextResource.GetContentType: TMCPResourceContentType;
begin
  Result := rctText;
end;

function TMCPTextResource.GetContent: RawByteString;
begin
  Result := fContent;
end;

{ TMCPBlobResource }

function TMCPBlobResource.GetContentType: TMCPResourceContentType;
begin
  Result := rctBlob;
end;

function TMCPBlobResource.GetContent: RawByteString;
begin
  Result := fContent;
end;

end.
