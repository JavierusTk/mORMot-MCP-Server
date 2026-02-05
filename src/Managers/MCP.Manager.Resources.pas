/// MCP Resources Manager
// - Manages resource registration, listing, reading, and templates
unit MCP.Manager.Resources;

{$I mormot.defines.inc}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.variants,
  mormot.core.json,
  mormot.core.log,
  mormot.core.os,
  mormot.core.rtti,
  MCP.Types,
  MCP.Resource.Base,
  MCP.Events;

const
  /// Default page size for resources/list pagination
  MCP_RESOURCES_DEFAULT_LIMIT = 100;

type
  /// Resource template definition following RFC 6570 URI template syntax
  // - Used for parameterized resource access where clients can construct
  //   specific URIs by replacing variables in the template
  TMCPResourceTemplate = record
    /// URI template following RFC 6570 syntax (e.g., 'file://{path}')
    UriTemplate: RawUtf8;
    /// Human-readable name for the template
    Name: RawUtf8;
    /// Description of what resources this template provides
    Description: RawUtf8;
    /// Optional MIME type hint for resources from this template
    MimeType: RawUtf8;
  end;

  TMCPResourceTemplateArray = array of TMCPResourceTemplate;

  /// Internal record for tracking resource subscriptions
  TMCPResourceSubscription = record
    /// URI of the subscribed resource
    Uri: RawUtf8;
    /// Subscription count (multiple subscribers can subscribe to same resource)
    Count: Integer;
  end;

  TMCPResourceSubscriptionArray = array of TMCPResourceSubscription;

  /// Resources capability manager for MCP protocol
  TMCPResourcesManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    fLock: TRTLCriticalSection;
    fResources: array of IMCPResource;
    fTemplates: TMCPResourceTemplateArray;
    fSubscriptions: TMCPResourceSubscriptionArray;
    function FindResource(const Uri: RawUtf8): IMCPResource;
    function FindResourceIndex(const Uri: RawUtf8): PtrInt;
    function FindTemplateIndex(const UriTemplate: RawUtf8): PtrInt;
    function FindSubscriptionIndex(const Uri: RawUtf8): PtrInt;
  public
    constructor Create;
    destructor Destroy; override;
    /// Register a resource
    procedure RegisterResource(const Resource: IMCPResource); overload;
    /// Register a resource by class (creates instance)
    procedure RegisterResource(ResourceClass: TMCPResourceClass); overload;
    /// Unregister a resource by URI
    function UnregisterResource(const Uri: RawUtf8): Boolean;
    /// Register a resource template (RFC 6570 URI template)
    // - UriTemplate: URI template string (e.g., 'file://{path}')
    // - Name: human-readable name
    // - Description: what this template provides
    // - MimeType: optional MIME type hint
    procedure RegisterTemplate(const UriTemplate, Name, Description: RawUtf8;
      const MimeType: RawUtf8 = ''); overload;
    /// Register a resource template from record
    procedure RegisterTemplate(const Template: TMCPResourceTemplate); overload;
    /// Unregister a template by URI template
    function UnregisterTemplate(const UriTemplate: RawUtf8): Boolean;
    /// IMCPCapabilityManager implementation
    function GetCapabilityName: RawUtf8;
    function HandlesMethod(const Method: RawUtf8): Boolean;
    function ExecuteMethod(const Method: RawUtf8; const Params: Variant): Variant;
    /// List all registered resources (with pagination)
    // - Cursor: opaque string for pagination (empty for first page)
    // - Limit: maximum number of resources to return (default 100)
    function ListResources(const Cursor: RawUtf8; Limit: Integer): Variant;
    /// Read a specific resource by URI
    // - Uri: unique identifier of the resource
    // - Raises EMCPResourceNotFound if resource doesn't exist
    function ReadResource(const Uri: RawUtf8): Variant;
    /// List all registered resource templates
    function ListTemplates: Variant;
    /// Get count of registered resources
    function GetResourceCount: Integer;
    /// Get count of registered templates
    function GetTemplateCount: Integer;
    /// Subscribe to resource updates
    // - Uri: unique identifier of the resource to subscribe to
    // - Returns success result
    function SubscribeResource(const Uri: RawUtf8): Variant;
    /// Unsubscribe from resource updates
    // - Uri: unique identifier of the resource to unsubscribe from
    // - Returns success result
    function UnsubscribeResource(const Uri: RawUtf8): Variant;
    /// Notify subscribers that a resource has been updated
    // - Uri: unique identifier of the updated resource
    // - Call this when resource content changes
    procedure NotifyResourceUpdated(const Uri: RawUtf8);
    /// Check if a resource has active subscriptions
    function HasSubscription(const Uri: RawUtf8): Boolean;
    /// Get count of active subscriptions
    function GetSubscriptionCount: Integer;
  end;

  /// Exception raised when a resource is not found
  EMCPResourceNotFound = class(EMCPError)
  public
    constructor Create(const Uri: RawUtf8);
  end;

