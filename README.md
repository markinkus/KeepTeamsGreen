<h1 align="center">KeepTeamsGreen</h1>

<p align="center">
  Mantieni attivo lo stato verde nelle piattaforme di collaborazione e controlla cosa sta succedendo da una piccola centrale operativa.
</p>
<p align="center">
  <img src="logo.png" alt="KeepTeamsGreen Logo" width="220">
</p>

**KeepTeamsGreen** e un'applicazione open source per Windows che monitora il tempo di inattivita e, quando serve, genera micro-movimenti del cursore. La versione 2.2.0 aggiunge regole locali, una watchlist contatti, fasce orarie, recupero da Assente e diagnostica.

> [!IMPORTANT]
> Il tool non modifica la presenza tramite API Microsoft e non promette uno stato che non riesce a verificare. Mantiene attiva la sessione simulando un minimo input del cursore; Teams conserva sempre il controllo finale della presenza.

## Centrale operativa

Il nuovo pannello mostra in tempo reale:

- stato del motore di protezione;
- stato presenza esposto da Teams: Disponibile, Assente, Occupato, Non disturbare o Offline;
- presenza o meno del focus sulla finestra di Teams;
- tempo di inattivita, prossimo jitter, ultimo intervento e numero di interventi;
- alert visivo, sonoro e nell'area di notifica quando uno stato verde confermato cambia;
- stato esplicito `Non rilevato` quando Teams non rende disponibile un dato affidabile.

Il focus viene individuato dalla finestra Windows in primo piano. La presenza viene letta tramite **Windows UI Automation**, cioe dai controlli accessibili esposti dall'interfaccia di Teams. Questo approccio non usa credenziali, token o traffico di rete.

## Funzioni principali preservate

- **Soglia di inattivita**: tempo senza input prima di preparare l'intervento.
- **Tempo tra i jitter**: range minimo/massimo configurabile da 1 a 600 secondi. Il default e `3 / 3`, cioe un jitter ogni 3 secondi; valori diversi introducono un'attesa casuale nel range.
- **Ampiezza jitter**: spostamento massimo in pixel.
- **Modalita visibile**: il cursore resta nella nuova posizione.
- **Modalita stealth**: il cursore torna subito alla posizione originale.
- **Start e Stop**: disponibili sia dal pannello sia dal menu tray.

## Contatti e regole locali (2.2)

Apri **CONTATTI E REGOLE**, aggiungi una persona e scrivi il nome completo esattamente come appare in Teams. Seleziona:

- `Available`: avvisa alla prima disponibilita confermata e ai successivi ritorni a Disponibile;
- `Change`: avvisa sui cambi di stato confermati dopo una prima lettura di riferimento;
- giorni (`Weekdays` = lun-ven, `Weekend` = sab-dom, `Everyday` = tutti) e fascia `HH:mm`;
- intervallo di controllo (5-300 secondi, default 15) e pausa minima tra gli avvisi della stessa persona (60-3600 secondi, default 120).

Attiva il monitor e premi **SALVA REGOLE**. Il salvataggio di questa finestra e indipendente dalle impostazioni jitter del pannello principale. La watchlist accetta fino a 40 nomi. Le modifiche alle regole azzerano le osservazioni precedenti.

La lettura e **passiva tramite Windows UI Automation**: Teams deve esporre un indicatore accessibile associato al nome, per esempio nella lista chat visibile. Il tool non apre chat, non scorre la lista e non cerca persone automaticamente. I contatti fuori dall'interfaccia caricata, i nomi non riconosciuti, gli indicatori discordanti e i dati scaduti mostrano **Non rilevato**, mai Offline per deduzione. Gli omonimi non sono distinguibili con certezza: usare solo etichette univoche nella propria interfaccia.

