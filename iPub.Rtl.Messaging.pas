unit iPub.Rtl.Messaging;

interface

{$SCOPEDENUMS ON}

uses
  { Delphi }
  System.SysUtils,
  System.TypInfo;

type
  EipMessaging = class(Exception);
  TipMessagingThread = (Posting, Main, Async, Background);

  { SubscribeAttribute }

  SubscribeAttribute = class(TCustomAttribute)
  strict private
    FMessageName: string;
    FMessagingThread: TipMessagingThread;
  public
    constructor Create; overload;
    constructor Create(const AMessageName: string); overload;
    constructor Create(const AMessagingThread: TipMessagingThread); overload;
    constructor Create(const AMessageName: string; const AMessagingThread: TipMessagingThread); overload;
    property MessageName: string read FMessageName;
    property MessagingThread: TipMessagingThread read FMessagingThread;
  end;

  { TipMessaging }

  TipMessaging = class
  protected
    type
      TipSubscriberMethod<T> = procedure(const AMessage: T) of object;
  strict protected
    procedure Post(const AMessage: IInterface; const ATypeInfo: PTypeInfo; const AMessageName: string); overload; virtual; abstract;
    procedure SubscribeMethod(const AMessageName: string; const AMethodArgumentTypeInfo: PTypeInfo; const AMethod: TMethod; const AMessagingThread: TipMessagingThread); overload; virtual; abstract;
    function TryUnsubscribeMethod(const AMessageName: string; const AMethodArgumentTypeInfo: PTypeInfo; const AMethod: TMethod): Boolean; overload; virtual; abstract;
  public
    class function NewManager: TipMessaging; static;
    function IsSubscribed(const ASubscriber: TObject): Boolean; virtual; abstract;
    procedure Post(const AMessageName, AMessage: string); overload; virtual; abstract;
    procedure Post<T: IInterface>(AMessage: T); overload;
    procedure Post<T: IInterface>(const AMessageName: string; AMessage: T); overload;
    procedure Subscribe(const ASubscriber: TObject); overload; virtual; abstract;
    procedure SubscribeMethod<T>(const AMessageName: string; const AMethod: TipSubscriberMethod<T>; const AMessagingThread: TipMessagingThread = TipMessagingThread.Posting); overload;
    function TryUnsubscribe(const ASubscriber: TObject): Boolean; virtual; abstract;
    function TryUnsubscribeMethod<T>(const AMessageName: string; const AMethod: TipSubscriberMethod<T>): Boolean; overload;
    procedure Unsubscribe(const ASubscriber: TObject);
    procedure UnsubscribeMethod<T>(const AMessageName: string; const AMethod: TipSubscriberMethod<T>);
  end;

var
  GMessaging: TipMessaging;

implementation

uses
  { Delphi }
  System.Classes,
  System.Threading,
  System.Rtti,
  System.SyncObjs,
  System.Generics.Collections,
  System.Generics.Defaults;

