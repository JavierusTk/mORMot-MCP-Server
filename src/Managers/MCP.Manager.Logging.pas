/// MCP Logging Manager
// - Handles logging/setLevel method and notifications/message
// - RFC 5424 log levels support
unit MCP.Manager.Logging;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.rtti,
  MCP.Types;

const
  /// RFC 5424 Log Levels (mapped to MCP string levels)
  // MCP uses subset: debug(7), info(6), notice(5), warning(4), error(3), critical(2)
  // We also include emergency(0) and alert(1) for completeness
  MCP_LOG_LEVEL_EMERGENCY = 0;
  MCP_LOG_LEVEL_ALERT     = 1;
  MCP_LOG_LEVEL_CRITICAL  = 2;
  MCP_LOG_LEVEL_ERROR     = 3;
  MCP_LOG_LEVEL_WARNING   = 4;
  MCP_LOG_LEVEL_NOTICE    = 5;
  MCP_LOG_LEVEL_INFO      = 6;
  MCP_LOG_LEVEL_DEBUG     = 7;

  /// MCP Level names (lowercase as per spec)
  MCP_LOG_LEVEL_NAMES: array[0..7] of RawUtf8 = (
    'emergency', 'alert', 'critical', 'error',
    'warning', 'notice', 'info', 'debug'
  );

  /// Default log level (info)
  MCP_LOG_LEVEL_DEFAULT = MCP_LOG_LEVEL_INFO;

type
  /// Logging capability manager for MCP protocol
  // - Provides logging/setLevel method
  // - Emits notifications/message via event bus
  TMCPLoggingManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    fCurrentLevel: Integer;
    fLock: TRTLCriticalSection;
    function GetCurrentLevel: Integer;
    procedure SetCurrentLevel(Value: Integer);
  public
    constructor Create;
    destructor Destroy; override;

    /// IMCPCapabilityManager implementation
    function GetCapabilityName: RawUtf8;
    function HandlesMethod(const Method: RawUtf8): Boolean;
    function ExecuteMethod(const Method: RawUtf8; const Params: Variant): Variant;

    /// Set the logging level
    // - Level: MCP level string (debug, info, notice, warning, error, critical)
    // - Returns True if level was valid and set
    function SetLevel(const Level: RawUtf8): Boolean;

    /// Get the current logging level as string
    function GetLevel: RawUtf8;

    /// Get the current logging level as numeric RFC 5424 value
    function GetLevelNumeric: Integer;

    /// Log a message at specified level
    // - Level: RFC 5424 numeric level (0-7)
    // - Message: The message text
    // - Only emits notification if level <= current level
    procedure LogMessage(Level: Integer; const Message: RawUtf8); overload;

    /// Log a message at specified level with logger name
    // - Level: RFC 5424 numeric level (0-7)
    // - Message: The message text
    // - Logger: Logger name
    procedure LogMessage(Level: Integer; const Message, Logger: RawUtf8); overload;

    /// Log a message at specified level with all options
    // - Level: RFC 5424 numeric level (0-7)
    // - Message: The message text
    // - Logger: Logger name (can be empty)
    // - Data: Additional data as variant
    procedure LogMessage(Level: Integer; const Message, Logger: RawUtf8;
      const Data: Variant); overload;

    /// Log a message at specified level (string level name)
    // - LevelName: MCP level string (debug, info, notice, warning, error, critical)
    // - Message: The message text
    procedure LogMessageByName(const LevelName, Message: RawUtf8); overload;

    /// Log a message at specified level (string level name) with logger
    // - LevelName: MCP level string (debug, info, notice, warning, error, critical)
    // - Message: The message text
    // - Logger: Logger name
    procedure LogMessageByName(const LevelName, Message, Logger: RawUtf8); overload;

    /// Log a message at specified level (string level name) with all options
    // - LevelName: MCP level string (debug, info, notice, warning, error, critical)
    // - Message: The message text
    // - Logger: Logger name (can be empty)
    // - Data: Additional data as variant
    procedure LogMessageByName(const LevelName, Message, Logger: RawUtf8;
      const Data: Variant); overload;

    /// Current log level (thread-safe access)
    property CurrentLevel: Integer read GetCurrentLevel write SetCurrentLevel;
  end;

