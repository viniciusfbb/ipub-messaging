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
  public
    constructor Create(const AMessagingThread: TipMessagingThread;
      const AMessageFullName: string);
    property MessageFullName: string read FMessageFullName;
    property MessagingThread: TipMessagingThread read FMessagingThread;
  end;

  { TSubscriberRttiMethod }

  TSubscriberRttiMethod = class(TSubscriberMethod)
  strict private
    FRttiMethod: TRttiMethod;
  public
    constructor Create(const AMessagingThread: TipMessagingThread;
      const AMessageFullName: string; const ARttiMethod: TRttiMethod);
    property RttiMethod: TRttiMethod read FRttiMethod;
  end;

  { TSubscriberObjectMethod }

  TSubscriberObjectMethod = class(TSubscriberMethod)
  strict private
    FMethod: TMethod;
    FTypeKind: TTypeKind;
  public
    constructor Create(const AMessagingThread: TipMessagingThread;
      const AMessageFullName: string; const AMethod: TMethod; const ATypeKind: TTypeKind);
    property Method: TMethod read FMethod;
    property TypeKind: TTypeKind read FTypeKind;
  end;

  { ISubscription }

  ISubscription = interface
    procedure Cancel;
    function GetMessagingThread: TipMessagingThread;
    function GetMethodCode: Pointer;
    function GetSubscriber: Pointer;
    procedure Invoke(const AArgument: TValue);
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
    FMethodCode: Pointer;
    FMessagingThread: TipMessagingThread;
    FSubscriber: Pointer;
    FSubscriberMethod: TSubscriberMethod;
    function GetMessagingThread: TipMessagingThread;
    function GetMethodCode: Pointer;
    function GetSubscriber: Pointer;
  public
    constructor Create(const ASubscriber: Pointer; const ASubscriberMethod: TSubscriberMethod);
    destructor Destroy; override;
    procedure Cancel;
    procedure Invoke(const AArgument: TValue);
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
    procedure DoPost(const AMessageFullName: string; const AArgument: TValue);
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

constructor TSubscriberMethod.Create(const AMessagingThread: TipMessagingThread;
  const AMessageFullName: string);
begin
  inherited Create;
  FMessagingThread := AMessagingThread;
  FMessageFullName := AMessageFullName.ToLower;
end;

{ TSubscriberRttiMethod }

constructor TSubscriberRttiMethod.Create(
  const AMessagingThread: TipMessagingThread; const AMessageFullName: string;
  const ARttiMethod: TRttiMethod);
begin
  inherited Create(AMessagingThread, AMessageFullName);
  FRttiMethod := ARttiMethod;
end;

{ TSubscriberObjectMethod }

constructor TSubscriberObjectMethod.Create(
  const AMessagingThread: TipMessagingThread; const AMessageFullName: string;
  const AMethod: TMethod; const ATypeKind: TTypeKind);
begin
  inherited Create(AMessagingThread, AMessageFullName);
  FMethod := AMethod;
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
    FMessagingThread := FSubscriberMethod.MessagingThread;
    FCriticalSection := TCriticalSection.Create;
    if ASubscriberMethod is TSubscriberObjectMethod then
      FMethodCode := TSubscriberObjectMethod(ASubscriberMethod).Method.Code;
  end;
end;

destructor TSubscription.Destroy;
begin
  if Assigned(FCriticalSection) then
    FCriticalSection.Free;
  // If the FSubscriberMethod is not a rtti method the subscription will be responsible to release it
  if Assigned(FMethodCode) then
    FSubscriberMethod.Free;
  inherited;
end;

function TSubscription.GetMessagingThread: TipMessagingThread;
begin
  Result := FMessagingThread;
end;

function TSubscription.GetMethodCode: Pointer;
begin
  Result := FMethodCode;
end;

function TSubscription.GetSubscriber: Pointer;
begin
  Result := FSubscriber;
end;