type
  { TRttiUtils }

  TRttiUtils = class sealed
  strict private
    class var FContext: TRttiContext;
    class var FGUIDCacheMap: TDictionary<PTypeInfo, string>;
    {$IF CompilerVersion >= 34.0}
    class var FGUIDCacheSync: TLightweightMREW;
    {$ELSE}
    class var FGUIDCacheSync: TCriticalSection;
    {$ENDIF}
    class constructor Create;
    class destructor Destroy;
    class function GetGUID(const ATypeInfo: PTypeInfo): TGUID; static;
  public
    class function GetGUIDString(const ATypeInfo: PTypeInfo): string; static; inline;
    class function HasAttribute<T: TCustomAttribute>(const ARttiMember: TRttiMember; out AAttribute: T): Boolean; static;
    class property Context: TRttiContext read FContext;
  end;

  { TSubscriberMethod }

  TSubscriberMethod = class
  strict private
    FMessageFullName: string;
    FMessagingThread: TipMessagingThread;
    FMethodCode: Pointer;
    FNameOfMethod: string;
    FTypeKind: TTypeKind;
  public
    constructor Create(const AMessageFullName: string;
      const AMessagingThread: TipMessagingThread;
      const AMethodCode: Pointer; const ANameOfMethod: string;
      const ATypeKind: TTypeKind);
    property MessageFullName: string read FMessageFullName;
    property MessagingThread: TipMessagingThread read FMessagingThread;
    property MethodCode: Pointer read FMethodCode;
    property NameOfMethod: string read FNameOfMethod;
    property TypeKind: TTypeKind read FTypeKind;
  end;

  { ISubscription }

  ISubscription = interface
    procedure Cancel;
    function GetMessagingThread: TipMessagingThread;
    function GetMethodCode: Pointer;
    function GetSubscriber: Pointer;
    procedure Invoke(const AArgAddress: Pointer);
    procedure WaitForInvoke;
    property MessagingThread: TipMessagingThread read GetMessagingThread;
    property Subscriber: Pointer read GetSubscriber;
    property MethodCode: Pointer read GetMethodCode;
  end;

  { TSubscription }

  TSubscription = class(TInterfacedObject, ISubscription)
  strict private
    FCanceled: Boolean;
    FCriticalSection: TCriticalSection;
    FMethod: TMethod;
    FSubscriber: Pointer;
    FSubscriberMethod: TSubscriberMethod;
    FSubscriberMethodOwn: Boolean;
    function GetMessagingThread: TipMessagingThread;
    function GetMethodCode: Pointer;
    function GetSubscriber: Pointer;
  public
    constructor Create(const ASubscriber: Pointer; const ASubscriberMethod: TSubscriberMethod); overload;
    constructor Create(const ASubscriber: Pointer; const AMessageFullName: string;
      const AMessagingThread: TipMessagingThread; const AMethodCode: Pointer;
      const AMethodName: string; const ATypeKind: TTypeKind); overload;
    destructor Destroy; override;
    procedure Cancel;
    procedure Invoke(const AArgAddress: Pointer);
    procedure WaitForInvoke;
  end;

  { TSubscriberMethodsFinder }

  TSubscriberMethodsFinder = class
  strict private
    type
      TSubscriberType = class
      strict private
        FMessageNames: TArray<string>;
        FMethods: TArray<TSubscriberMethod>;
        FOwnMethods: Integer;
      public
        constructor Create(const AParentMethods, AOwnMethods: TArray<TSubscriberMethod>; const AParentMessageNames: TArray<string>);
        destructor Destroy; override;    
        property MessageNames: TArray<string> read FMessageNames;
        property Methods: TArray<TSubscriberMethod> read FMethods;
      end;
  strict private
    FClassCacheMap: TObjectDictionary<TClass, TSubscriberType>;
    FIgnoredUnits: TDictionary<string, Boolean>;
    function GetSubscriberType(const AClass: TClass; ARttiType: TRttiInstanceType): TSubscriberType;
  public
    constructor Create;
    destructor Destroy; override;
    function FindSubscriberMessageNames(const ASubscriberClass: TClass): TArray<string>;
    function FindSubscriberMethods(const ASubscriberClass: TClass): TArray<TSubscriberMethod>;
  end;

  { TipMessageManager }

  TipMessageManager = class(TipMessaging)
  strict private
    FCriticalSection: TCriticalSection;
    FMessageSubscriptions: TObjectDictionary<string, TList<ISubscription>>;
    FSubscriberMethodsFinder: TSubscriberMethodsFinder;
    FSubscribersMap: TDictionary<TObject, string>;
    FSubscriberMethodsMap: TDictionary<string, string>;
    FSubscriptionsComparer: IComparer<ISubscription>;
    procedure DoPost<T>(const AMessageFullName: string; const AArgument: T);
    procedure DoPostWithAnonymousProc<T>(ASubscription: ISubscription; const AArgument: T);
  strict protected
    procedure Post(const AMessage: IInterface; const ATypeInfo: PTypeInfo; const AMessageName: string); overload; override;
    procedure SubscribeMethod(const AMessageName: string; const AMethodArgumentTypeInfo: PTypeInfo; const AMethod: TMethod; const AMessagingThread: TipMessagingThread); overload; override;
    function TryUnsubscribeMethod(const AMessageName: string; const AMethodArgumentTypeInfo: PTypeInfo; const AMethod: TMethod): Boolean; overload; override;
  public
    constructor Create;
    destructor Destroy; override;
    function IsSubscribed(const ASubscriber: TObject): Boolean; override;
    procedure Post(const AMessageName, AMessage: string); overload; override;
    procedure Subscribe(const ASubscriber: TObject); override; 
    function TryUnsubscribe(const ASubscriber: TObject): Boolean; override;
  end;

{ SubscribeAttribute }

constructor SubscribeAttribute.Create;
begin
  inherited Create
end;

constructor SubscribeAttribute.Create(const AMessageName: string);
begin
  inherited Create;
  FMessageName := AMessageName;
end;

constructor SubscribeAttribute.Create(
  const AMessagingThread: TipMessagingThread);
begin
  inherited Create;
  FMessagingThread := AMessagingThread;
end;

constructor SubscribeAttribute.Create(const AMessageName: string;
  const AMessagingThread: TipMessagingThread);
begin
  inherited Create;
  FMessageName := AMessageName;
  FMessagingThread := AMessagingThread;
end;

{ TipMessaging }

class function TipMessaging.NewManager: TipMessaging;
begin
  // This is public because is useful for DUnitX tests
  Result := TipMessageManager.Create;
end;
                  
// The interface parameter cannot have const because sometimes you can create 
// the interface in post call parameter, then we need to increment the reference
procedure TipMessaging.Post<T>(const AMessageName: string; AMessage: T);
var
  LTypeInfo: PTypeInfo;
begin
  LTypeInfo := TypeInfo(T);
  if LTypeInfo.Kind <> TTypeKind.tkInterface then
    raise EipMessaging.Create('Invalid type of message');
  Post(AMessage, LTypeInfo, AMessageName);
end;

// The interface parameter cannot have const because sometimes you can create
// the interface in post call parameter, then we need to increment the reference
procedure TipMessaging.Post<T>(AMessage: T);
var
  LTypeInfo: PTypeInfo;
begin
  LTypeInfo := TypeInfo(T);
  if LTypeInfo.Kind <> TTypeKind.tkInterface then
    raise EipMessaging.Create('Invalid type of message');
  Post(AMessage, LTypeInfo, '');
end;

procedure TipMessaging.SubscribeMethod<T>(const AMessageName: string;
  const AMethod: TipSubscriberMethod<T>; const AMessagingThread: TipMessagingThread);
var
  LTypeInfo: PTypeInfo;
