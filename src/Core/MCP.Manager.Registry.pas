/// MCP Manager Registry
// - Registers and dispatches to capability managers
unit MCP.Manager.Registry;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.data,
  MCP.Types;

type
  /// Registry for MCP capability managers
  TMCPManagerRegistry = class(TInterfacedObject, IMCPManagerRegistry)
  private
    fManagers: array of IMCPCapabilityManager;
  public
    constructor Create;
    destructor Destroy; override;
    /// Register a capability manager
    procedure RegisterManager(const Manager: IMCPCapabilityManager);
    /// Get the manager that handles a specific method
    function GetManagerForMethod(const Method: RawUtf8): IMCPCapabilityManager;
  end;

implementation

{ TMCPManagerRegistry }

constructor TMCPManagerRegistry.Create;
begin
  inherited Create;
  SetLength(fManagers, 0);
end;

destructor TMCPManagerRegistry.Destroy;
begin
  SetLength(fManagers, 0);
  inherited;
end;

procedure TMCPManagerRegistry.RegisterManager(const Manager: IMCPCapabilityManager);
var
  i: PtrInt;
begin
  // Check if already registered
  for i := 0 to High(fManagers) do
    if fManagers[i] = Manager then
      Exit;

  // Add to list
  SetLength(fManagers, Length(fManagers) + 1);
  fManagers[High(fManagers)] := Manager;
end;

function TMCPManagerRegistry.GetManagerForMethod(
  const Method: RawUtf8): IMCPCapabilityManager;
var
  i: PtrInt;
begin
  Result := nil;
  for i := 0 to High(fManagers) do
    if fManagers[i].HandlesMethod(Method) then
    begin
      Result := fManagers[i];
      Exit;
    end;
end;

end.
