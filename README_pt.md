# iPub Messaging
<img src="https://img.shields.io/static/v1?label=Delphi%20Supported%20Versions&message=XE7%2B&color=blueviolet&style=for-the-badge"> <img src="https://img.shields.io/static/v1?label=Supported%20platforms&message=Full%20Cross-Platform&color=blue&style=for-the-badge">

Sistema de mensagens thread-safe, assíncrono e simplista para comunicação entre classes/camadas no delphi criado pela equipe do iPub.

## O problema
  O Delphi tem um sistema de mensagens próprio (System.Messaging.pas) que funciona bem mas é totalmente síncrono e thread-unsafe. Em sistemas multithread temos sempre a necessidade de comunicar com outras classes, algumas vezes de forma síncrona, outras assíncronas, outras sincronizando com o mainthread (no caso da UI), e fazer isso sem um sistema de mensagens próprio (comunicando direto) torna o código grande e complexo, passível de muitos bugs.

## A solução
  Um sistema de mensagens ideal seria um sistema thread-safe que permitisse que uma classe se inscreva e depois cancele sua inscrição para escutar uma determinada mensagem ao longo do tempo, sendo que esta classe recebedora da mensagem quem irá informar como o seu método será executado ao receber a mensagem: no mesmo thread (**posting**), no main thread (**main**), em outro thread (**async**) e em um thread que não seja o main (**background**). Essa é a base do nosso sistema de mensagens, o uso é similar à outro sistema existente, o Delphi Event Bus (DEB).

## Vantagens em relação ao similar (DEB)
 - **Performance**: mais rápido em todas as operações (subscribe, unsubscribe, post), além de ter a inicialização 10x mais rápida
 - **Eficiência**: consome metade da memória
 - **Código menor**: menor binário gerado e compilação mais rápida
 
 Veja a comparação em um ambiente com 1000 objetos:
|  | Subscribe | Post | Unsubscribe |
| --- | --- | --- | --- |
| iPub | 1.6368 ms | 1.3119 ms | 1.7666 ms |
| DEB | 9.8832 ms | 2.0293 ms | 4.0022 ms |

## Uso
  #### Mensagem interface
  
  ```delphi
  ILogOutMessage = interface
    ['{CA101646-B801-433D-B31A-ADF7F31AC59E}']
    // here you can put any data
  end;
  ```
    
  #### Escutando uma mensagem
  Primeiro você deve inscrever sua classe para escutar mensagens, então todos os métodos públicos que tiverem o atributo [Subscribe] serão inscritos.
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
  
  #### Enviando uma mensagem
  ```delphi  
  var
    LMessage: ILogOutMessage
  begin
    LMessage := TLogOutMessage.Create;
    GMessaging.Post(LMessage);
  ```
  
  #### Outros tipos de mensagem
  Nos exemplos anteriores mostramos uma mensagem interface, mas existem ao todo 3 formas de mensagens: 
  | Identidade | Parâmetro |
  | --- | --- |
  | nome (explícito) | string |
  | guid da interface do parametro (implícito) | interface |
  | guid da interface do parametro (implícito) + nome (explícito) | interface |

  Para receber uma mensagem com nome, basta declarar o nome no atributo do método
  ```delphi  
    [Subscribe(TipMessagingThread.Main, 'Name')]
  ```
  Para enviar uma mensagem identficada por um nome, basta informá-la no próprio Post:
  ```delphi  
    GMessaging.Post('Name', LMessage);
  ```
  Nota: O nome explícito é case-insensitive.
   
# Licença
O iPub Messaging é licenciado pelo MIT e o arquivo de licença está incluído nesta pasta.