begin
  LTypeInfo := TypeInfo(T);
  if not (LTypeInfo.Kind in [TTypeKind.tkInterface, TTypeKind.tkUString]) then
    raise EipMessaging.Create('Invalid type of message');
  if (LTypeInfo.Kind = TTypeKind.tkUString) and AMessageName.IsEmpty then
    raise EipMessaging.Create('Invalid name');
  SubscribeMethod(AMessageName, LTypeInfo, TMethod(AMethod), AMessagingThread);
end;

function TipMessaging.TryUnsubscribeMethod<T>(const AMessageName: string;
  const AMethod: TipSubscriberMethod<T>): Boolean;
var
  LTypeInfo: PTypeInfo;
begin
  LTypeInfo := TypeInfo(T);
  if not (LTypeInfo.Kind in [TTypeKind.tkInterface, TTypeKind.tkUString]) then
    raise EipMessaging.Create('Invalid type of message');
  if (LTypeInfo.Kind = TTypeKind.tkUString) and AMessageName.IsEmpty then
    raise EipMessaging.Create('Invalid name');
  Result := TryUnsubscribeMethod(AMessageName, LTypeInfo, TMethod(AMethod));
end;

procedure TipMessaging.Unsubscribe(const ASubscriber: TObject);
begin
  if not TryUnsubscribe(ASubscriber) then
    raise EipMessaging.CreateFmt('The object %s is not subscribed', [ASubscriber.QualifiedClassName]);
end;

procedure TipMessaging.UnsubscribeMethod<T>(const AMessageName: string;
  const AMethod: TipSubscriberMethod<T>);
begin
  if not TryUnsubscribeMethod<T>(AMessageName, AMethod) then
    raise EipMessaging.Create('The method is not subscribed');
end;

{ TRttiUtils }

class constructor TRttiUtils.Create;
begin
  FContext := TRttiContext.Create;
  FGUIDCacheMap := TDictionary<PTypeInfo, string>.Create;
  {$IF CompilerVersion < 34.0}
  FGUIDCacheSync := TCriticalSection.Create;
  {$ENDIF}
end;

class destructor TRttiUtils.Destroy;
begin
  {$IF CompilerVersion < 34.0}
  FGUIDCacheSync.Free;
  {$ENDIF}
  FGUIDCacheMap.Free;
  FContext.Free;
end;

class function TRttiUtils.GetGUID(const ATypeInfo: PTypeInfo): TGUID;
var
  LRttiType: TRttiInterfaceType;
begin
  LRttiType := TRttiInterfaceType(FContext.GetType(ATypeInfo));
  if not (TIntfFlag.ifHasGuid in LRttiType.IntfFlags)  then
    raise Exception.CreateFmt('Cannot possible to get the guid of "%s"', [LRttiType.Name, LRttiType.Name]);
  Result := LRttiType.GUID;
end;

class function TRttiUtils.GetGUIDString(const ATypeInfo: PTypeInfo): string;
begin
  {$IF CompilerVersion >= 34.0}
  FGUIDCacheSync.BeginRead;
  {$ELSE}
  FGUIDCacheSync.Enter;
  {$ENDIF}
  try
    if FGUIDCacheMap.TryGetValue(ATypeInfo, Result) then
      Exit;
  finally
    {$IF CompilerVersion >= 34.0}
    FGUIDCacheSync.EndRead;
    {$ELSE}
    FGUIDCacheSync.Leave;
    {$ENDIF}
  end;
  Result := GetGUID(ATypeInfo).ToString.ToLower;
  {$IF CompilerVersion >= 34.0}
  FGUIDCacheSync.BeginWrite;
  {$ELSE}
  FGUIDCacheSync.Enter;
  {$ENDIF}
  try
    FGUIDCacheMap.TryAdd(ATypeInfo, Result);
  finally
    {$IF CompilerVersion >= 34.0}
    FGUIDCacheSync.EndWrite;
    {$ELSE}
    FGUIDCacheSync.Leave;
    {$ENDIF}
  end;
end;

class function TRttiUtils.HasAttribute<T>(const ARttiMember: TRttiMember;
  out AAttribute: T): Boolean;
var
  LAttributes: TArray<TCustomAttribute>;
  I: Integer;
begin
  LAttributes := ARttiMember.GetAttributes;
  for I := 0 to Length(LAttributes)-1 do
    if LAttributes[I] is T then
    begin
      AAttribute := T(LAttributes[I]);
      Exit(True);
    end;
  AAttribute := nil;
  Result := False;
end;

{ TSubscriberMethod }

constructor TSubscriberMethod.Create(const AMessageFullName: string;
  const AMessagingThread: TipMessagingThread; const AMethodCode: Pointer;
  const ANameOfMethod: string; const ATypeKind: TTypeKind);
begin
  inherited Create;
  FMessageFullName := AMessageFullName;
  FMessagingThread := AMessagingThread;
  FMethodCode := AMethodCode;
  FNameOfMethod := ANameOfMethod;
  FTypeKind := ATypeKind;
end;

{ TSubscription }

procedure TSubscription.Cancel;
begin
  FCanceled := True;
end;

constructor TSubscription.Create(const ASubscriber: Pointer;
  const ASubscriberMethod: TSubscriberMethod);