Ogni stato richiede due letture coerenti distanziate di almeno 3 secondi. La freschezza scade dopo il maggiore tra 45 secondi e tre intervalli di controllo; una lettura senza indicatore invalida subito lo stato. Le letture scadute non generano avvisi di cambio stato. Gli orari si riferiscono al PC; una fascia notturna e attribuita al giorno in cui inizia, e orari uguali significano 24 ore.

La tabella mostra anche l'ora dell'ultima osservazione. **Controlla ora** anticipa la prossima lettura; **Silenzia contatti 15 min** sospende gli avvisi senza bloccare le letture. Il monitor contatti funziona anche quando il motore jitter e fermo.

## Fasce personali, focus e recupero

In **Orari e recupero** puoi limitare la protezione a giorni e fascia oraria. Premi Avvia nel pannello principale per armare il motore: attende fuori fascia e riprende nella fascia. Stop lo disarma. Il programma deve essere aperto: non crea attivita pianificate in Windows.

Il recupero opzionale esegue un jitter sul passaggio personale confermato **Verde > Assente**, al massimo una volta ogni due minuti, e controlla il ritorno a verde entro 30 secondi. Il risultato indica una nuova osservazione, non una garanzia che il jitter abbia modificato la presenza. Occupato e Non disturbare non vengono modificati. **Porta Teams davanti** permette di recuperare il focus su richiesta; Windows potrebbe non concederlo.

Quando Windows e bloccato o il desktop non e accessibile, il jitter e la lettura vengono sospesi. Allo sblocco si scartano le osservazioni precedenti. Dopo la sospensione del PC i dati troppo vecchi vengono invalidati.

## Diagnostica e dati locali

La scheda **Diagnostica** mostra salute del lettore, ultima lettura, stato del recupero, ultimi 100 eventi in memoria ed errori con codice e contatore. I tentativi falliti applicano un'attesa crescente fino a due minuti. Una lettura UI Automation bloccata non avvia altri worker: dopo 12 secondi viene segnalato il timeout e i dati vecchi non vengono accettati. **Riprova lettura Teams** riparte appena il provider precedente ha terminato; se rimane bloccato e necessario riavviare il tool/Teams.

Il log ruota a 1 MiB conservando una copia precedente. **Esporta diagnostica** salva versione, contatori e codici errore, escludendo nomi e stati dei colleghi, configurazione, percorsi personali e log grezzi. I nomi della watchlist sono salvati nel `config.json` locale, gli stati e gli orari di osservazione restano in memoria e non vengono registrati nel log. Il programma non effettua richieste Graph, login Microsoft, webhook o telemetria. La normale attivita di rete di Teams rimane gestita da Teams.

## Tray, taskbar e icona

Il logo mostrato in questo README viene ora usato anche dalla finestra e dall'icona nell'area di notifica. La gestione della finestra e stata resa coerente:

- `X` e il pulsante Riduci a icona nascondono il pannello, ma non fermano il motore e non eliminano l'icona tray;
- doppio clic sull'icona tray riapre il pannello e ripristina correttamente il pulsante nella barra delle applicazioni;
- **Esci** dal menu tray chiude davvero timer, widget e icona;
- l'avvio minimizzato non forza la ricomparsa del pannello.

## Mostriciattolo

Attiva **Mostra il mostriciattolo quando la protezione e attiva** per avere un piccolo widget sempre in primo piano:

- `GREEN OK` quando Teams espone uno stato Disponibile;
- `CHECK TEAMS` quando viene rilevato uno stato diverso;
- `KTG ATTIVO` quando il motore lavora ma la presenza non e verificabile.

Il widget si puo trascinare, aprire con doppio clic o nascondere dal menu contestuale.

## Impostazioni affidabili

La configurazione viene validata e salvata in modo atomico in:

```text
%APPDATA%\KeepTeamsGreen\config.json
```

Prima di sostituire un file esistente viene mantenuto anche `config.backup.json`. Gli errori non vengono piu ignorati: il pannello mostra l'esito reale e il dettaglio viene scritto in `%APPDATA%\KeepTeamsGreen\last_run.log`. Le configurazioni della versione precedente vengono migrate automaticamente con valori sicuri per le nuove opzioni.