procedure TSubscription.Invoke(const AArgument: TValue);
begin
  if FCanceled then
    Exit;
  FCriticalSection.Enter;
  try
    if not FCanceled then
    begin
      try
        if FSubscriberMethod is TSubscriberRttiMethod then
          TSubscriberRttiMethod(FSubscriberMethod).RttiMethod.Invoke(TObject(FSubscriber), [AArgument])
        else
        begin
          case TSubscriberObjectMethod(FSubscriberMethod).TypeKind of
            TTypeKind.tkUString:
              TipMessaging.TipSubscriberMethod<string>(TSubscriberObjectMethod(FSubscriberMethod).Method)(AArgument.AsString);
            TTypeKind.tkInterface:
              TipMessaging.TipSubscriberMethod<IInterface>(TSubscriberObjectMethod(FSubscriberMethod).Method)(AArgument.AsInterface);
          end;
        end;
      except
        on E: Exception do
        begin
          E.Message := E.Message + ' Error invoking subscribed messaging method';
          if FSubscriberMethod is TSubscriberRttiMethod then
            E.Message := E.Message + Format(' %s in class %s', [TSubscriberRttiMethod(FSubscriberMethod).RttiMethod.Name, TObject(FSubscriber).QualifiedClassName])
          else
            E.Message := E.Message + Format(' %s', [TSubscriberObjectMethod(FSubscriberMethod).MessageFullName]);
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
  LParamsLength: Integer;
  LMessageFullName: string;
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

      if (LParamsLength <> 1) or
        not (LRttiMethod.GetParameters[0].ParamType.TypeKind in [TTypeKind.tkUString, TTypeKind.tkInterface]) then
      begin
        raise EipMessaging.CreateFmt('Method %s.%s has attribute %s, but the method have invalid arguments. ' +
          'You need to have 1 argument of string or interface.', [AClass.QualifiedClassName, LRttiMethod.Name, LAttribute.ClassName]);
      end;

      LMessageFullName := LAttribute.MessageName;
      case LRttiMethod.GetParameters[0].ParamType.TypeKind of
        TTypeKind.tkUString:
          begin
            if LMessageFullName.IsEmpty then
              raise EipMessaging.CreateFmt('Method %s.%s has invalid subscribe attribute. All string messages should ' +
                'have a name in attribute like [Subscribe(''Hello'')]', [AClass.QualifiedClassName, LRttiMethod.Name]);
            LMessageFullName := '{string}' + LMessageFullName;
          end;
        TTypeKind.tkInterface: LMessageFullName := TRttiInterfaceType(LRttiMethods[I].GetParameters[0].ParamType).GUID.ToString + LMessageFullName;
      end;
      SetLength(LOwnMethods, Length(LOwnMethods) + 1);
      LOwnMethods[High(LOwnMethods)] := TSubscriberRttiMethod.Create(LAttribute.MessagingThread, LMessageFullName, LRttiMethods[I]);
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
  FMessageSubscriptions.Free;
  FSubscriberMethodsFinder.Free;
  FSubscriberMethodsMap.Free;
  FSubscribersMap.Free;
  FCriticalSection.Free;
  inherited;
end;

procedure TipMessageManager.DoPost(const AMessageFullName: string;
  const AArgument: TValue);

  // Don't remove this method. This is to force the refcount +1 before call annonymous proc.
  procedure _Post(ASubscription: ISubscription);
  begin
    case ASubscription.MessagingThread of
      // The subscriber method will be invoked in the main thread
      TipMessagingThread.Main:
        begin
          if MainThreadID = TThread.CurrentThread.ThreadID then
            ASubscription.Invoke(AArgument)
          else
            TThread.Queue(nil, procedure()
              begin
                ASubscription.Invoke(AArgument);
              end);
        end;
      // The subscriber method will be invoked asynchronously in a new anonnymous thread other than the posting thread
      TipMessagingThread.Async:
        TTask.Run(procedure()
          begin
            ASubscription.Invoke(AArgument);
          end);
      // If the posting thread is the main thread, the subscriber method will be invoked asynchronously in a new
      // anonnymous thread, other than the posting thread. If the posting thread is not the main thread, the subscriber
      // method will be invoked synchronously in the same posting thread
      TipMessagingThread.Background:
        begin
          if MainThreadID = TThread.CurrentThread.ThreadID then
            TTask.Run(procedure()
              begin
                ASubscription.Invoke(AArgument);
              end)
          else
            ASubscription.Invoke(AArgument);
        end;
    else
      Assert(False);
    end;
  end;

