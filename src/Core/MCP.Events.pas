/// MCP Event Bus for Notifications
// - Thread-safe singleton event bus for MCP notifications
// - Supports subscribe/publish pattern with pending queue
unit MCP.Events;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.unicode,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.rtti;

const
  /// Standard MCP notification event types
  MCP_EVENT_TOOLS_LIST_CHANGED = 'notifications/tools/list_changed';
  MCP_EVENT_RESOURCES_LIST_CHANGED = 'notifications/resources/list_changed';
  MCP_EVENT_RESOURCES_UPDATED = 'notifications/resources/updated';
  MCP_EVENT_PROMPTS_LIST_CHANGED = 'notifications/prompts/list_changed';
  MCP_EVENT_MESSAGE = 'notifications/message';
  MCP_EVENT_PROGRESS = 'notifications/progress';
  MCP_EVENT_CANCELLED = 'notifications/cancelled';

type
  /// Callback type for event subscribers
  // Data parameter contains event-specific information as TDocVariant
  TMCPEventCallback = procedure(const Data: Variant) of object;

  /// Internal record for storing subscriber information
  TMCPEventSubscription = record
    EventType: RawUtf8;
    Callback: TMCPEventCallback;
  end;

  /// Dynamic array type for subscriptions
  TMCPEventSubscriptionArray = array of TMCPEventSubscription;

  /// Internal record for pending events (queued when no subscribers)
  TMCPPendingEvent = record
    EventType: RawUtf8;
    Data: Variant;
  end;

  /// Dynamic array type for pending events
  TMCPPendingEventArray = array of TMCPPendingEvent;

  /// Thread-safe singleton event bus for MCP notifications
  // - Subscribe to specific event types
  // - Publish events to all subscribers
  // - Queues events if no subscribers available
  TMCPEventBus = class
  private
    fLock: TRTLCriticalSection;
    fSubscriptions: TMCPEventSubscriptionArray;
    fPendingEvents: TMCPPendingEventArray;
    class var fInstance: TMCPEventBus;
    class var fInstanceLock: TRTLCriticalSection;
    constructor CreateInstance;
    procedure DeliverPendingEvents(const EventType: RawUtf8);
  public
    class constructor Create;
    class destructor Destroy;
    destructor Destroy; override;

    /// Get the singleton instance
    class function GetInstance: TMCPEventBus;

    /// Subscribe to an event type
    // - EventType: The notification type to subscribe to (e.g., 'notifications/tools/list_changed')
    // - Callback: Method to call when event is published
    procedure Subscribe(const EventType: RawUtf8; Callback: TMCPEventCallback);

    /// Unsubscribe from an event type
    // - EventType: The notification type to unsubscribe from
    // - Callback: The specific callback to remove
    procedure Unsubscribe(const EventType: RawUtf8; Callback: TMCPEventCallback);

    /// Unsubscribe all callbacks for an event type
    // - EventType: The notification type to clear all subscribers for
    procedure UnsubscribeAll(const EventType: RawUtf8);

    /// Publish an event to all subscribers
    // - EventType: The notification type being published
    // - Data: Event-specific data as TDocVariant (can be empty)
    // - If no subscribers exist, event is queued for later delivery
    procedure Publish(const EventType: RawUtf8; const Data: Variant);

    /// Check if there are subscribers for an event type
    function HasSubscribers(const EventType: RawUtf8): Boolean;

    /// Get count of pending events for an event type
    function GetPendingCount(const EventType: RawUtf8): Integer;

    /// Clear all pending events for an event type
    procedure ClearPending(const EventType: RawUtf8);

    /// Clear all pending events
    procedure ClearAllPending;

    /// Get total subscriber count
    function GetSubscriberCount: Integer;
  end;

/// Helper function to get the event bus instance
function MCPEventBus: TMCPEventBus;

/// Emit a progress notification for a tool operation
// - ProgressToken: Token provided by the client in _meta.progressToken
// - Progress: Current progress value (e.g., 50)
// - Total: Total value for progress (e.g., 100), or 0 if unknown
// Note: If ProgressToken is empty, no notification is sent
procedure EmitProgress(const ProgressToken: RawUtf8; Progress: Integer; Total: Integer = 0);

implementation

function MCPEventBus: TMCPEventBus;
begin
  Result := TMCPEventBus.GetInstance;
end;

procedure EmitProgress(const ProgressToken: RawUtf8; Progress: Integer; Total: Integer);
var
  Data: Variant;
