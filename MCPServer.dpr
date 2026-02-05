/// mORMot2 MCP Server - Console Application
// - High-performance MCP server using mORMot2 framework
// - Supports multiple transports: stdio, http
program MCPServer;

{$I mormot.defines.inc}

{$APPTYPE CONSOLE}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.log,
  mormot.core.rtti,
  mormot.core.variants,
  mormot.core.json,
  MCP.Types in 'src\Protocol\MCP.Types.pas',
  MCP.Server in 'src\Server\MCP.Server.pas',
  MCP.Manager.Registry in 'src\Core\MCP.Manager.Registry.pas',
  MCP.Events in 'src\Core\MCP.Events.pas',
  MCP.Manager.Core in 'src\Managers\MCP.Manager.Core.pas',
  MCP.Manager.Logging in 'src\Managers\MCP.Manager.Logging.pas',
  MCP.Manager.Tools in 'src\Managers\MCP.Manager.Tools.pas',
  MCP.Tool.Base in 'src\Tools\MCP.Tool.Base.pas',
  MCP.Tool.Echo in 'src\Tools\MCP.Tool.Echo.pas',
  MCP.Tool.GetTime in 'src\Tools\MCP.Tool.GetTime.pas',
  MCP.Resource.Base in 'src\Resources\MCP.Resource.Base.pas',
  MCP.Manager.Resources in 'src\Managers\MCP.Manager.Resources.pas',
  MCP.Prompt.Base in 'src\Prompts\MCP.Prompt.Base.pas',
  MCP.Manager.Prompts in 'src\Managers\MCP.Manager.Prompts.pas',
  MCP.Manager.Completion in 'src\Managers\MCP.Manager.Completion.pas',
  MCP.Transport.Base in 'src\Transport\MCP.Transport.Base.pas',
  MCP.Transport.Http in 'src\Transport\MCP.Transport.Http.pas',
  MCP.Transport.Stdio in 'src\Transport\MCP.Transport.Stdio.pas';

type
  /// Helper class to provide request handler method
  TMCPRequestProcessor = class
  private
    fRegistry: IMCPManagerRegistry;
  public
    constructor Create(ARegistry: IMCPManagerRegistry);
    function HandleRequest(const RequestJson: RawUtf8;
      const SessionId: RawUtf8): RawUtf8;
    property Registry: IMCPManagerRegistry read fRegistry;
  end;

var
  Settings: TMCPServerSettings;
  Registry: IMCPManagerRegistry;
  CoreManager: TMCPCoreManager;
  LoggingManager: TMCPLoggingManager;
  ToolsManager: TMCPToolsManager;
  ResourcesManager: TMCPResourcesManager;
  PromptsManager: TMCPPromptsManager;
  CompletionManager: TMCPCompletionManager;
  TransportType: TMCPTransportType;
  TransportTypeStr: RawUtf8;
  TransportConfig: TMCPTransportConfig;
  RequestProcessor: TMCPRequestProcessor;

{ TMCPRequestProcessor }

constructor TMCPRequestProcessor.Create(ARegistry: IMCPManagerRegistry);
begin
  inherited Create;
  fRegistry := ARegistry;
end;

function TMCPRequestProcessor.HandleRequest(const RequestJson: RawUtf8;
  const SessionId: RawUtf8): RawUtf8;
var
  Request, Response: Variant;
  RequestId: Variant;
  Method: RawUtf8;
  Params: Variant;
  Manager: IMCPCapabilityManager;
  MethodResult: Variant;