/// Parse MCP log level string to RFC 5424 numeric value
// - Returns -1 if invalid level name
function MCPLogLevelFromString(const Level: RawUtf8): Integer;

/// Convert RFC 5424 numeric level to MCP level string
// - Returns 'info' for out-of-range values
function MCPLogLevelToString(Level: Integer): RawUtf8;

/// Check if a level should be logged given current minimum level
// - MessageLevel: The level of the message to log
// - CurrentMinLevel: The current minimum level setting
// - Returns True if message should be logged (lower number = higher priority)
function ShouldLog(MessageLevel, CurrentMinLevel: Integer): Boolean;

implementation

uses
  MCP.Events;

function MCPLogLevelFromString(const Level: RawUtf8): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(MCP_LOG_LEVEL_NAMES) do
    if IdemPropNameU(Level, MCP_LOG_LEVEL_NAMES[i]) then
    begin
      Result := i;
      Exit;
    end;
end;

function MCPLogLevelToString(Level: Integer): RawUtf8;
begin
  if (Level >= 0) and (Level <= High(MCP_LOG_LEVEL_NAMES)) then
    Result := MCP_LOG_LEVEL_NAMES[Level]
  else
    Result := MCP_LOG_LEVEL_NAMES[MCP_LOG_LEVEL_INFO]; // Default to info
end;

function ShouldLog(MessageLevel, CurrentMinLevel: Integer): Boolean;
begin
  // RFC 5424: Lower number = higher priority
  // A message should be logged if its priority is >= current level setting
  // i.e., if its numeric value is <= current level numeric value
  Result := MessageLevel <= CurrentMinLevel;
end;

{ TMCPLoggingManager }

constructor TMCPLoggingManager.Create;
begin
  inherited Create;
  InitializeCriticalSection(fLock);
  fCurrentLevel := MCP_LOG_LEVEL_DEFAULT;
end;

destructor TMCPLoggingManager.Destroy;
begin
  DeleteCriticalSection(fLock);
  inherited;
end;

function TMCPLoggingManager.GetCurrentLevel: Integer;
begin
  EnterCriticalSection(fLock);
  try
    Result := fCurrentLevel;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

procedure TMCPLoggingManager.SetCurrentLevel(Value: Integer);
begin
  EnterCriticalSection(fLock);
  try
    if (Value >= 0) and (Value <= MCP_LOG_LEVEL_DEBUG) then
      fCurrentLevel := Value;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TMCPLoggingManager.GetCapabilityName: RawUtf8;
begin
  Result := 'logging';
end;

function TMCPLoggingManager.HandlesMethod(const Method: RawUtf8): Boolean;
begin
  Result := IdemPropNameU(Method, 'logging/setLevel');
end;

function TMCPLoggingManager.ExecuteMethod(const Method: RawUtf8;
  const Params: Variant): Variant;
var
  ParamsDoc: PDocVariantData;
  Level: RawUtf8;
begin
  VarClear(Result);

  if IdemPropNameU(Method, 'logging/setLevel') then
  begin
    // Extract level parameter
    ParamsDoc := _Safe(Params);
    Level := ParamsDoc^.U['level'];

    if Level = '' then
      raise EMCPError.Create('Missing required parameter: level');

    if not SetLevel(Level) then
      raise EMCPError.CreateFmt('Invalid log level: %s', [Level]);

    // Return empty object on success per MCP spec
    Result := _ObjFast([]);

    TSynLog.Add.Log(sllInfo, 'MCP Logging level set to: %', [Level]);
  end
  else
    raise EMCPError.CreateFmt('Method %s not handled by %s',
      [Method, GetCapabilityName]);
end;