begin
  // Do not emit if no progress token was provided
  if ProgressToken = '' then
    Exit;

  TDocVariantData(Data).InitFast;
  TDocVariantData(Data).U['progressToken'] := ProgressToken;
  TDocVariantData(Data).I['progress'] := Progress;
  if Total > 0 then
    TDocVariantData(Data).I['total'] := Total;

  MCPEventBus.Publish(MCP_EVENT_PROGRESS, Data);
end;

{ TMCPEventBus }

class constructor TMCPEventBus.Create;
begin
  InitializeCriticalSection(fInstanceLock);
  fInstance := nil;
end;

class destructor TMCPEventBus.Destroy;
begin
  FreeAndNil(fInstance);
  DeleteCriticalSection(fInstanceLock);
end;

constructor TMCPEventBus.CreateInstance;
begin
  inherited Create;
  InitializeCriticalSection(fLock);
  SetLength(fSubscriptions, 0);
  SetLength(fPendingEvents, 0);
end;

destructor TMCPEventBus.Destroy;
begin
  EnterCriticalSection(fLock);
  try
    SetLength(fSubscriptions, 0);
    SetLength(fPendingEvents, 0);
  finally
    LeaveCriticalSection(fLock);
  end;
  DeleteCriticalSection(fLock);
  inherited;
end;

class function TMCPEventBus.GetInstance: TMCPEventBus;
begin
  if fInstance = nil then
  begin
    EnterCriticalSection(fInstanceLock);
    try
      if fInstance = nil then
        fInstance := TMCPEventBus.CreateInstance;
    finally
      LeaveCriticalSection(fInstanceLock);
    end;
  end;
  Result := fInstance;
end;

procedure TMCPEventBus.Subscribe(const EventType: RawUtf8; Callback: TMCPEventCallback);
var
  i, n: PtrInt;
begin
  if not Assigned(Callback) then
    Exit;

  EnterCriticalSection(fLock);
  try
    // Check if already subscribed
    for i := 0 to High(fSubscriptions) do
      if IdemPropNameU(fSubscriptions[i].EventType, EventType) and
         (@fSubscriptions[i].Callback = @Callback) then
        Exit; // Already subscribed

    // Add new subscription
    n := Length(fSubscriptions);
    SetLength(fSubscriptions, n + 1);
    fSubscriptions[n].EventType := EventType;
    fSubscriptions[n].Callback := Callback;

    TSynLog.Add.Log(sllDebug, 'EventBus: Subscribed to [%]', [EventType]);

    // Deliver any pending events for this type
    DeliverPendingEvents(EventType);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

procedure TMCPEventBus.Unsubscribe(const EventType: RawUtf8; Callback: TMCPEventCallback);
var
  i: PtrInt;
begin
  EnterCriticalSection(fLock);
  try
    for i := High(fSubscriptions) downto 0 do
      if IdemPropNameU(fSubscriptions[i].EventType, EventType) and
         (@fSubscriptions[i].Callback = @Callback) then
      begin
        // Remove by shifting remaining elements
        if i < High(fSubscriptions) then
          Move(fSubscriptions[i + 1], fSubscriptions[i],
            (High(fSubscriptions) - i) * SizeOf(TMCPEventSubscription));
        SetLength(fSubscriptions, Length(fSubscriptions) - 1);
        TSynLog.Add.Log(sllDebug, 'EventBus: Unsubscribed from [%]', [EventType]);
        Exit;
      end;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

procedure TMCPEventBus.UnsubscribeAll(const EventType: RawUtf8);
var
  i, j: PtrInt;
  NewSubscriptions: TMCPEventSubscriptionArray;
begin
  EnterCriticalSection(fLock);
  try
    j := 0;
    SetLength(NewSubscriptions, Length(fSubscriptions));
    for i := 0 to High(fSubscriptions) do
      if not IdemPropNameU(fSubscriptions[i].EventType, EventType) then
      begin
        NewSubscriptions[j] := fSubscriptions[i];
        Inc(j);
      end;
    SetLength(NewSubscriptions, j);
    fSubscriptions := NewSubscriptions;
    TSynLog.Add.Log(sllDebug, 'EventBus: Unsubscribed all from [%]', [EventType]);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

procedure TMCPEventBus.Publish(const EventType: RawUtf8; const Data: Variant);
var
  i, n: PtrInt;
  Delivered: Boolean;
  Callbacks: array of TMCPEventCallback;
