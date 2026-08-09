<h1 align="center">KeepTeamsGreen</h1>

<p align="center">
  Mantieni attivo lo stato verde nelle piattaforme di collaborazione e controlla cosa sta succedendo da una piccola centrale operativa.
</p>
<p align="center">
  <img src="logo.png" alt="KeepTeamsGreen Logo" width="220">
</p>

**KeepTeamsGreen** e un'applicazione open source per Windows che monitora il tempo di inattivita e, quando serve, genera micro-movimenti del cursore. La versione 2.1.1 aggiunge un pannello in tempo reale per Microsoft Teams, alert sul cambio presenza, una gestione tray piu solida e il mostriciattolo del progetto come widget opzionale.

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