begin
  inherited Create;
  FSubscriber := ASubscriber;
  FSubscriberMethod := ASubscriberMethod;
  if Assigned(FSubscriberMethod) then
  begin
    FCriticalSection := TCriticalSection.Create;
    FMethod.Code := FSubscriberMethod.MethodCode;
    FMethod.Data := ASubscriber;
  end;
end;

constructor TSubscription.Create(const ASubscriber: Pointer;
  const AMessageFullName: string; const AMessagingThread: TipMessagingThread;
  const AMethodCode: Pointer; const AMethodName: string;
  const ATypeKind: TTypeKind);
begin
  Create(ASubscriber, TSubscriberMethod.Create(AMessageFullName,
    AMessagingThread, AMethodCode, AMethodName, ATypeKind));
  FSubscriberMethodOwn := True;
end;

destructor TSubscription.Destroy;
begin
  if Assigned(FCriticalSection) then
    FCriticalSection.Free;
  if FSubscriberMethodOwn then
    FSubscriberMethod.Free;
  inherited;
end;

function TSubscription.GetMessagingThread: TipMessagingThread;
begin
  Result := FSubscriberMethod.MessagingThread;
end;

function TSubscription.GetMethodCode: Pointer;
begin
  if FSubscriberMethodOwn then
    Result := FSubscriberMethod.MethodCode
  else
    Result := nil;
end;

function TSubscription.GetSubscriber: Pointer;
begin
  Result := FSubscriber;
end;

procedure TSubscription.Invoke(const AArgAddress: Pointer);
type
  PInterface = ^IInterface;
begin
  if FCanceled then
    Exit;
  FCriticalSection.Enter;
  try
    if not FCanceled then
    begin
      try
        case FSubscriberMethod.TypeKind of
          TTypeKind.tkUString: TipMessaging.TipSubscriberMethod<string>(FMethod)(PString(AArgAddress)^);
          TTypeKind.tkInterface: TipMessaging.TipSubscriberMethod<IInterface>(FMethod)(PInterface(AArgAddress)^);
        end;
      except
        on E: Exception do
        begin
          if not E.Message.EndsWith('.') then
            E.Message := E.Message + '.';
          E.Message := E.Message + Format(' Error invoking subscribed messaging method %s in class %s with message %s',
            [FSubscriberMethod.NameOfMethod, TObject(FSubscriber).ClassName, FSubscriberMethod.MessageFullName]);
          raise;
        end;
      end;
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TSubscription.WaitForInvoke;
begin
  // We will call this just after call cancel, then enter and leave the critical section will
  // grant that any thread is invoke this subscription method more
  FCriticalSection.Enter;
  FCriticalSection.Leave;
end;

{ TSubscriberMethodsFinder.TSubscriberType }

constructor TSubscriberMethodsFinder.TSubscriberType.Create(
  const AParentMethods, AOwnMethods: TArray<TSubscriberMethod>; 
  const AParentMessageNames: TArray<string>);

  function _GetParentAndOwnMessageNames: TArray<string>;  
  var
    LMessageNameList: TList<string>;
    LIndex: Integer;
    I: Integer;
  begin   
    LMessageNameList := TList<string>.Create;
    try
      LMessageNameList.Capacity := Length(AParentMessageNames) + Length(AOwnMethods);
      if Length(AParentMessageNames) > 0 then
        LMessageNameList.AddRange(AParentMessageNames);          
      // We will insert the message name using binary search to avoid duplications optimally
      for I := 0 to Length(AOwnMethods)-1 do
        if not LMessageNameList.BinarySearch(AOwnMethods[I].MessageFullName, LIndex) then
          LMessageNameList.Insert(LIndex, AOwnMethods[I].MessageFullName);
      Result := LMessageNameList.ToArray;
    finally
      LMessageNameList.Free;
    end;
  end;
  
begin
  inherited Create;
  SetLength(FMethods, Length(AParentMethods) + Length(AOwnMethods));
  if Length(AParentMethods) > 0 then
    Move(AParentMethods[0], FMethods[0], Length(AParentMethods) * SizeOf(TSubscriberMethod));
  if Length(AOwnMethods) > 0 then
    Move(AOwnMethods[0], FMethods[Length(AParentMethods)], Length(AOwnMethods) * SizeOf(TSubscriberMethod));
  FOwnMethods := Length(AOwnMethods);

  if Length(AOwnMethods) = 0 then
    FMessageNames := AParentMessageNames
  else    
    FMessageNames := _GetParentAndOwnMessageNames;
end;

destructor TSubscriberMethodsFinder.TSubscriberType.Destroy;
var
  I: Integer;
begin
  for I := Length(FMethods)-FOwnMethods to Length(FMethods)-1 do
    FMethods[I].Free;
  inherited;
end;

{ TSubscriberMethodsFinder }

constructor TSubscriberMethodsFinder.Create;
begin
  inherited Create;
  FClassCacheMap := TObjectDictionary<TClass, TSubscriberType>.Create([doOwnsValues]);
  // An ugly but efficient way to speed up 10x the TipMessaging.Subscribe()
  FIgnoredUnits := TDictionary<string, Boolean>.Create;
  FIgnoredUnits.Add('System', True);
  FIgnoredUnits.Add('System.Classes', True);
  FIgnoredUnits.Add('FMX.Forms', True);
  FIgnoredUnits.Add('FMX.Controls', True);
  FIgnoredUnits.Add('FMX.Types', True);
  FIgnoredUnits.Add('VCL.Forms', True);