begin
  Result := '';

  try
    TDocVariantData(Request).InitJson(RequestJson, JSON_FAST_FLOAT);
    RequestId := TDocVariantData(Request).Value['id'];
    Method := TDocVariantData(Request).U['method'];

    // Handle notifications (no response needed)
    if Method = 'notifications/initialized' then
    begin
      TSynLog.Add.Log(sllInfo, 'MCP Initialized notification received');
      Exit;
    end;

    if fRegistry = nil then
    begin
      Result := CreateJsonRpcError(RequestId, JSONRPC_INTERNAL_ERROR,
        'Manager registry not initialized');
      Exit;
    end;

    Manager := fRegistry.GetManagerForMethod(Method);
    if Manager = nil then
    begin
      Result := CreateJsonRpcError(RequestId, JSONRPC_METHOD_NOT_FOUND,
        FormatUtf8('Method [%] not found', [Method]));
      Exit;
    end;

    Params := TDocVariantData(Request).Value['params'];
    MethodResult := Manager.ExecuteMethod(Method, Params);

    Response := CreateJsonRpcResponse(RequestId);
    if not VarIsEmptyOrNull(MethodResult) then
      TDocVariantData(Response).AddValue('result', MethodResult);

    Result := TDocVariantData(Response).ToJson;

  except
    on E: Exception do
    begin
      TSynLog.Add.Log(sllError, 'Error processing request: %', [E.Message]);
      Result := CreateJsonRpcError(RequestId, JSONRPC_INTERNAL_ERROR,
        StringToUtf8(E.Message));
    end;
  end;
end;

procedure InitializeLogging;
begin
  with TSynLog.Family do
  begin
    Level := LOG_VERBOSE;
    DestinationPath := Executable.ProgramFilePath;
    PerThreadLog := ptIdentifiedInOneFile;
    RotateFileCount := 5;
    RotateFileSizeKB := 10240; // 10MB
  end;
end;

procedure RegisterTools(Manager: TMCPToolsManager);
begin
  // Register built-in tools
  Manager.RegisterTool(TMCPToolEcho);
  Manager.RegisterTool(TMCPToolGetTime);

  // Add more tools here...
end;

function HasSwitch(const Name: string): Boolean;
var
  I: Integer;
  S: string;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (S = '--' + Name) or (S = '-' + Name) or (S = '/' + Name) then
      Exit(True);
  end;
end;

function GetSwitchValue(const Name: string): string;
var
  I: Integer;
  S, Prefix: string;
begin
  Result := '';
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    // Check for --name=value format
    Prefix := '--' + Name + '=';
    if Copy(S, 1, Length(Prefix)) = Prefix then
    begin
      Result := Copy(S, Length(Prefix) + 1, MaxInt);
      Exit;
    end;
    // Check for --name value format
    if (S = '--' + Name) or (S = '-' + Name) or (S = '/' + Name) then
    begin
      if I < ParamCount then
        Result := ParamStr(I + 1);
      Exit;
    end;
  end;
end;

procedure ParseCommandLine;
var
  I: Integer;
  S: string;
begin
  I := 1;
  while I <= ParamCount do
  begin
    S := ParamStr(I);
    if (S = '--port') or (S = '-p') or (S = '/port') then
    begin
      Inc(I);
      if I <= ParamCount then
        Settings.Port := StrToIntDef(ParamStr(I), Settings.Port);
    end
    else if (Length(S) > 0) and not CharInSet(S[1], ['-', '/']) then
      // Bare number = port
      Settings.Port := StrToIntDef(S, Settings.Port);
    Inc(I);
  end;

  // Parse transport type
  TransportTypeStr := StringToUtf8(GetSwitchValue('transport'));
  if TransportTypeStr = '' then
    TransportTypeStr := 'http';
  TransportType := TMCPTransportFactory.ParseTransportType(TransportTypeStr);
end;

procedure RunWithTransport;
var
  IsDaemon: Boolean;
  HttpTransport: TMCPHttpTransport;
  StdioTransport: TMCPStdioTransport;
  ShutdownSuccess: Boolean;