var
  LMessageFullName: string;
  LSubscriptionsList: TList<ISubscription>;
  LSubscriptions: TArray<ISubscription>;
  I: Integer;
begin
  if AMessageFullName.IsEmpty then
    raise EipMessaging.Create('Invalid message name');

  LMessageFullName := AMessageFullName.ToLower;
  FCriticalSection.Enter;
  try
    if not FMessageSubscriptions.TryGetValue(LMessageFullName, LSubscriptionsList) then
      Exit;
    LSubscriptions := LSubscriptionsList.ToArray;
  finally
    FCriticalSection.Leave;
  end;

  for I := 0 to Length(LSubscriptions)-1 do
  begin
    // The subscriber method will be invoked in the same posting thread where Post was called
    if LSubscriptions[I].MessagingThread = TipMessagingThread.Posting then
      LSubscriptions[I].Invoke(AArgument)
    else
      _Post(LSubscriptions[I]);
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
  DoPost(TRttiUtils.GetGUIDString(ATypeInfo) + AMessageName, AMessage as TObject);
end;

procedure TipMessageManager.Post(const AMessageName, AMessage: string);
begin
  DoPost('{string}' + AMessageName, AMessage);
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
  LSubscriberMethod: TSubscriberMethod;
  LSubscription: ISubscription;
  LSubscriptions: TList<ISubscription>;
  LMessageFullName: string;
  LMethodId: string;
  LMethodName: string;
  LIndex: Integer;
begin
  if AMethod.Code = nil then
    raise EipMessaging.Create('Invalid method');
  if AMethodArgumentTypeInfo.Kind = TTypeKind.tkInterface then
    LMessageFullName := TRttiUtils.GetGUIDString(AMethodArgumentTypeInfo) + AMessageName
  else
    LMessageFullName := '{string}' + AMessageName;
  LMessageFullName := LMessageFullName.ToLower;
  LMethodId := Format('%s.%s.%s', [NativeUInt(AMethod.Code).ToHexString(SizeOf(Pointer) * 2),
    NativeUInt(AMethod.Data).ToHexString(SizeOf(Pointer) * 2), LMessageFullName]);
  LMethodName := TObject(AMethod.Data).MethodName(AMethod.Code);
  if LMethodName.IsEmpty then
    LMethodName := '<unknown>';
  LMethodName := TObject(AMethod.Data).ClassName + '.' + LMethodName + '.' + LMessageFullName;
  FCriticalSection.Enter;
  try
    if FSubscriberMethodsMap.ContainsKey(LMethodId) then
      raise EipMessaging.CreateFmt('The method %s is already subscribed', [LMethodName]);
    FSubscriberMethodsMap.Add(LMethodId, LMethodName);

    LSubscriberMethod := TSubscriberObjectMethod.Create(AMessagingThread, LMethodName, AMethod, AMethodArgumentTypeInfo.Kind);
    LSubscription := TSubscription.Create(AMethod.Data, LSubscriberMethod);

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
  LSubscriberMethod: TSubscriberMethod;
  LMessageFullName: string;
  LMethodId: string;
  LIndex: Integer;
begin
  if AMethod.Code = nil then
    raise EipMessaging.Create('Invalid method');
  if AMethodArgumentTypeInfo.Kind = TTypeKind.tkInterface then
    LMessageFullName := TRttiUtils.GetGUIDString(AMethodArgumentTypeInfo) + AMessageName
  else
    LMessageFullName := '{string}' + AMessageName;
  LMessageFullName := LMessageFullName.ToLower;
  LMethodId := NativeUInt(AMethod.Code).ToHexString(SizeOf(Pointer) * 2) + '.' +
    NativeUInt(AMethod.Data).ToHexString(SizeOf(Pointer) * 2) + '.' + LMessageFullName;
  LCancelSubscription := nil;
  LSubscriberMethod := TSubscriberObjectMethod.Create(TipMessagingThread.Posting, '', AMethod, AMethodArgumentTypeInfo.Kind);
  LSubscriptionToFind := TSubscription.Create(AMethod.Data, LSubscriberMethod);
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
  GMessaging := TipMessageManager.Create;
finalization
  FreeAndNil(GMessaging);
end.