implementation

{ EMCPResourceNotFound }

constructor EMCPResourceNotFound.Create(const Uri: RawUtf8);
begin
  inherited CreateFmt('Resource not found: %s', [Uri]);
end;

{ TMCPResourcesManager }

constructor TMCPResourcesManager.Create;
begin
  inherited Create;
  InitializeCriticalSection(fLock);
  SetLength(fResources, 0);
  SetLength(fTemplates, 0);
  SetLength(fSubscriptions, 0);
end;

destructor TMCPResourcesManager.Destroy;
begin
  EnterCriticalSection(fLock);
  try
    SetLength(fResources, 0);
    SetLength(fTemplates, 0);
    SetLength(fSubscriptions, 0);
  finally
    LeaveCriticalSection(fLock);
  end;
  DeleteCriticalSection(fLock);
  inherited;
end;

function TMCPResourcesManager.FindResource(const Uri: RawUtf8): IMCPResource;
var
  i: PtrInt;
begin
  Result := nil;
  for i := 0 to High(fResources) do
    if fResources[i].GetUri = Uri then
    begin
      Result := fResources[i];
      Exit;
    end;
end;

function TMCPResourcesManager.FindResourceIndex(const Uri: RawUtf8): PtrInt;
var
  i: PtrInt;
begin
  Result := -1;
  for i := 0 to High(fResources) do
    if fResources[i].GetUri = Uri then
    begin
      Result := i;
      Exit;
    end;
end;

function TMCPResourcesManager.FindTemplateIndex(const UriTemplate: RawUtf8): PtrInt;
var
  i: PtrInt;
begin
  Result := -1;
  for i := 0 to High(fTemplates) do
    if fTemplates[i].UriTemplate = UriTemplate then
    begin
      Result := i;
      Exit;
    end;
end;

function TMCPResourcesManager.FindSubscriptionIndex(const Uri: RawUtf8): PtrInt;
var
  i: PtrInt;
begin
  Result := -1;
  for i := 0 to High(fSubscriptions) do
    if fSubscriptions[i].Uri = Uri then
    begin
      Result := i;
      Exit;
    end;
end;

procedure TMCPResourcesManager.RegisterResource(const Resource: IMCPResource);
var
  i: PtrInt;
begin
  EnterCriticalSection(fLock);
  try
    // Check if already registered
    for i := 0 to High(fResources) do
      if fResources[i].GetUri = Resource.GetUri then
        Exit;

    // Add to list
    SetLength(fResources, Length(fResources) + 1);
    fResources[High(fResources)] := Resource;

    TSynLog.Add.Log(sllInfo, 'Registered resource: %', [Resource.GetUri]);
  finally
    LeaveCriticalSection(fLock);
  end;

  // Emit resources/list_changed notification (outside lock)
  MCPEventBus.Publish(MCP_EVENT_RESOURCES_LIST_CHANGED, _ObjFast([]));
end;

procedure TMCPResourcesManager.RegisterResource(ResourceClass: TMCPResourceClass);
var
  Resource: TMCPResourceBase;
begin
  Resource := ResourceClass.Create;
  RegisterResource(Resource);
end;