end;

destructor TSubscriberMethodsFinder.Destroy;
begin
  FIgnoredUnits.Free;
  FClassCacheMap.Free;
  inherited;
end;

function TSubscriberMethodsFinder.FindSubscriberMessageNames(
  const ASubscriberClass: TClass): TArray<string>;
var
  LSubscriberType: TSubscriberType;
begin
  LSubscriberType := GetSubscriberType(ASubscriberClass, nil);
  if (LSubscriberType = nil) or (Length(LSubscriberType.MessageNames) = 0) then
    raise EipMessaging.CreateFmt('Class %s and its super classes have no public methods with attribute [Subscribe] defined.',
      [ASubscriberClass.QualifiedClassName]);
  Result := LSubscriberType.MessageNames;
end;

function TSubscriberMethodsFinder.FindSubscriberMethods(
  const ASubscriberClass: TClass): TArray<TSubscriberMethod>;
var
  LClassSubscribersMethod: TSubscriberType;
begin
  LClassSubscribersMethod := GetSubscriberType(ASubscriberClass, nil);
  if (LClassSubscribersMethod = nil) or (Length(LClassSubscribersMethod.Methods) = 0) then
    raise EipMessaging.CreateFmt('Class %s and its super classes have no public methods with attribute [Subscribe] defined.',
      [ASubscriberClass.QualifiedClassName]);
  Result := LClassSubscribersMethod.Methods;
end; 

function TSubscriberMethodsFinder.GetSubscriberType(const AClass: TClass;
  ARttiType: TRttiInstanceType): TSubscriberType;  
var
  LOwnMethods: TArray<TSubscriberMethod>;
  LAttribute: SubscribeAttribute;
  LRttiMethods: TArray<TRttiMethod>;
  LRttiMethod: TRttiMethod;
  LRttiParamType: TRttiType;
  LParamsLength: Integer;
  LMessageFullName: string;
  LTypeKind: TTypeKind;
  I: Integer;
begin
  if AClass = nil then
    Exit(nil);
  if FClassCacheMap.TryGetValue(AClass, Result) then
    Exit;
  if FIgnoredUnits.ContainsKey(AClass.UnitName) then
    Exit(nil);
  if not Assigned(ARttiType) then
  begin
    ARttiType := TRttiInstanceType(TRttiUtils.Context.GetType(AClass));
    if ARttiType = nil then
      Exit(nil);
  end;

  Result := GetSubscriberType(AClass.ClassParent, ARttiType.BaseType);

  LOwnMethods := nil;
  LRttiMethods := ARttiType.GetDeclaredMethods;
  for I := 0 to Length(LRttiMethods)-1 do
  begin
    LRttiMethod := LRttiMethods[I];
    if TRttiUtils.HasAttribute<SubscribeAttribute>(LRttiMethod, LAttribute) then
    begin
      LParamsLength := Length(LRttiMethod.GetParameters);

      if LParamsLength <> 1 then
        raise EipMessaging.CreateFmt('Method %s.%s have invalid arguments. ', [AClass.QualifiedClassName, LRttiMethod.Name]);
      LRttiParamType := LRttiMethod.GetParameters[0].ParamType;
      if LRttiParamType = nil then
        raise EipMessaging.CreateFmt('Method %s.%s have invalid arguments. ', [AClass.QualifiedClassName, LRttiMethod.Name]);
      LTypeKind := LRttiParamType.TypeKind;
      if not (LTypeKind in [TTypeKind.tkUString, TTypeKind.tkInterface]) then
        raise EipMessaging.CreateFmt('Method %s.%s has attribute %s, but the method have invalid arguments. ' +
          'You need to have 1 argument of string or interface.', [AClass.QualifiedClassName, LRttiMethod.Name, LAttribute.ClassName]);

      LMessageFullName := LAttribute.MessageName;
      case LTypeKind of
        TTypeKind.tkUString:
          begin
            if LMessageFullName.IsEmpty then
              raise EipMessaging.CreateFmt('Method %s.%s has invalid subscribe attribute. All string messages should ' +
                'have a name in attribute like [Subscribe(''Hello'')]', [AClass.QualifiedClassName, LRttiMethod.Name]);
            LMessageFullName := '{str}' + LMessageFullName.ToLower;
          end;
        TTypeKind.tkInterface:
          begin
            LMessageFullName := TRttiInterfaceType(LRttiParamType).GUID.ToString + LMessageFullName;
            LMessageFullName := LMessageFullName.ToLower;
          end;
      end;
      SetLength(LOwnMethods, Length(LOwnMethods) + 1);
      LOwnMethods[High(LOwnMethods)] := TSubscriberMethod.Create(LMessageFullName, LAttribute.MessagingThread, LRttiMethods[I].CodeAddress, LRttiMethod.Name, LTypeKind);
    end;
  end;

  if Assigned(Result) then
    Result := TSubscriberType.Create(Result.Methods, LOwnMethods, Result.MessageNames)
  else                                                                                  
    Result := TSubscriberType.Create(nil, LOwnMethods, nil);
  FClassCacheMap.Add(AClass, Result);
end;

{ TipMessageManager }

