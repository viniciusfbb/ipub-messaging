# iPub Messaging
<a href="https://www.embarcadero.com/products/delphi" title=""><img src="https://img.shields.io/static/v1?label=Delphi%20Supported%20Versions&message=XE7%2B&color=blueviolet&style=for-the-badge"></a> <a href="http://docwiki.embarcadero.com/PlatformStatus/en/Main_Page" title=""><img src="https://img.shields.io/static/v1?label=Supported%20platforms&message=Full%20Cross-Platform&color=blue&style=for-the-badge"></a>

Thread safe, asynchronous and simplistic messaging system for communication between classes / layers in delphi created by the iPub team.

## The problem
  Delphi has its own messaging system (System.Messaging.pas) that works well but is totally synchronous and thread unsafe. In multithreaded systems we always need to communicate with other classes, sometimes synchronously, sometimes asynchronously, sometimes synchronizing with the mainthread (in the case of the UI), and doing this without a message system (communicating directly) makes the code large and complex, prone to many bugs.

## The solution
  An ideal messaging system would be a thread safe system that would allow a class to subscribe and then unsubscribe to listen to a particular message over this time, and this listener class that will receiving the message is who will inform how the sender will invoke it's method: on the same thread (**posting**), on the main thread (**main**), on another thread (**async**) and on a thread other than main (**background**). This is the basis of our messaging system, the usage is similar to another existing system, the [Delphi Event Bus (DEB)](https://github.com/spinettaro/delphi-event-bus).

## Advantages over similar (DEB)
 - **Performance**: faster in all operations (subscribe, unsubscribe, post), in addition to 10x faster initialization
 - **Efficiency**: consumes half the memory
 - **Minor code**: lower generated binary and faster compilation
 
 See the comparison in an environment with 1000 objects:
|  | Subscribe | Post | Unsubscribe |
| --- | --- | --- | --- |
| iPub | 1.6368 ms | 0.1215 ms | 1.7666 ms |
| DEB | 9.8832 ms | 2.0293 ms | 4.0022 ms |

## Using
  #### Interface message
  
  ```delphi
  ILogOutMessage = interface
    ['{CA101646-B801-433D-B31A-ADF7F31AC59E}']
    // here you can put any data
  end;
  ```
    
  #### Listening to a message
  First, you must subscribe your class to listen to messages, then all public methods that have the [Subscribe] attribute will be subscribed.
  ```delphi
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    { Private declarations }
  public
    { Public declarations }
    [Subscribe(TipMessagingThread.Main)]
    procedure OnLogout(const AMessage: ILogOutMessage);
  end;
  
  ...
  
  procedure TForm1.FormCreate(Sender: TObject);
  begin
    GMessaging.Subscribe(Self);
  end;

  procedure TForm1.FormDestroy(Sender: TObject);
  begin
    GMessaging.Unsubscribe(Self);
  end;

  procedure TForm1.OnLogout(const AMessage: ILogOutMessage);
  begin
    Showmessage('Log out!');
  end;
  ```
  
  #### Sending a message
  ```delphi  
  var
    LMessage: ILogOutMessage
  begin
    LMessage := TLogOutMessage.Create;
    GMessaging.Post(LMessage);
  ```
  
  #### Other message types
  In the previous examples we have shown an interface message, but there are altogether 3 type of messages:
  | Identity | Parameter |
  | --- | --- |
  | name (explicit) | string |
  | guid of parameter interface (implicit) | interface |
  | guid of parameter interface (implicit) + name (explicit) | interface |

  To receive messages with name identity, just declare the name in method attribute:
  ```delphi  
    [Subscribe('Name', TipMessagingThread.Main)]
  ```
  To send messages with name identity, just inform it in the Post call:
  ```delphi  
    GMessaging.Post('Name', LMessage);
  ```
  Note: The explicit name is case-insensitive.

  #### Thread invoke kind
  In [Subscribe] attribute, you can determine how the method receiving a message will be executed:
  | Kind | Description |
  | --- | --- |
  | TipMessagingThread.Posting | The default, the subscriber method will be invoked in the same posting thread where Post was called |
  | TipMessagingThread.Main | The subscriber method will be invoked in the main thread |
  | TipMessagingThread.Async | The subscriber method will be invoked asynchronously in a new anonnymous thread other than the posting thread |
  | TipMessagingThread.Background | If the posting thread is the main thread, the subscriber method will be invoked asynchronously in a new anonnymous thread, other than the posting thread. If the posting thread is not the main thread, the subscriber method will be invoked synchronously in the same posting thread |

  #### Manually subscribe a method at run time
  Although the use of the [Subscribe] attribute to subscribe a method is very practical, it is limited because you have to define the name of the message before compilation, in design time, and sometimes it is really useful to define the name of the messages in runtime. An example, a message for a product that has been changed 'product_105346_changed', that name of that message I can only define at run time, so we added the option to subscribe / unsubscribe a method to listen to a message manually:
  ```delphi
    GMessaging.SubscribeMethod<string>('product_105346_changed', Self.OnProductChanged, TipMessagingThread.Posting);
    GMessaging.UnsubscribeMethod<string>('product_105346_changed', Self.OnProductChanged);
  ```
  These two manual methods are independent of the Subscribe / Unsubscribe methods. You can merge the same class with subscribed methods automatically using the [Subscribe] attribute and calling Subscribe / Unsubscribe, and at the same time in this class having methods that you added manually using SubscribeMethod / UnsubscribeMethod.

  Another benefit of manually enrolling methods is that they do not restrict to public methods only.

  #### Considerations
  The idea of the system is just to forward messages, notices, containing or not information, so keep in mind that it is not advisable to place large codes or codes with stops (waitfor) within the subscribed methods to listen to messages, as this would directly affect the performance of the system, even in asynchronous modes.

  Another consideration is just a reminder of the correct way to use Delphi's TTask. Never use TTask to execute methods with stops (events, semaphores, ...), it was not made for that, its goal is to perform continuous and simpler tasks, if your task is more complex the correct thing is to use a TThread. We are warning you about this, because our system uses delphi's TTask to increase performance mainly in more complex environments in addition to saving resources, and if you use TTask incorrectly in your codes you can cause your application to freeze when sending a message.

# License
The iPub Messaging is licensed under MIT, and the license file is included in this folder.