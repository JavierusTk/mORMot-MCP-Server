/// MCP GetTime Tool
// - Returns current date/time in various formats
unit MCP.Tool.GetTime;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.datetime,
  mormot.core.variants,
  mormot.core.json,
  MCP.Tool.Base;

type
  /// GetTime tool - returns current date/time
  TMCPToolGetTime = class(TMCPToolBase)
  protected
    function BuildInputSchema: Variant; override;
  public
    constructor Create; override;
    function Execute(const Arguments: Variant): Variant; override;
  end;

implementation

{ TMCPToolGetTime }

constructor TMCPToolGetTime.Create;
begin
  inherited Create;
  fName := 'get_time';
  fDescription := 'Returns the current date and time in various formats';
end;

function TMCPToolGetTime.BuildInputSchema: Variant;
var
  Properties, FormatProp, Enum, Required: Variant;
begin
  TDocVariantData(Result).InitFast;
  TDocVariantData(Result).S['type'] := 'object';

  // Properties
  TDocVariantData(Properties).InitFast;

  TDocVariantData(FormatProp).InitFast;
  TDocVariantData(FormatProp).S['type'] := 'string';
  TDocVariantData(FormatProp).S['description'] :=
    'Output format: iso8601, unix, readable, or date_only';
  TDocVariantData(FormatProp).S['default'] := 'iso8601';

  // Enum values
  TDocVariantData(Enum).InitArray([], JSON_FAST);
  TDocVariantData(Enum).AddItem('iso8601');
  TDocVariantData(Enum).AddItem('unix');
  TDocVariantData(Enum).AddItem('readable');
  TDocVariantData(Enum).AddItem('date_only');
  TDocVariantData(FormatProp).AddValue('enum', Enum);

  TDocVariantData(Properties).AddValue('format', FormatProp);
  TDocVariantData(Result).AddValue('properties', Properties);

  // No required properties (format has default)
  TDocVariantData(Required).InitArray([], JSON_FAST);
  TDocVariantData(Result).AddValue('required', Required);
end;

function TMCPToolGetTime.Execute(const Arguments: Variant): Variant;
var
  ArgsDoc: PDocVariantData;
  Format: RawUtf8;
  Now: TDateTime;
  TimeStr: RawUtf8;
  ResultData: Variant;
begin
  Now := NowUtc;

  // Get format parameter using safe access
  ArgsDoc := _Safe(Arguments);
  Format := ArgsDoc^.U['format'];
  if Format = '' then
    Format := 'iso8601';

  // Format the time
  if IdemPropNameU(Format, 'iso8601') then
    TimeStr := DateTimeToIso8601(Now, True, 'T', True)
  else if IdemPropNameU(Format, 'unix') then
    TimeStr := Int64ToUtf8(DateTimeToUnixTime(Now))
  else if IdemPropNameU(Format, 'readable') then
    TimeStr := DateTimeToIso8601(Now, True, ' ', False)
  else if IdemPropNameU(Format, 'date_only') then
    TimeStr := DateToIso8601(Now, True)
  else
    TimeStr := DateTimeToIso8601(Now, True, 'T', True);

  // Build result
  TDocVariantData(ResultData).InitFast;
  TDocVariantData(ResultData).U['time'] := TimeStr;
  TDocVariantData(ResultData).U['format'] := Format;
  TDocVariantData(ResultData).U['timezone'] := 'UTC';

  Result := ToolResultJson(ResultData);
end;

end.