constructor TipMessageManager.Create;
begin
  inherited Create;
  FCriticalSection := TCriticalSection.Create;
  FMessageSubscriptions := TObjectDictionary<string, TList<ISubscription>>.Create([doOwnsValues]);
  FSubscriberMethodsFinder := TSubscriberMethodsFinder.Create;
  FSubscribersMap := TDictionary<TObject, string>.Create;
  FSubscriberMethodsMap := TDictionary<string, string>.Create;
  FSubscriptionsComparer := TComparer<ISubscription>.Construct(
    function(const ALeft, ARight: ISubscription): Integer
    var
      LLeft, LRight: UInt64;
    begin
      LLeft := NativeUInt(ALeft.Subscriber);
      LRight := NativeUInt(ARight.Subscriber);
      if LLeft = LRight then
      begin
        LLeft := NativeUInt(ALeft.MethodCode);
        LRight := NativeUInt(ARight.MethodCode);
        if LLeft = LRight then
          Result := 0
        else if LLeft < LRight then
          Result := -1
        else
          Result := 1;
      end
      else if LLeft < LRight then
        Result := -1
      else
        Result := 1;
    end);
end;

destructor TipMessageManager.Destroy;

  function _GetSubscribersClassName(const ASubscribers: TArray<string>): string;
  var
    LAmountMap: TDictionary<string, Integer>;
    LClassesAmount: TArray<TPair<string, Integer>>;
    LCount: Integer;
    I: Integer;
  begin
    LAmountMap := TDictionary<string, Integer>.Create;
    try
      for I := 0 to Length(ASubscribers)-1 do
      begin
        if not LAmountMap.TryGetValue(ASubscribers[I], LCount) then
          LCount := 0;
        Inc(LCount);
        LAmountMap.AddOrSetValue(ASubscribers[I], LCount);
      end;
      LClassesAmount := LAmountMap.ToArray;
    finally
      LAmountMap.Free;
    end;
    TArray.Sort<TPair<string, Integer>>(LClassesAmount, TComparer<TPair<string, Integer>>.Construct(
      function (const ALeft, ARight: TPair<string, Integer>): Integer
      begin
        Result := ARight.Value - ALeft.Value;
      end));

    Result := '';
    for I := 0 to Length(LClassesAmount)-1 do
    begin
      if I = 10 then
        Exit(Result + ', ...');
      if I > 0 then
        Result := Result + ', ';
      Result := Result + LClassesAmount[I].Value.ToString + 'x ' + LClassesAmount[I].Key;
    end;
  end;

begin
  try
    try
      // It is more than a good practice to unsubscribe, we will force it to avoid problems
      if (FSubscribersMap.Count > 0) or (FSubscriberMethodsMap.Count > 0) then
      begin
        FCriticalSection.Enter;
        try
          raise EipMessaging.CreateFmt('Found %d object(s)/method(s) that haven''t unsubscribed: %s', [FSubscribersMap.Count + FSubscriberMethodsMap.Count,
            _GetSubscribersClassName(FSubscribersMap.Values.ToArray + FSubscriberMethodsMap.Values.ToArray)]);
        finally
          FCriticalSection.Leave;
        end;
      end;
    finally
      FMessageSubscriptions.Free;
      FSubscriberMethodsFinder.Free;
      FSubscriberMethodsMap.Free;
      FSubscribersMap.Free;
      FCriticalSection.Free;
      inherited;
    end;
  except
    // This is just to raise the exception avoiding showing this class in memory leak report
    on E: EipMessaging do
    begin
      FreeInstance;
      raise;
    end;
  end;
end;

procedure TipMessageManager.DoPost<T>(const AMessageFullName: string;
  const AArgument: T);
var
  LSubscriptionsList: TList<ISubscription>;
  LSubscriptions: TArray<ISubscription>;
  I: Integer;
begin
  if AMessageFullName.IsEmpty then
    raise EipMessaging.Create('Invalid message name');

  FCriticalSection.Enter;
  try
    if not FMessageSubscriptions.TryGetValue(AMessageFullName, LSubscriptionsList) then
      Exit;
    LSubscriptions := LSubscriptionsList.ToArray;
  finally
    FCriticalSection.Leave;
  end;

  for I := 0 to Length(LSubscriptions)-1 do
  begin
    // The subscriber method will be invoked in the same posting thread where Post was called
    if LSubscriptions[I].MessagingThread = TipMessagingThread.Posting then
      LSubscriptions[I].Invoke(@AArgument)
    else
      DoPostWithAnonymousProc<T>(LSubscriptions[I], AArgument);
  end;
end;

// Don't remove this method. This is to force the refcount +1 before call annonymous proc.
procedure TipMessageManager.DoPostWithAnonymousProc<T>(
  ASubscription: ISubscription; const AArgument: T);
begin
  case ASubscription.MessagingThread of
    // The subscriber method will be invoked in the main thread
    TipMessagingThread.Main:
      begin
        if MainThreadID = TThread.CurrentThread.ThreadID then
          ASubscription.Invoke(@AArgument)
        else
          TThread.Queue(nil, procedure()
            begin
              ASubscription.Invoke(@AArgument);
            end);
      end;
    // The subscriber method will be invoked asynchronously in a new anonnymous thread other than the posting thread
    TipMessagingThread.Async:
      TTask.Run(procedure()
        begin
          ASubscription.Invoke(@AArgument);
        end);
    // If the posting thread is the main thread, the subscriber method will be invoked asynchronously in a new
    // anonnymous thread, other than the posting thread. If the posting thread is not the main thread, the subscriber
    // method will be invoked synchronously in the same posting thread
    TipMessagingThread.Background:
      begin
        if MainThreadID = TThread.CurrentThread.ThreadID then
          TTask.Run(procedure()
            begin
              ASubscription.Invoke(@AArgument);
            end)
        else
          ASubscription.Invoke(@AArgument);
      end;
  else
    Assert(False);
  end;
