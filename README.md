<p align="center">
  <img src="assets/logo.png" alt="KeepTeamsGreen Logo" width="400">
</p>

<h1 align="center">KeepTeamsGreen</h1>
<p align="center">
  Mantieni sempre attivo lo stato verde su Microsoft Teams in modo elegante e discreto.
</p>
KeepTeamsGreen è un applicativo open-source per sistemi Windows, concepito per mantenere attivo lo stato di disponibilità (“verde”) nelle piattaforme di collaborazione come Microsoft Teams.
Spesso, infatti, dopo alcuni minuti di inattività apparente il sistema segna l’utente come “Assente” (giallo), anche se questi è realmente presente e operativo in attività non rilevate dal sistema (lettura, riflessione, riunioni telefoniche, ecc.).
L’applicativo risolve in modo elegante tale problematica, garantendo una continuità di stato senza richiedere interventi manuali costanti.

## Principio di funzionamento
Il programma monitora il tempo di inattività dell’utente (assenza di input da tastiera o mouse).
- Se l’inattività non supera la soglia configurata, non interviene.
- Se invece l’inattività supera la soglia prestabilita (ad esempio 120 secondi), il sistema attiva dei micro-movimenti del cursore che vengono registrati da Windows come attività effettiva.

Questi movimenti sono minimi e possono essere configurati in modalità visibile (leggero spostamento del puntatore) o stealth (movimento impercettibile, il cursore torna nella posizione iniziale).

## Interfaccia e Pannello di Controllo
All’avvio, l’utente dispone di un pannello di controllo grafico (GUI), dal quale può gestire ogni aspetto del programma.

### Elementi principali del pannello:
- Soglia di inattività (secondi): tempo trascorso senza input prima dell’intervento automatico.
- Intervallo jitter (secondi): tempo casuale tra un micro-movimento e l’altro, per simulare un comportamento naturale.
- Ampiezza jitter (pixel): distanza massima di spostamento del cursore.
- Avvia minimizzato su Tray: l’applicativo parte in background e compare solo come icona nell’area di notifica (tray di sistema).
- Pulsanti di controllo: Start, Stop, Salva impostazioni.
- Sezione di stato: indica se il programma è attivo, inattivo o in modalità automatica, e mostra l’orario del prossimo intervento programmato.

### Modalità di movimento:
- Visible: spostamento effettivamente percepibile sullo schermo.
- Stealth: il puntatore torna immediatamente nella posizione originale, risultando immobile per l’occhio umano.

## Integrazione con il Tray di Sistema
Il programma può funzionare in modo discreto, posizionandosi nell’area di notifica di Windows (tray).
- Un’icona segnala che KeepTeamsGreen è in esecuzione.
- Con un doppio clic si riapre il pannello di controllo.
- Con il tasto destro è possibile accedere rapidamente ai comandi principali (Apri pannello, Start, Stop, Esci).

Questa modalità consente di mantenere il desktop ordinato, lasciando l’applicativo sempre attivo in background.

## Modalità operative
### Idle Monitoring
- Il sistema osserva il tempo di inattività reale (mouse e tastiera).
- Viene utilizzata la funzione nativa di Windows GetLastInputInfo per un monitoraggio accurato.

### Auto-Jitter
- Se la soglia è superata, viene attivato un movimento minimo del cursore.
- Tale movimento è sufficiente a segnalare attività al sistema operativo e a mantenere “verde” lo stato utente.

### Visibile vs Stealth
- In modalità visibile: il cursore compie piccoli spostamenti casuali.
- In modalità stealth: il cursore si muove ma torna istantaneamente alla posizione di partenza.

## Vantaggi principali
Continuità di stato: garantisce che l’utente risulti disponibile senza interruzioni indesiderate.
Personalizzazione: soglia, intervalli e modalità sono interamente configurabili.
Discrezione: possibilità di avvio minimizzato e funzionamento in tray.
Flessibilità: utile non solo per Teams, ma anche per altri scenari in cui è richiesto mantenere attivo il sistema.
Professionalità: il comportamento simulato è realistico e non invasivo.

## Modalità d’uso consigliata
1. Avviare il programma.
2. Configurare soglia, intervalli e modalità secondo le preferenze personali.
3. Salvare le impostazioni.
4. Avviare l’esecuzione con il pulsante Start.
5. (Opzionale) Attivare Avvia minimizzato su Tray per esecuzioni future più discrete.
6. Tenere Focus sulla finestra Teams.