begin
  IsDaemon := HasSwitch('daemon') or HasSwitch('d');

  // Create transport config from settings
  TransportConfig := TMCPTransportFactory.ConfigFromSettings(TransportType, Settings);

  case TransportType of
    mttStdio:
      begin
        // Stdio mode - minimal output, just JSON
        // Signal handling and graceful shutdown is handled internally by the transport
        TSynLog.Add.Log(sllInfo, 'Starting MCP Server in stdio mode');

        StdioTransport := TMCPStdioTransport.Create(TransportConfig);
        try
          StdioTransport.ManagerRegistry := Registry;
          StdioTransport.SetRequestHandler(RequestProcessor.HandleRequest);
          StdioTransport.Start; // Blocks until EOF or SIGTERM/SIGINT
        finally
          StdioTransport.Free;
        end;
      end;

    mttHttp:
      begin
        WriteLn('mORMot2 MCP Server v1.0.0');
        WriteLn('========================');
        WriteLn('Transport: HTTP');
        WriteLn;

        if Settings.Port <> 3000 then
          WriteLn('Port: ', Settings.Port);

        HttpTransport := TMCPHttpTransport.Create(TransportConfig);
        try
          HttpTransport.ManagerRegistry := Registry;
          HttpTransport.SetRequestHandler(RequestProcessor.HandleRequest);
          HttpTransport.Start;

          WriteLn;
          WriteLn('Server listening on http://', Settings.Host, ':',
            Settings.Port, Settings.Endpoint);

          if IsDaemon then
          begin
            WriteLn('Running in daemon mode. Press Ctrl+C to stop (graceful shutdown).');
            // Use ConsoleWaitForEnterKey which handles SIGTERM/SIGINT properly
            // and also responds to Enter key press
            ConsoleWaitForEnterKey;
            // Graceful shutdown with 5s timeout for pending requests
            WriteLn('Initiating graceful shutdown...');
            ShutdownSuccess := HttpTransport.GracefulShutdown(GRACEFUL_SHUTDOWN_TIMEOUT_MS);
            if not ShutdownSuccess then
              WriteLn('Warning: Some requests may not have completed');
          end
          else
          begin
            WriteLn('Press Enter to stop (graceful shutdown)...');
            WriteLn;
            ReadLn;
            // Graceful shutdown with 5s timeout for pending requests
            WriteLn('Initiating graceful shutdown...');
            ShutdownSuccess := HttpTransport.GracefulShutdown(GRACEFUL_SHUTDOWN_TIMEOUT_MS);
            if not ShutdownSuccess then
              WriteLn('Warning: Some requests may not have completed');
          end;
        finally
          HttpTransport.Free;
        end;

        WriteLn('Server stopped.');
      end;
  end;
end;

procedure Run;
begin
  // Initialize logging
  InitializeLogging;
  TSynLog.Add.Log(sllInfo, 'Starting mORMot2 MCP Server');

  // Initialize settings
  InitDefaultSettings(Settings);

  // Parse command line
  ParseCommandLine;

  // Create registry
  Registry := TMCPManagerRegistry.Create;

  // Create and register core manager
  CoreManager := TMCPCoreManager.Create(Settings);
  Registry.RegisterManager(CoreManager);

  // Create and register logging manager
  LoggingManager := TMCPLoggingManager.Create;
  Registry.RegisterManager(LoggingManager);

  // Create and register tools manager
  ToolsManager := TMCPToolsManager.Create;
  RegisterTools(ToolsManager);
  Registry.RegisterManager(ToolsManager);

  // Create and register resources manager
  ResourcesManager := TMCPResourcesManager.Create;
  Registry.RegisterManager(ResourcesManager);

  // Create and register prompts manager
  PromptsManager := TMCPPromptsManager.Create;
  Registry.RegisterManager(PromptsManager);

  // Create and register completion manager
  CompletionManager := TMCPCompletionManager.Create;
  Registry.RegisterManager(CompletionManager);

  // Create request processor
  RequestProcessor := TMCPRequestProcessor.Create(Registry);
  try
    // Run with new transport system (supports both stdio and HTTP with SSE)
    RunWithTransport;
  finally
    RequestProcessor.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      // For stdio mode, output error as JSON-RPC error
      if TransportType = mttStdio then
        WriteLn(CreateJsonRpcError(Null, JSONRPC_INTERNAL_ERROR,
          StringToUtf8('Fatal error: ' + E.Message)))
      else
      begin
        WriteLn('Error: ', E.Message);
        TSynLog.Add.Log(sllError, 'Fatal error: %', [E.Message]);
      end;
      ExitCode := 1;
    end;
  end;
end.