end;

function TipMessageManager.IsSubscribed(
  const ASubscriber: TObject): Boolean;
begin
  FCriticalSection.Enter;
  try
    Result := FSubscribersMap.ContainsKey(ASubscriber);
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TipMessageManager.Post(const AMessage: IInterface;
  const ATypeInfo: PTypeInfo; const AMessageName: string);
begin
  DoPost<IInterface>(TRttiUtils.GetGUIDString(ATypeInfo) + AMessageName.ToLower, AMessage);
end;

procedure TipMessageManager.Post(const AMessageName, AMessage: string);
begin
  DoPost<string>('{str}' + AMessageName.ToLower, AMessage);
end;

procedure TipMessageManager.Subscribe(const ASubscriber: TObject);
var
  LSubscriberMethods: TArray<TSubscriberMethod>;
  LSubscriberMethod: TSubscriberMethod;
  LSubscription: ISubscription;
  LSubscriptions: TList<ISubscription>;
  LIndex: Integer;
  I: Integer;
begin
  if not Assigned(ASubscriber) then
    raise EipMessaging.Create('Invalid subscriber');
  FCriticalSection.Enter;
  try
    if FSubscribersMap.ContainsKey(ASubscriber) then
      raise EipMessaging.CreateFmt('The object %s is already subscribed', [ASubscriber.QualifiedClassName]);
    LSubscriberMethods := FSubscriberMethodsFinder.FindSubscriberMethods(ASubscriber.ClassType); 
    Assert(Length(LSubscriberMethods) > 0);
    FSubscribersMap.Add(ASubscriber, ASubscriber.ClassName);
    
    for I := 0 to Length(LSubscriberMethods)-1 do 
    begin
      LSubscriberMethod := LSubscriberMethods[I];
      LSubscription := TSubscription.Create(ASubscriber, LSubscriberMethod);

      if not FMessageSubscriptions.TryGetValue(LSubscriberMethod.MessageFullName, LSubscriptions) then
      begin
        LSubscriptions := TList<ISubscription>.Create(FSubscriptionsComparer);
        FMessageSubscriptions.Add(LSubscriberMethod.MessageFullName, LSubscriptions);
      end;   
      // We don't need the result of binary search, just the index, because although it is uncommon,
      // there may be a class that has the same message name in several methods including super classes
      LSubscriptions.BinarySearch(LSubscription, LIndex);
      LSubscriptions.Insert(LIndex, LSubscription);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TipMessageManager.SubscribeMethod(const AMessageName: string;
  const AMethodArgumentTypeInfo: PTypeInfo; const AMethod: TMethod;
  const AMessagingThread: TipMessagingThread);
var
  LSubscription: ISubscription;
  LSubscriptions: TList<ISubscription>;
  LMessageFullName: string;
  LMethodId: string;
  LMethodName: string;
  LIndex: Integer;
begin
  if (AMethod.Code = nil) or (AMethod.Data = nil) then
    raise EipMessaging.Create('Invalid method');
  if AMethodArgumentTypeInfo.Kind = TTypeKind.tkInterface then
    LMessageFullName := TRttiUtils.GetGUIDString(AMethodArgumentTypeInfo) + AMessageName.ToLower
  else
    LMessageFullName := '{str}' + AMessageName.ToLower;
  LMethodId := NativeUInt(AMethod.Code).ToString + '.' +
    NativeUInt(AMethod.Data).ToString + '.' + LMessageFullName;
  {$IFDEF DEBUG}
  LMethodName := TObject(AMethod.Data).MethodName(AMethod.Code);
  if LMethodName.IsEmpty then
  {$ENDIF}
    LMethodName := '<?>';
  FCriticalSection.Enter;
  try
    if FSubscriberMethodsMap.ContainsKey(LMethodId) then
      raise EipMessaging.CreateFmt('The method %s is already subscribed', [LMethodName]);
    FSubscriberMethodsMap.Add(LMethodId, TObject(AMethod.Data).ClassName + '.' + LMethodName + '.' + LMessageFullName);

    LSubscription := TSubscription.Create(AMethod.Data, LMessageFullName,
      AMessagingThread, AMethod.Code, LMethodName, AMethodArgumentTypeInfo.Kind);

    if not FMessageSubscriptions.TryGetValue(LMessageFullName, LSubscriptions) then
    begin
      LSubscriptions := TList<ISubscription>.Create(FSubscriptionsComparer);
      FMessageSubscriptions.Add(LMessageFullName, LSubscriptions);
    end;
    if LSubscriptions.BinarySearch(LSubscription, LIndex) then
      raise EipMessaging.CreateFmt('Unexpected error subscribing %s', [LMethodName]);
    LSubscriptions.Insert(LIndex, LSubscription);
  finally
    FCriticalSection.Leave;
  end;
end;

function TipMessageManager.TryUnsubscribe(
  const ASubscriber: TObject): Boolean;