begin
  EnterCriticalSection(fLock);
  try
    // Collect matching callbacks first (to avoid calling with lock held)
    SetLength(Callbacks, 0);
    for i := 0 to High(fSubscriptions) do
      if IdemPropNameU(fSubscriptions[i].EventType, EventType) then
      begin
        n := Length(Callbacks);
        SetLength(Callbacks, n + 1);
        Callbacks[n] := fSubscriptions[i].Callback;
      end;

    Delivered := Length(Callbacks) > 0;

    // If no subscribers, queue the event
    if not Delivered then
    begin
      n := Length(fPendingEvents);
      SetLength(fPendingEvents, n + 1);
      fPendingEvents[n].EventType := EventType;
      fPendingEvents[n].Data := Data;
      TSynLog.Add.Log(sllDebug, 'EventBus: Queued event [%] (no subscribers)', [EventType]);
    end;
  finally
    LeaveCriticalSection(fLock);
  end;

  // Deliver outside the lock to prevent deadlocks
  if Delivered then
  begin
    TSynLog.Add.Log(sllDebug, 'EventBus: Publishing [%] to % subscriber(s)',
      [EventType, Length(Callbacks)]);
    for i := 0 to High(Callbacks) do
    begin
      try
        Callbacks[i](Data);
      except
        on E: Exception do
          TSynLog.Add.Log(sllError, 'EventBus: Callback error for [%]: %',
            [EventType, E.Message]);
      end;
    end;
  end;
end;

procedure TMCPEventBus.DeliverPendingEvents(const EventType: RawUtf8);
var
  i, j: PtrInt;
  PendingToDeliver: TMCPPendingEventArray;
  NewPending: TMCPPendingEventArray;
begin
  // Must be called with lock held
  // Collect pending events for this type
  SetLength(PendingToDeliver, 0);
  SetLength(NewPending, 0);

  for i := 0 to High(fPendingEvents) do
    if IdemPropNameU(fPendingEvents[i].EventType, EventType) then
    begin
      j := Length(PendingToDeliver);
      SetLength(PendingToDeliver, j + 1);
      PendingToDeliver[j] := fPendingEvents[i];
    end
    else
    begin
      j := Length(NewPending);
      SetLength(NewPending, j + 1);
      NewPending[j] := fPendingEvents[i];
    end;

  fPendingEvents := NewPending;

  // Deliver pending events (still under lock, but subscribers just registered)
  if Length(PendingToDeliver) > 0 then
  begin
    TSynLog.Add.Log(sllDebug, 'EventBus: Delivering % pending event(s) for [%]',
      [Length(PendingToDeliver), EventType]);
    for i := 0 to High(PendingToDeliver) do
    begin
      // Find callbacks for this event type
      for j := 0 to High(fSubscriptions) do
        if IdemPropNameU(fSubscriptions[j].EventType, EventType) then
        begin
          try
            fSubscriptions[j].Callback(PendingToDeliver[i].Data);
          except
            on E: Exception do
              TSynLog.Add.Log(sllError, 'EventBus: Pending callback error for [%]: %',
                [EventType, E.Message]);
          end;
        end;
    end;
  end;
end;

function TMCPEventBus.HasSubscribers(const EventType: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  EnterCriticalSection(fLock);
  try
    for i := 0 to High(fSubscriptions) do
      if IdemPropNameU(fSubscriptions[i].EventType, EventType) then
      begin
        Result := True;
        Exit;
      end;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TMCPEventBus.GetPendingCount(const EventType: RawUtf8): Integer;
var
  i: PtrInt;
begin
  Result := 0;
  EnterCriticalSection(fLock);
  try
    for i := 0 to High(fPendingEvents) do
      if IdemPropNameU(fPendingEvents[i].EventType, EventType) then
        Inc(Result);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

procedure TMCPEventBus.ClearPending(const EventType: RawUtf8);
var
  i, j: PtrInt;
  NewPending: TMCPPendingEventArray;
begin
  EnterCriticalSection(fLock);
  try
    SetLength(NewPending, 0);
    for i := 0 to High(fPendingEvents) do
      if not IdemPropNameU(fPendingEvents[i].EventType, EventType) then
      begin
        j := Length(NewPending);
        SetLength(NewPending, j + 1);
        NewPending[j] := fPendingEvents[i];
      end;
    fPendingEvents := NewPending;
    TSynLog.Add.Log(sllDebug, 'EventBus: Cleared pending events for [%]', [EventType]);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

procedure TMCPEventBus.ClearAllPending;
begin
  EnterCriticalSection(fLock);
  try
    SetLength(fPendingEvents, 0);
    TSynLog.Add.Log(sllDebug, 'EventBus: Cleared all pending events');
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TMCPEventBus.GetSubscriberCount: Integer;
begin
  EnterCriticalSection(fLock);
  try
    Result := Length(fSubscriptions);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

end.