## Avvio

Su Windows 10 o 11, dalla cartella del progetto:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\script.gui.ps1
```

Durante lo sviluppo e consigliato eseguire direttamente `script.gui.ps1`, cosi il comportamento corrisponde sempre al sorgente corrente. `KeepTeamsGreen.exe` deve essere rigenerato su Windows dopo ogni modifica del sorgente.

Per creare l'eseguibile standalone con script, logo e icona incorporati serve [.NET SDK 8](https://dotnet.microsoft.com/download/dotnet/8.0) o successivo. Esegui:

```powershell
.\build.ps1
```

La build valida prima la sintassi, incorpora anche `logo.png` per il widget e conserva l'eseguibile precedente come `KeepTeamsGreen.previous.exe`.
I moduli in `local/` sono incorporati nell'EXE: basta copiare l'eseguibile sul PC Windows. Per l'avvio da sorgente servono anche i file nella cartella `local/`.

Verifica delle regole (eseguibile anche con PowerShell 7 su Linux):

```powershell
pwsh -NoProfile -File ./tests/Test-LocalRules.ps1
```

Collaudo dell'interfaccia reale su Windows PowerShell 5.1, con configurazione temporanea isolata:

```powershell
powershell.exe -NoProfile -STA -File .\tests\Smoke-Windows.ps1
```

### Firma digitale e SmartScreen

I campi `Company` e `Product` nei dettagli dell'EXE non definiscono il publisher mostrato da Windows. Per ottenere `Autore: Markino Solutions` serve un certificato attendibile con uso **Code Signing** e relativa chiave privata. Se il certificato e installato nello store personale di Windows, la build puo firmare e verificare automaticamente l'eseguibile:

```powershell
.\build.ps1 `
  -SigningCertificateThumbprint 'THUMBPRINT_CERTIFICATO' `
  -TimestampServer 'URL_TIMESTAMP_FORNITO_DALLA_CA'
```

Senza `-SigningCertificateThumbprint` la build continua, ma segnala chiaramente che l'EXE resta senza firma. Per un test locale di un file ricevuto tramite browser si puo controllare **Proprieta > Annulla blocco** oppure, dopo aver verificato origine e contenuto, usare:

```powershell
Unblock-File .\KeepTeamsGreen.exe
```

## Limiti del monitor Teams

Microsoft puo cambiare struttura e nomi dei controlli dell'interfaccia. Se il pulsante del profilo non espone la presenza a Windows UI Automation, KeepTeamsGreen mostra `Non rilevato` e non genera un falso alert di cambio stato. Teams nel browser e riconosciuto quando il titolo della finestra contiene `Microsoft Teams`; la lettura della presenza dipende comunque dai controlli accessibili del browser.

## Compatibilita

- Windows 10 e Windows 11;
- Windows PowerShell 5.1 in modalita STA;
- client Teams classico, nuovo client `ms-teams` e Teams aperto nei browser piu comuni;
- nessuna credenziale Microsoft richiesta.

## Stack tecnologico

- **PowerShell 5.1**: interfaccia WinForms, motore jitter, configurazione, tray e coordinamento generale.
- **C# / .NET Framework 4.8**: launcher standalone, interoperabilita Win32 e lettura asincrona di Teams tramite UI Automation.
- **XML / MSBuild**: definizione del progetto e processo di compilazione dell'eseguibile.
- **JSON**: configurazione persistente in `%APPDATA%`.
- **Markdown**: documentazione del progetto.

## Disclaimer legale

Questo progetto e completamente indipendente e non affiliato a Microsoft, Slack, Zoom o altre piattaforme di collaborazione. Microsoft Teams e i relativi marchi appartengono a Microsoft Corporation. L'uso del termine "Teams" nel nome e puramente descrittivo.

## Licenza

Il progetto e distribuito con licenza [Apache 2.0](LICENSE).