var
  LMessageNames: TArray<string>;
  LSubscriptions: TList<ISubscription>;   
  LCancelSubscriptions: TList<ISubscription>;
  LSubscriptionToFind: ISubscription;
  LIndex: Integer;  
  LStartIndex: Integer;     
  LCount: Integer;
  I: Integer;
begin
  if not Assigned(ASubscriber) then
    raise EipMessaging.Create('Invalid subscriber');
  LCancelSubscriptions := nil;
  try
    LSubscriptionToFind := TSubscription.Create(ASubscriber, nil);
    FCriticalSection.Enter;
    try
      if not FSubscribersMap.ContainsKey(ASubscriber) then
        Exit(False);
      LMessageNames := FSubscriberMethodsFinder.FindSubscriberMessageNames(ASubscriber.ClassType); 
      Assert(Length(LMessageNames) > 0); 
      FSubscribersMap.Remove(ASubscriber);
    
      for I := 0 to Length(LMessageNames)-1 do 
      begin
        if not FMessageSubscriptions.TryGetValue(LMessageNames[I], LSubscriptions) then
          Continue;
        if LSubscriptions.BinarySearch(LSubscriptionToFind, LIndex) then
        begin
          // Although it is uncommon, there may be a class that has the same message name in several methods including super classes
          LStartIndex := LIndex;
          while (LStartIndex > 0) and (FSubscriptionsComparer.Compare(LSubscriptions.List[LStartIndex - 1], LSubscriptionToFind) = 0) do
            Dec(LStartIndex);
          LCount := (LIndex - LStartIndex) + 1;
          while (LStartIndex + LCount < LSubscriptions.Count) and
            (FSubscriptionsComparer.Compare(LSubscriptions.List[LStartIndex + LCount], LSubscriptionToFind) = 0) do
          begin
            Inc(LCount);
          end;
          LIndex := LStartIndex;
          while LIndex < LStartIndex + LCount do
          begin
            // Check cancel need, just when subscription is executing
            if TSubscription(LSubscriptions.List[LIndex]).FRefCount <> 1 then
            begin
              if not Assigned(LCancelSubscriptions) then
                LCancelSubscriptions := TList<ISubscription>.Create;
              LCancelSubscriptions.Add(LSubscriptions[LIndex]);
            end;
            Inc(LIndex);
          end;
          LSubscriptions.DeleteRange(LStartIndex, LCount);
          if LSubscriptions.Count = 0 then
            FMessageSubscriptions.Remove(LMessageNames[I]);
        end;
      end;
    finally
      FCriticalSection.Leave;
    end;
    // Cancel subscriptions that is executing
    if Assigned(LCancelSubscriptions) then
    begin
      for I := 0 to LCancelSubscriptions.Count-1 do
        LCancelSubscriptions.List[I].Cancel;
      for I := 0 to LCancelSubscriptions.Count-1 do
        LCancelSubscriptions.List[I].WaitForInvoke;
    end;
  finally
    if Assigned(LCancelSubscriptions) then
      LCancelSubscriptions.Free;
  end;
  Result := True;
end;

function TipMessageManager.TryUnsubscribeMethod(const AMessageName: string;
  const AMethodArgumentTypeInfo: PTypeInfo; const AMethod: TMethod): Boolean;
var
  LSubscriptions: TList<ISubscription>;
  LCancelSubscription: ISubscription;
  LSubscriptionToFind: ISubscription;
  LMessageFullName: string;
  LMethodId: string;
  LIndex: Integer;
begin
  if AMethod.Code = nil then
    raise EipMessaging.Create('Invalid method');
  if AMethodArgumentTypeInfo.Kind = TTypeKind.tkInterface then
    LMessageFullName := TRttiUtils.GetGUIDString(AMethodArgumentTypeInfo) + AMessageName.ToLower
  else
    LMessageFullName := '{str}' + AMessageName.ToLower;
  LMethodId := NativeUInt(AMethod.Code).ToString + '.' +
    NativeUInt(AMethod.Data).ToString + '.' + LMessageFullName;
  LCancelSubscription := nil;
  LSubscriptionToFind := TSubscription.Create(AMethod.Data, '',
      TipMessagingThread.Posting, AMethod.Code, '', AMethodArgumentTypeInfo.Kind);
  FCriticalSection.Enter;
  try
    if not FSubscriberMethodsMap.ContainsKey(LMethodId) then
      Exit(False);
    FSubscriberMethodsMap.Remove(LMethodId);

    if not FMessageSubscriptions.TryGetValue(LMessageFullName, LSubscriptions) then
      Exit(False);
    if not LSubscriptions.BinarySearch(LSubscriptionToFind, LIndex) then
      Exit(False);

    // Check cancel need, just when subscription is executing
    if TSubscription(LSubscriptions.List[LIndex]).FRefCount <> 1 then
      LCancelSubscription := LSubscriptions[LIndex];
    LSubscriptions.Delete(LIndex);
    if LSubscriptions.Count = 0 then
      FMessageSubscriptions.Remove(LMessageFullName);
  finally
    FCriticalSection.Leave;
  end;
  // Cancel subscriptions that is executing
  if Assigned(LCancelSubscription) then
  begin
    LCancelSubscription.Cancel;
    LCancelSubscription.WaitForInvoke;
  end;
  Result := True;
end;

initialization
  GMessaging := TipMessaging.NewManager;
finalization
  FreeAndNil(GMessaging);
end.