function TMCPResourcesManager.UnregisterResource(const Uri: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  EnterCriticalSection(fLock);
  try
    i := FindResourceIndex(Uri);
    if i >= 0 then
    begin
      // Remove by shifting remaining elements
      if i < High(fResources) then
        Move(fResources[i + 1], fResources[i],
          (High(fResources) - i) * SizeOf(IMCPResource));
      SetLength(fResources, Length(fResources) - 1);

      TSynLog.Add.Log(sllInfo, 'Unregistered resource: %', [Uri]);
      Result := True;
    end;
  finally
    LeaveCriticalSection(fLock);
  end;

  // Emit resources/list_changed notification if something was removed
  if Result then
    MCPEventBus.Publish(MCP_EVENT_RESOURCES_LIST_CHANGED, _ObjFast([]));
end;

function TMCPResourcesManager.GetCapabilityName: RawUtf8;
begin
  Result := 'resources';
end;

function TMCPResourcesManager.HandlesMethod(const Method: RawUtf8): Boolean;
begin
  Result := IdemPropNameU(Method, 'resources/list') or
            IdemPropNameU(Method, 'resources/read') or
            IdemPropNameU(Method, 'resources/templates/list') or
            IdemPropNameU(Method, 'resources/subscribe') or
            IdemPropNameU(Method, 'resources/unsubscribe');
end;

function TMCPResourcesManager.ExecuteMethod(const Method: RawUtf8;
  const Params: Variant): Variant;
var
  ParamsDoc: PDocVariantData;
  Cursor, Uri: RawUtf8;
  Limit: Integer;
begin
  ParamsDoc := _Safe(Params);

  if IdemPropNameU(Method, 'resources/list') then
  begin
    Cursor := ParamsDoc^.U['cursor'];
    Limit := ParamsDoc^.I['limit'];
    if Limit <= 0 then
      Limit := MCP_RESOURCES_DEFAULT_LIMIT;
    Result := ListResources(Cursor, Limit);
  end
  else if IdemPropNameU(Method, 'resources/read') then
  begin
    Uri := ParamsDoc^.U['uri'];
    if Uri = '' then
      raise Exception.Create('[uri] property not found');
    Result := ReadResource(Uri);
  end
  else if IdemPropNameU(Method, 'resources/templates/list') then
  begin
    Result := ListTemplates;
  end
  else if IdemPropNameU(Method, 'resources/subscribe') then
  begin
    Uri := ParamsDoc^.U['uri'];
    if Uri = '' then
      raise Exception.Create('[uri] property not found');
    Result := SubscribeResource(Uri);
  end
  else if IdemPropNameU(Method, 'resources/unsubscribe') then
  begin
    Uri := ParamsDoc^.U['uri'];
    if Uri = '' then
      raise Exception.Create('[uri] property not found');
    Result := UnsubscribeResource(Uri);
  end
  else
    raise Exception.CreateFmt('Method %s not handled by %s',
      [Method, GetCapabilityName]);
end;

function TMCPResourcesManager.ListResources(const Cursor: RawUtf8;
  Limit: Integer): Variant;
var
  Resources, ResourceInfo: Variant;
  i, StartIndex, EndIndex, Count: PtrInt;
  NextCursor: RawUtf8;
  Res: IMCPResource;
begin
  TSynLog.Add.Log(sllInfo, 'MCP resources/list called (cursor=%, limit=%)',
    [Cursor, Limit]);

  TDocVariantData(Result).InitFast;
  TDocVariantData(Resources).InitArray([], JSON_FAST);

  EnterCriticalSection(fLock);
  try
    Count := Length(fResources);

    // Parse cursor to get start index (cursor is a simple integer index)
    if Cursor = '' then
      StartIndex := 0
    else
      StartIndex := GetInteger(Pointer(Cursor));

    // Clamp start index
    if StartIndex < 0 then
      StartIndex := 0;
    if StartIndex >= Count then
      StartIndex := Count;

    // Calculate end index
    EndIndex := StartIndex + Limit;
    if EndIndex > Count then
      EndIndex := Count;

    // Build resources array
    for i := StartIndex to EndIndex - 1 do
    begin
      Res := fResources[i];
      TDocVariantData(ResourceInfo).InitFast;
      TDocVariantData(ResourceInfo).U['uri'] := Res.GetUri;
      TDocVariantData(ResourceInfo).U['name'] := Res.GetName;
      if Res.GetDescription <> '' then
        TDocVariantData(ResourceInfo).U['description'] := Res.GetDescription;
      if Res.GetMimeType <> '' then
        TDocVariantData(ResourceInfo).U['mimeType'] := Res.GetMimeType;
      TDocVariantData(Resources).AddItem(ResourceInfo);
    end;

    // Set next cursor if there are more results
    if EndIndex < Count then
      NextCursor := Int32ToUtf8(EndIndex);
  finally
    LeaveCriticalSection(fLock);
  end;

  TDocVariantData(Result).AddValue('resources', Resources);
  if NextCursor <> '' then
    TDocVariantData(Result).U['nextCursor'] := NextCursor;
end;

function TMCPResourcesManager.ReadResource(const Uri: RawUtf8): Variant;
var
  Resource: IMCPResource;
  Contents, ContentItem: Variant;
  RawContent: RawByteString;
  ContentType: TMCPResourceContentType;
begin
  TSynLog.Add.Log(sllInfo, 'MCP resources/read called for: %', [Uri]);

  EnterCriticalSection(fLock);
  try
    Resource := FindResource(Uri);
    if Resource = nil then
    begin
      TSynLog.Add.Log(sllWarning, 'Resource not found: %', [Uri]);
      raise EMCPResourceNotFound.Create(Uri);
    end;

    // Get resource content and type
    RawContent := Resource.GetContent;
    ContentType := Resource.GetContentType;

    // Build content item
    TDocVariantData(ContentItem).InitFast;
    TDocVariantData(ContentItem).U['uri'] := Resource.GetUri;
    if Resource.GetMimeType <> '' then
      TDocVariantData(ContentItem).U['mimeType'] := Resource.GetMimeType;

    // Set text or blob based on content type
    if ContentType = rctText then
      TDocVariantData(ContentItem).U['text'] := RawContent
    else
      TDocVariantData(ContentItem).U['blob'] := BinToBase64(RawContent);
  finally
    LeaveCriticalSection(fLock);
  end;

  // Build result
  TDocVariantData(Result).InitFast;
  TDocVariantData(Contents).InitArray([], JSON_FAST);
  TDocVariantData(Contents).AddItem(ContentItem);
  TDocVariantData(Result).AddValue('contents', Contents);
end;

function TMCPResourcesManager.GetResourceCount: Integer;
begin
  EnterCriticalSection(fLock);
  try
    Result := Length(fResources);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

procedure TMCPResourcesManager.RegisterTemplate(const UriTemplate, Name,
  Description: RawUtf8; const MimeType: RawUtf8);
var
  Template: TMCPResourceTemplate;
begin
  Template.UriTemplate := UriTemplate;
  Template.Name := Name;
  Template.Description := Description;
  Template.MimeType := MimeType;
  RegisterTemplate(Template);
end;

procedure TMCPResourcesManager.RegisterTemplate(const Template: TMCPResourceTemplate);
var
  i: PtrInt;
begin
  if Template.UriTemplate = '' then
    Exit;

  EnterCriticalSection(fLock);
  try
    // Check if already registered
    for i := 0 to High(fTemplates) do
      if fTemplates[i].UriTemplate = Template.UriTemplate then
        Exit;

    // Add to list
    SetLength(fTemplates, Length(fTemplates) + 1);
    fTemplates[High(fTemplates)] := Template;

    TSynLog.Add.Log(sllInfo, 'Registered resource template: %', [Template.UriTemplate]);
  finally
    LeaveCriticalSection(fLock);
  end;

  // Emit resources/list_changed notification (outside lock)
  MCPEventBus.Publish(MCP_EVENT_RESOURCES_LIST_CHANGED, _ObjFast([]));
end;

function TMCPResourcesManager.UnregisterTemplate(const UriTemplate: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  EnterCriticalSection(fLock);
  try
    i := FindTemplateIndex(UriTemplate);
    if i >= 0 then
    begin
      // Remove by shifting remaining elements
      if i < High(fTemplates) then
        Move(fTemplates[i + 1], fTemplates[i],
          (High(fTemplates) - i) * SizeOf(TMCPResourceTemplate));
      SetLength(fTemplates, Length(fTemplates) - 1);

      TSynLog.Add.Log(sllInfo, 'Unregistered resource template: %', [UriTemplate]);
      Result := True;
    end;
  finally
    LeaveCriticalSection(fLock);
  end;

  // Emit resources/list_changed notification if something was removed
  if Result then
    MCPEventBus.Publish(MCP_EVENT_RESOURCES_LIST_CHANGED, _ObjFast([]));
end;

function TMCPResourcesManager.ListTemplates: Variant;
var
  Templates, TemplateInfo: Variant;
  i: PtrInt;
begin
  TSynLog.Add.Log(sllInfo, 'MCP resources/templates/list called');

  TDocVariantData(Result).InitFast;
  TDocVariantData(Templates).InitArray([], JSON_FAST);

  EnterCriticalSection(fLock);
  try
    for i := 0 to High(fTemplates) do
    begin
      TDocVariantData(TemplateInfo).InitFast;
      TDocVariantData(TemplateInfo).U['uriTemplate'] := fTemplates[i].UriTemplate;
      TDocVariantData(TemplateInfo).U['name'] := fTemplates[i].Name;
      if fTemplates[i].Description <> '' then
        TDocVariantData(TemplateInfo).U['description'] := fTemplates[i].Description;
      if fTemplates[i].MimeType <> '' then
        TDocVariantData(TemplateInfo).U['mimeType'] := fTemplates[i].MimeType;
      TDocVariantData(Templates).AddItem(TemplateInfo);
    end;
  finally
    LeaveCriticalSection(fLock);
  end;

  TDocVariantData(Result).AddValue('resourceTemplates', Templates);
end;

function TMCPResourcesManager.GetTemplateCount: Integer;
begin
  EnterCriticalSection(fLock);
  try
    Result := Length(fTemplates);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TMCPResourcesManager.SubscribeResource(const Uri: RawUtf8): Variant;
var
  Resource: IMCPResource;
  i, n: PtrInt;
begin
  TSynLog.Add.Log(sllInfo, 'MCP resources/subscribe called for: %', [Uri]);

  EnterCriticalSection(fLock);
  try
    // Check if resource exists
    Resource := FindResource(Uri);
    if Resource = nil then
    begin
      TSynLog.Add.Log(sllWarning, 'Cannot subscribe - resource not found: %', [Uri]);
      raise EMCPResourceNotFound.Create(Uri);
    end;

    // Find existing subscription or create new one
    i := FindSubscriptionIndex(Uri);
    if i >= 0 then
    begin
      // Increment subscription count
      Inc(fSubscriptions[i].Count);
      TSynLog.Add.Log(sllDebug, 'Incremented subscription count for %: %',
        [Uri, fSubscriptions[i].Count]);
    end
    else
    begin
      // Add new subscription
      n := Length(fSubscriptions);
      SetLength(fSubscriptions, n + 1);
      fSubscriptions[n].Uri := Uri;
      fSubscriptions[n].Count := 1;
      TSynLog.Add.Log(sllDebug, 'Created new subscription for %', [Uri]);
    end;
  finally
    LeaveCriticalSection(fLock);
  end;

  // Return empty object on success (MCP spec)
  Result := _ObjFast([]);
end;

function TMCPResourcesManager.UnsubscribeResource(const Uri: RawUtf8): Variant;
var
  i: PtrInt;
begin
  TSynLog.Add.Log(sllInfo, 'MCP resources/unsubscribe called for: %', [Uri]);

  EnterCriticalSection(fLock);
  try
    i := FindSubscriptionIndex(Uri);
    if i >= 0 then
    begin
      Dec(fSubscriptions[i].Count);
      if fSubscriptions[i].Count <= 0 then
      begin
        // Remove subscription
        if i < High(fSubscriptions) then
          Move(fSubscriptions[i + 1], fSubscriptions[i],
            (High(fSubscriptions) - i) * SizeOf(TMCPResourceSubscription));
        SetLength(fSubscriptions, Length(fSubscriptions) - 1);
        TSynLog.Add.Log(sllDebug, 'Removed subscription for %', [Uri]);
      end
      else
        TSynLog.Add.Log(sllDebug, 'Decremented subscription count for %: %',
          [Uri, fSubscriptions[i].Count]);
    end
    else
      TSynLog.Add.Log(sllDebug, 'No subscription found for %', [Uri]);
  finally
    LeaveCriticalSection(fLock);
  end;

  // Return empty object on success (MCP spec)
  Result := _ObjFast([]);
end;

procedure TMCPResourcesManager.NotifyResourceUpdated(const Uri: RawUtf8);
var
  Resource: IMCPResource;
  Data: Variant;
  IsSubscribed: Boolean;
begin
  EnterCriticalSection(fLock);
  try
    // Check if resource has active subscriptions
    IsSubscribed := FindSubscriptionIndex(Uri) >= 0;

    // Get resource info if subscribed
    if IsSubscribed then
      Resource := FindResource(Uri);
  finally
    LeaveCriticalSection(fLock);
  end;

  // Only emit if there are subscribers
  if IsSubscribed and (Resource <> nil) then
  begin
    TSynLog.Add.Log(sllInfo, 'Emitting resources/updated notification for: %', [Uri]);

    // Build notification data with resource URI
    TDocVariantData(Data).InitFast;
    TDocVariantData(Data).U['uri'] := Uri;

    // Emit notification through event bus
    MCPEventBus.Publish(MCP_EVENT_RESOURCES_UPDATED, Data);
  end;
end;

function TMCPResourcesManager.HasSubscription(const Uri: RawUtf8): Boolean;
begin
  EnterCriticalSection(fLock);
  try
    Result := FindSubscriptionIndex(Uri) >= 0;
  finally
    LeaveCriticalSection(fLock);
  end;
end;

function TMCPResourcesManager.GetSubscriptionCount: Integer;
begin
  EnterCriticalSection(fLock);
  try
    Result := Length(fSubscriptions);
  finally
    LeaveCriticalSection(fLock);
  end;
end;

end.