function TMCPLoggingManager.SetLevel(const Level: RawUtf8): Boolean;
var
  NumericLevel: Integer;
begin
  NumericLevel := MCPLogLevelFromString(Level);
  Result := NumericLevel >= 0;
  if Result then
    CurrentLevel := NumericLevel;
end;

function TMCPLoggingManager.GetLevel: RawUtf8;
begin
  Result := MCPLogLevelToString(GetCurrentLevel);
end;

function TMCPLoggingManager.GetLevelNumeric: Integer;
begin
  Result := GetCurrentLevel;
end;

procedure TMCPLoggingManager.LogMessage(Level: Integer; const Message: RawUtf8);
var
  EmptyData: Variant;
begin
  VarClear(EmptyData);
  LogMessage(Level, Message, '', EmptyData);
end;

procedure TMCPLoggingManager.LogMessage(Level: Integer;
  const Message, Logger: RawUtf8);
var
  EmptyData: Variant;
begin
  VarClear(EmptyData);
  LogMessage(Level, Message, Logger, EmptyData);
end;

procedure TMCPLoggingManager.LogMessage(Level: Integer;
  const Message, Logger: RawUtf8; const Data: Variant);
var
  NotificationData: Variant;
begin
  // Check if this level should be logged
  if not ShouldLog(Level, GetCurrentLevel) then
    Exit;

  // Build notification data per MCP spec
  // Format: { level: string, logger?: string, data?: any, message: string }
  TDocVariantData(NotificationData).InitFast;
  TDocVariantData(NotificationData).U['level'] := MCPLogLevelToString(Level);
  if Logger <> '' then
    TDocVariantData(NotificationData).U['logger'] := Logger;
  if not VarIsEmpty(Data) and not VarIsNull(Data) then
    TDocVariantData(NotificationData).AddValue('data', Data);
  TDocVariantData(NotificationData).U['message'] := Message;

  // Emit via event bus
  MCPEventBus.Publish(MCP_EVENT_MESSAGE, NotificationData);

  // Also log to mORMot's logging system
  case Level of
    MCP_LOG_LEVEL_EMERGENCY,
    MCP_LOG_LEVEL_ALERT,
    MCP_LOG_LEVEL_CRITICAL:
      TSynLog.Add.Log(sllError, 'MCP [%]: %', [MCPLogLevelToString(Level), Message]);
    MCP_LOG_LEVEL_ERROR:
      TSynLog.Add.Log(sllError, 'MCP [error]: %', [Message]);
    MCP_LOG_LEVEL_WARNING:
      TSynLog.Add.Log(sllWarning, 'MCP [warning]: %', [Message]);
    MCP_LOG_LEVEL_NOTICE,
    MCP_LOG_LEVEL_INFO:
      TSynLog.Add.Log(sllInfo, 'MCP [%]: %', [MCPLogLevelToString(Level), Message]);
    MCP_LOG_LEVEL_DEBUG:
      TSynLog.Add.Log(sllDebug, 'MCP [debug]: %', [Message]);
  end;
end;

procedure TMCPLoggingManager.LogMessageByName(const LevelName, Message: RawUtf8);
var
  EmptyData: Variant;
begin
  VarClear(EmptyData);
  LogMessageByName(LevelName, Message, '', EmptyData);
end;

procedure TMCPLoggingManager.LogMessageByName(const LevelName, Message,
  Logger: RawUtf8);
var
  EmptyData: Variant;
begin
  VarClear(EmptyData);
  LogMessageByName(LevelName, Message, Logger, EmptyData);
end;

procedure TMCPLoggingManager.LogMessageByName(const LevelName, Message,
  Logger: RawUtf8; const Data: Variant);
var
  NumericLevel: Integer;
begin
  NumericLevel := MCPLogLevelFromString(LevelName);
  if NumericLevel < 0 then
    NumericLevel := MCP_LOG_LEVEL_INFO; // Default to info for unknown levels
  LogMessage(NumericLevel, Message, Logger, Data);
end;

end.
