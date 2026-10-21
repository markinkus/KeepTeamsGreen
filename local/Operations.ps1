$script:LocalGeneration = 0
$script:ContactRuntime = @{}
$script:ContactScanDue = Get-Date
$script:LastContactScan = $null
$script:LocalErrors = @{}
$script:LocalEvents = New-Object 'System.Collections.Generic.List[object]'
$script:SnoozeUntil = $null
$script:RecoveryDeadline = $null
$script:RecoveryLastAttempt = $null
$script:RecoveryStatus = 'Nessun intervento richiesto'
$script:WasDesktopUnlocked = $true
$script:LocalForm = $null

function Add-LocalEvent {
    param([string]$Kind, [string]$Message)
    $script:LocalEvents.Insert(0, [pscustomobject]@{ At = (Get-Date); Kind = $Kind; Message = $Message })
    if ($script:LocalEvents.Count -gt 100) { $script:LocalEvents.RemoveAt(100) }
}

function Write-LocalError {
    param([string]$Code, [string]$Detail)
    $now = Get-Date
    if (-not $script:LocalErrors.ContainsKey($Code)) {
        $script:LocalErrors[$Code] = @{ Count = 0; At = $now; Detail = $Detail; Logged = $null }
    }
    $errorState = $script:LocalErrors[$Code]
    $errorState.Count++
    $errorState.At = $now
    $errorState.Detail = $Detail
    if ($null -eq $errorState.Logged -or ($now - $errorState.Logged).TotalSeconds -ge 30) {
        $errorState.Logged = $now
        Add-LocalEvent 'Errore' "$Code - $Detail"
        Write-AppLog "$Code - $Detail"
    }
}

function Get-EnginePauseReason {
    if (-not [Win32Window]::IsDesktopUnlocked()) { return 'Windows bloccato o desktop non accessibile' }
    if ([bool]$Config['ScheduleEnabled'] -and -not (Test-LocalWindow -Now (Get-Date) -Days $Config['ScheduleDays'] -From $Config['ScheduleFrom'] -To $Config['ScheduleTo'])) {
        return "Fuori fascia $($Config['ScheduleFrom']) - $($Config['ScheduleTo'])"
    }
    return $null
}

function Test-ContactActive {
    param($Person, [datetime]$Now)
    return ([bool]$Person.Enabled -and (Test-LocalWindow -Now $Now -Days $Person.Days -From $Person.From -To $Person.To))
}

function Get-DueContactNames {
    if (-not [bool]$Config['MonitorColleagues'] -or -not [Win32Window]::IsDesktopUnlocked()) { return }
    $now = Get-Date
    if ($now -lt $script:ContactScanDue) { return }
    $script:ContactScanDue = $now.AddSeconds([int]$Config['ColleagueScanSeconds'])
    foreach ($person in @($Config['Colleagues'])) {
        if (Test-ContactActive $person $now) { [string]$person.Name }
    }
}

function Receive-ContactReadings {
    param($Readings)
    if (-not [bool]$Config['MonitorColleagues'] -or -not [Win32Window]::IsDesktopUnlocked()) { return }
    if (@($Readings).Count -eq 0) { return }
    $now = Get-Date
    $script:LastContactScan = $now
    foreach ($reading in @($Readings)) {
        $matches = @($Config['Colleagues'] | Where-Object { $_.Name -eq $reading.Name })
        if ($matches.Count -ne 1 -or -not (Test-ContactActive $matches[0] $now)) { continue }
        $person = $matches[0]
        if (-not $script:ContactRuntime.ContainsKey($person.Name)) {
            $script:ContactRuntime[$person.Name] = New-ContactRuntime
        }
        $runtime = $script:ContactRuntime[$person.Name]
        $runtime.Detail = [string]$reading.Diagnostic
        $notifyContact = Update-ContactObservation -Runtime $runtime -State $reading.State -Now $now -Rule $person.Rule `
            -StaleSeconds ([Math]::Max(45, 3 * [int]$Config['ColleagueScanSeconds'])) -CooldownSeconds ([int]$Config['ColleagueCooldownSeconds'])
        if ($notifyContact -and ($null -eq $script:SnoozeUntil -or $now -ge $script:SnoozeUntil)) {
            $stateText = Get-PresenceDisplayName $runtime.State
            $Notify.ShowBalloonTip(5000, 'KeepTeamsGreen - Contatto', "$($person.Name): $stateText", [System.Windows.Forms.ToolTipIcon]::Info)
            # Names and contact history stay in RAM, not in application logs.
            Add-LocalEvent 'Contatto' 'Regola contatto soddisfatta (nome omesso)'
        }
    }
}

function Invoke-AwayRecovery {
    if (-not $script:IsRunning -or -not [bool]$Config['RecoverAway'] -or (Get-EnginePauseReason)) { return }
    $now = Get-Date
    if ($null -ne $script:RecoveryLastAttempt -and ($now - $script:RecoveryLastAttempt).TotalMinutes -lt 2) { return }
    try {
        Invoke-Jitter -Mode ([string]$Config['Mode']) -MaximumPixels ([int]$Config['MaxJitterPixels'])
        $script:LastJitterAt = $now
        $script:JitterCount++
        $script:RecoveryLastAttempt = $now
        $script:RecoveryDeadline = $now.AddSeconds(30)
        $script:RecoveryStatus = 'Jitter eseguito: verifica verde entro 30 secondi'
        $script:NextPresenceProbeAt = $now
        Add-LocalEvent 'Recupero' 'Assente confermato: jitter eseguito'
    } catch { Write-LocalError 'RECOVERY' $_.Exception.GetType().Name }
}

function Complete-AwayRecovery {
    param([string]$State)
    if ($null -eq $script:RecoveryDeadline) { return }
    if ($State -eq 'Available') {
        $script:RecoveryStatus = 'Verde confermato dopo il tentativo'
        $script:RecoveryDeadline = $null
        Add-LocalEvent 'Recupero' 'Verde nuovamente rilevato'
    } elseif ($State -in @('Busy', 'Dnd')) {
        $script:RecoveryStatus = 'Occupato / Non disturbare: nessun altro intervento'
        $script:RecoveryDeadline = $null
    }
}

function Focus-TeamsWindow {
    $window = Get-TeamsWindow
    if ($null -eq $window) { $lblLocalFeedback.Text = 'Nessuna finestra Teams trovata.'; return }
    if (-not [Win32Window]::FocusWindow($window.Handle)) {
        $lblLocalFeedback.Text = 'Windows non ha concesso il focus: seleziona Teams nella barra.'
    } else { $lblLocalFeedback.Text = 'Teams portato in primo piano.' }
}

function Save-LocalOptions {
    try {
        $contactGrid.EndEdit() | Out-Null
        $people = @()
        $seen = @{}
        foreach ($row in $contactGrid.Rows) {
            if ($row.IsNewRow) { continue }
            $name = ([string]$row.Cells['Person'].Value).Trim()
            if ($name.Length -lt 3 -or $name.Length -gt 100) { throw 'Usa un nome completo di almeno 3 caratteri (massimo 100).' }
            if ($seen.ContainsKey($name)) { throw 'La lista contiene un nome duplicato.' }
            $seen[$name] = $true
            $from = [string]$row.Cells['From'].Value
            $to = [string]$row.Cells['To'].Value
            if (-not (Test-LocalTime $from) -or -not (Test-LocalTime $to)) { throw 'Inserisci gli orari dei contatti nel formato HH:mm.' }
            $rule = [string]$row.Cells['Rule'].Value
            $days = [string]$row.Cells['Days'].Value
            if ($rule -notin @('Available', 'Change') -or $days -notin @('Everyday', 'Weekdays', 'Weekend')) { throw 'Scegli una regola e i giorni per ogni contatto.' }
            $people += [pscustomobject]@{ Name = $name; Enabled = [bool]$row.Cells['Active'].Value; Rule = $rule; Days = $days; From = $from; To = $to }
        }
        if ($people.Count -gt 40) { throw 'Massimo 40 persone nella watchlist.' }
        if (-not (Test-LocalTime $txtScheduleFrom.Text) -or -not (Test-LocalTime $txtScheduleTo.Text)) { throw 'Inserisci la fascia della protezione nel formato HH:mm.' }

        $snapshot = [ordered]@{}
        foreach ($key in $Config.Keys) { $snapshot[$key] = $Config[$key] }
        $Config['Colleagues'] = @($people)
        $Config['MonitorColleagues'] = $chkLocalContacts.Checked
        $Config['ColleagueScanSeconds'] = [int]$nudContactScan.Value
        $Config['ColleagueCooldownSeconds'] = [int]$nudContactCooldown.Value
        $Config['ScheduleEnabled'] = $chkSchedule.Checked
        $Config['ScheduleDays'] = [string]$cmbScheduleDays.SelectedItem
        $Config['ScheduleFrom'] = $txtScheduleFrom.Text
        $Config['ScheduleTo'] = $txtScheduleTo.Text
        $Config['RecoverAway'] = $chkRecovery.Checked
        if (-not (Save-Config)) {
            foreach ($key in $snapshot.Keys) { $Config[$key] = $snapshot[$key] }
            throw 'Salvataggio fallito. La configurazione operativa precedente e stata conservata.'
        }
        $script:LocalGeneration++
        $script:ContactRuntime = @{}
        $script:ContactScanDue = Get-Date
        $script:NextPresenceProbeAt = Get-Date
        $script:NextJitterAt = $null
        $lblLocalFeedback.Text = 'Regole salvate. Nuove osservazioni in attesa di conferma.'
        Add-LocalEvent 'Impostazioni' 'Regole locali aggiornate'
    } catch {
        $lblLocalFeedback.Text = $_.Exception.Message
        Write-LocalError 'OPTIONS_SAVE' $_.Exception.GetType().Name
    }
}

function Export-LocalDiagnostics {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'Diagnostica JSON (*.json)|*.json'
    $dialog.FileName = 'KeepTeamsGreen-diagnostics.json'
    try {
        if ($dialog.ShowDialog($LocalForm) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $report = [ordered]@{
            Version = $AppVersion; At = (Get-Date).ToString('o')
            PowerShell = $PSVersionTable.PSVersion.ToString()
            UIAutomation = $script:UIAutomationAvailable
            EngineRunning = $script:IsRunning; JitterCount = $script:JitterCount
            OwnState = $script:CommittedPresence; Focus = $script:TeamsFocusState
            LastOwnRead = $script:LastPresenceReadAt
            ColleagueMonitor = [bool]$Config['MonitorColleagues']
            ContactCount = @($Config['Colleagues']).Count
            LastContactRead = $script:LastContactScan
            Errors = @($script:LocalErrors.Keys | ForEach-Object {
                [pscustomobject]@{ Code = $_; Count = $script:LocalErrors[$_].Count; At = $script:LocalErrors[$_].At }
            })
        }
        [IO.File]::WriteAllText($dialog.FileName, ($report | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        $lblLocalFeedback.Text = 'Diagnostica esportata: esclusi nomi, stati dei colleghi, percorsi e log grezzi.'
    } catch { Write-LocalError 'EXPORT' $_.Exception.GetType().Name; $lblLocalFeedback.Text = 'Esportazione fallita.' }
    finally { $dialog.Dispose() }
}

function Update-LocalOperations {
    $now = Get-Date
    $unlocked = [Win32Window]::IsDesktopUnlocked()
    if (-not $unlocked -or -not $script:WasDesktopUnlocked) {
        $script:CommittedPresence = 'Unknown'
        $script:PendingPresence = $null
        $script:PendingPresenceSince = $null
        $script:ContactRuntime = @{}
        $script:LocalGeneration++
        $script:NextJitterAt = $null
        $script:ContactScanDue = $now
    }
    $script:WasDesktopUnlocked = $unlocked
    $staleSeconds = [Math]::Max(45, 3 * [int]$Config['ColleagueScanSeconds'])
    foreach ($person in @($Config['Colleagues'])) {
        if (-not $script:ContactRuntime.ContainsKey($person.Name)) { $script:ContactRuntime[$person.Name] = New-ContactRuntime }
        $runtime = $script:ContactRuntime[$person.Name]
        if (-not [bool]$Config['MonitorColleagues'] -or -not (Test-ContactActive $person $now) -or
            $null -eq $script:TeamsWindow -or -not $unlocked -or
            ($null -ne $runtime.LastSeen -and ($now - $runtime.LastSeen).TotalSeconds -gt $staleSeconds)) {
            $runtime.State = 'Unknown'; $runtime.Candidate = $null; $runtime.CandidateAt = $null
        }
    }
    if ($null -ne $script:RecoveryDeadline -and $now -gt $script:RecoveryDeadline) {
        $script:RecoveryDeadline = $null
        $script:RecoveryStatus = 'Verde non confermato entro 30 secondi'
        Add-LocalEvent 'Recupero' $script:RecoveryStatus
    }
    if ($null -eq $LocalForm -or -not $LocalForm.Visible) { return }
    foreach ($row in $contactGrid.Rows) {
        if ($row.IsNewRow) { continue }
        $name = [string]$row.Cells['Person'].Value
        if (-not $script:ContactRuntime.ContainsKey($name)) { $row.Cells['State'].Value = 'Non salvato'; continue }
        $runtime = $script:ContactRuntime[$name]
        $row.Cells['State'].Value = Get-PresenceDisplayName $runtime.State
        $row.Cells['Seen'].Value = Get-TimeText $runtime.LastSeen
        $row.Cells['State'].ToolTipText = $runtime.Detail
    }
    $lblContactHealth.Text = 'Ultima scansione: ' + (Get-TimeText $script:LastContactScan) + ' | Stato corrente solo dopo due letture; nessun dato = Non rilevato.'
    $taskState = 'Pronto'
    if ($null -ne $script:PresenceTask) { $taskState = 'Lettura in corso' }
    $pause = Get-EnginePauseReason
    if (-not $pause) { $pause = 'Nessuna pausa' }
    $lblDiagnostic.Text = "Versione $AppVersion | UI Automation: $($script:UIAutomationAvailable)`r`nMotore: $($script:IsRunning) | $pause`r`nLettore: $taskState | Ultima lettura: $(Get-TimeText $script:LastPresenceReadAt)`r`nTeams: $($script:PresenceDiagnostic)`r`nRecupero: $($script:RecoveryStatus)`r`nNotifiche contatti silenziate fino a: $(Get-TimeText $script:SnoozeUntil)"
    $eventBox.BeginUpdate()
    try {
        $eventBox.Items.Clear()
        foreach ($entry in $script:LocalEvents) { $eventBox.Items.Add(('{0:HH:mm:ss} [{1}] {2}' -f $entry.At, $entry.Kind, $entry.Message)) | Out-Null }
        foreach ($code in $script:LocalErrors.Keys) { $eventBox.Items.Add(('ERROR {0}: {1} occorrenze | {2}' -f $code, $script:LocalErrors[$code].Count, $script:LocalErrors[$code].Detail)) | Out-Null }
    } finally { $eventBox.EndUpdate() }
}

function New-LocalButton {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 170)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object Drawing.Point($X, $Y)
    $button.Size = New-Object Drawing.Size($Width, 34)
    Set-ButtonStyle $button $ColorGreenDark $ColorText
    $Parent.Controls.Add($button)
    return $button
}

function Initialize-LocalOperations {
    $script:LocalForm = New-Object System.Windows.Forms.Form
    $LocalForm.Text = 'KeepTeamsGreen - Regole locali e contatti'
    $LocalForm.ClientSize = New-Object Drawing.Size(980, 650)
    $LocalForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $LocalForm.MaximizeBox = $false
    $LocalForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $LocalForm.Icon = $script:AppIcon
    $LocalForm.BackColor = $ColorBackground
    $LocalForm.ForeColor = $ColorText
    $LocalForm.Font = New-Object Drawing.Font('Segoe UI', 9)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object Drawing.Point(16, 16)
    $tabs.Size = New-Object Drawing.Size(948, 572)
    $contactsTab = New-Object System.Windows.Forms.TabPage
    $contactsTab.Text = 'Contatti'
    $optionsTab = New-Object System.Windows.Forms.TabPage
    $optionsTab.Text = 'Orari e recupero'
    $healthTab = New-Object System.Windows.Forms.TabPage
    $healthTab.Text = 'Diagnostica'
    foreach ($tab in @($contactsTab, $optionsTab, $healthTab)) {
        $tab.BackColor = $ColorCard
        $tab.ForeColor = $ColorText
        $tabs.TabPages.Add($tab)
    }
    $LocalForm.Controls.Add($tabs)

    $script:chkLocalContacts = New-DarkCheckBox 'Abilita monitor contatti sul PC' 16 ([bool]$Config['MonitorColleagues'])
    $contactsTab.Controls.Add($chkLocalContacts)
    $contactsTab.Controls.Add((New-Label 'Controllo (s)' 420 20 100 24))
    $script:nudContactScan = New-Object System.Windows.Forms.NumericUpDown
    $nudContactScan.Minimum = 5; $nudContactScan.Maximum = 300; $nudContactScan.Value = $Config['ColleagueScanSeconds']
    $nudContactScan.Location = New-Object Drawing.Point(525, 18); $nudContactScan.Width = 65
    $contactsTab.Controls.Add($nudContactScan)
    $contactsTab.Controls.Add((New-Label 'Pausa alert (s)' 620 20 110 24))
    $script:nudContactCooldown = New-Object System.Windows.Forms.NumericUpDown
    $nudContactCooldown.Minimum = 60; $nudContactCooldown.Maximum = 3600; $nudContactCooldown.Value = $Config['ColleagueCooldownSeconds']
    $nudContactCooldown.Location = New-Object Drawing.Point(740, 18); $nudContactCooldown.Width = 80
    $contactsTab.Controls.Add($nudContactCooldown)
    $contactsTab.Controls.Add((New-Label 'Nome completo come appare in Teams. Available = avvisa quando disponibile; Change = cambio confermato.' 20 58 890 24 9))
    $contactsTab.Controls.Add((New-Label 'Weekdays = lun-ven; Weekend = sab-dom; Everyday = tutti. Orari uguali = 24 ore. Le righe si salvano con SALVA REGOLE.' 20 84 895 32 9))

    $script:contactGrid = New-Object System.Windows.Forms.DataGridView
    $contactGrid.Location = New-Object Drawing.Point(20, 122)
    $contactGrid.Size = New-Object Drawing.Size(894, 300)
    $contactGrid.BackgroundColor = $ColorBackground
    $contactGrid.DefaultCellStyle.BackColor = $ColorCardAlt
    $contactGrid.DefaultCellStyle.ForeColor = $ColorText
    $contactGrid.DefaultCellStyle.SelectionBackColor = $ColorGreenDark
    $contactGrid.DefaultCellStyle.SelectionForeColor = $ColorText
    $contactGrid.ColumnHeadersDefaultCellStyle.BackColor = $ColorCard
    $contactGrid.ColumnHeadersDefaultCellStyle.ForeColor = $ColorText
    $contactGrid.EnableHeadersVisualStyles = $false
    $contactGrid.RowHeadersVisible = $false
    $contactGrid.AllowUserToAddRows = $false
    $contactGrid.AllowUserToDeleteRows = $false
    $contactGrid.AutoGenerateColumns = $false
    foreach ($spec in @(
        @('Active', 'On', 40, 'Check'), @('Person', 'Persona', 205, 'Text'),
        @('Rule', 'Regola', 90, 'Rule'), @('Days', 'Giorni', 90, 'Days'),
        @('From', 'Dalle', 60, 'Text'), @('To', 'Alle', 60, 'Text'),
        @('State', 'Stato attuale', 150, 'Read'), @('Seen', 'Ultima lettura', 100, 'Read')
    )) {
        if ($spec[3] -eq 'Check') { $column = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn }
        elseif ($spec[3] -in @('Rule', 'Days')) {
            $column = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
            $column.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            if ($spec[3] -eq 'Rule') { $column.Items.AddRange([object[]]@('Available', 'Change')) }
            else { $column.Items.AddRange([object[]]@('Weekdays', 'Weekend', 'Everyday')) }
        } else { $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn }
        $column.Name = $spec[0]; $column.HeaderText = $spec[1]; $column.Width = $spec[2]
        $column.ReadOnly = $spec[3] -eq 'Read'
        $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
        $contactGrid.Columns.Add($column) | Out-Null
    }
    $contactGrid.Add_DataError({ $this.CancelEdit(); $lblLocalFeedback.Text = 'Valore non valido nella tabella contatti.' })
    foreach ($person in @($Config['Colleagues'])) {
        $contactGrid.Rows.Add([object[]]@($person.Enabled, $person.Name, $person.Rule, $person.Days, $person.From, $person.To, 'Non rilevato', '-')) | Out-Null
    }
    $contactsTab.Controls.Add($contactGrid)
    $addButton = New-LocalButton $contactsTab 'Aggiungi persona' 20 434
    $addButton.Add_Click({
        if ($contactGrid.Rows.Count -lt 40) { $contactGrid.Rows.Add([object[]]@($true, '', 'Available', 'Weekdays', '09:00', '18:00', 'Non salvato', '-')) | Out-Null }
    })
    $removeButton = New-LocalButton $contactsTab 'Rimuovi selezionata' 200 434
    $removeButton.Add_Click({ if ($null -ne $contactGrid.CurrentRow) { $contactGrid.Rows.RemoveAt($contactGrid.CurrentRow.Index) } })
    $scanButton = New-LocalButton $contactsTab 'Controlla ora' 380 434
    $scanButton.Add_Click({ $script:ContactScanDue = Get-Date; $script:NextPresenceProbeAt = Get-Date; $lblLocalFeedback.Text = 'Controllo richiesto. Mantieni visibile in Teams la lista con i contatti.' })
    $snoozeButton = New-LocalButton $contactsTab 'Silenzia contatti 15 min' 560 434 190
    $snoozeButton.Add_Click({ $script:SnoozeUntil = (Get-Date).AddMinutes(15) })
    $script:lblContactHealth = New-Label '' 20 477 894 26 9
    $contactsTab.Controls.Add($lblContactHealth)
    $contactsTab.Controls.Add((New-Label 'Lettura passiva: niente login, richieste Graph o apertura automatica di chat. Indicatori assenti o discordanti = Non rilevato.' 20 506 894 32 8))

    $script:chkSchedule = New-DarkCheckBox 'Limita la protezione alla fascia oraria' 24 ([bool]$Config['ScheduleEnabled'])
    $optionsTab.Controls.Add($chkSchedule)
    $optionsTab.Controls.Add((New-Label 'Giorni' 20 70 100 24))
    $script:cmbScheduleDays = New-Object System.Windows.Forms.ComboBox
    $cmbScheduleDays.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbScheduleDays.Items.AddRange(@('Weekdays', 'Weekend', 'Everyday'))
    $cmbScheduleDays.SelectedItem = $Config['ScheduleDays']
    $cmbScheduleDays.Location = New-Object Drawing.Point(130, 68)
    $optionsTab.Controls.Add($cmbScheduleDays)
    $optionsTab.Controls.Add((New-Label 'Dalle / alle' 20 115 100 24))
    $script:txtScheduleFrom = New-Object System.Windows.Forms.TextBox
    $txtScheduleFrom.Location = New-Object Drawing.Point(130, 112); $txtScheduleFrom.Width = 85; $txtScheduleFrom.Text = $Config['ScheduleFrom']
    $script:txtScheduleTo = New-Object System.Windows.Forms.TextBox
    $txtScheduleTo.Location = New-Object Drawing.Point(235, 112); $txtScheduleTo.Width = 85; $txtScheduleTo.Text = $Config['ScheduleTo']
    $optionsTab.Controls.AddRange(@($txtScheduleFrom, $txtScheduleTo))
    $optionsTab.Controls.Add((New-Label 'Premi Avvia nel pannello: il motore attende fuori fascia e riprende nella fascia. Stop disarma la protezione.' 20 153 850 40))
    $optionsTab.Controls.Add((New-Label 'Orari locali del PC, anche a cavallo della mezzanotte. La fascia si applica alla protezione, ogni contatto ha i propri orari.' 20 196 850 40))
    $script:chkRecovery = New-DarkCheckBox 'Jitter al passaggio confermato Verde > Assente' 252 ([bool]$Config['RecoverAway'])
    $chkRecovery.Width = 550
    $optionsTab.Controls.Add($chkRecovery)
    $optionsTab.Controls.Add((New-Label 'Un solo tentativo ogni 2 minuti; verifica per 30 secondi. Occupato e Non disturbare non vengono corretti.' 20 295 850 40))
    $optionsTab.Controls.Add((New-Label 'Quando Windows e bloccato, jitter e lettura contatti sono sospesi. Il ripristino richiede osservazioni nuove.' 20 344 850 40))
    $focusButton = New-LocalButton $optionsTab 'Porta Teams davanti' 20 410 210
    $focusButton.Add_Click({ Focus-TeamsWindow })
    $optionsTab.Controls.Add((New-Label 'Focus su richiesta: il colore rosso resta visibile nel pannello e non provoca cambi finestra automatici.' 20 458 850 40))

    $script:lblDiagnostic = New-Label '' 20 20 880 165 10
    $healthTab.Controls.Add($lblDiagnostic)
    $script:eventBox = New-Object System.Windows.Forms.ListBox
    $eventBox.Location = New-Object Drawing.Point(20, 195)
    $eventBox.Size = New-Object Drawing.Size(894, 260)
    $eventBox.BackColor = $ColorCardAlt; $eventBox.ForeColor = $ColorText
    $eventBox.HorizontalScrollbar = $true
    $healthTab.Controls.Add($eventBox)
    $exportButton = New-LocalButton $healthTab 'Esporta diagnostica' 20 475 190
    $exportButton.Add_Click({ Export-LocalDiagnostics })
    $retryButton = New-LocalButton $healthTab 'Riprova lettura Teams' 230 475 190
    $retryButton.Add_Click({
        if ($null -ne $script:PresenceTask -and -not $script:PresenceTask.IsCompleted) {
            $lblLocalFeedback.Text = 'Provider Windows ancora occupato. Nessun worker duplicato; se persiste, riavvia Teams e il tool.'
        } else { $script:NextPresenceProbeAt = Get-Date; $script:ContactScanDue = Get-Date; $lblLocalFeedback.Text = 'Nuova lettura richiesta.' }
    })
    $resumeButton = New-LocalButton $healthTab 'Riattiva alert contatti' 440 475 190
    $resumeButton.Add_Click({ $script:SnoozeUntil = $null })
    $saveButton = New-LocalButton $LocalForm 'SALVA REGOLE' 16 602 170
    $saveButton.Add_Click({ Save-LocalOptions })
    $script:lblLocalFeedback = New-Label 'Dati locali. I nomi sono salvati solo nella configurazione; gli stati restano in memoria.' 205 600 750 38 9
    $LocalForm.Controls.Add($lblLocalFeedback)
    $LocalForm.Add_FormClosing({
        param($eventSource, $closingEvent)
        $null = $eventSource
        if (-not $script:AllowExit -and $closingEvent.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) { $closingEvent.Cancel = $true; $LocalForm.Hide() }
    })

    $advancedButton = New-LocalButton $Form 'CONTATTI E REGOLE' 650 24 163
    $advancedButton.Add_Click({ $LocalForm.Show($Form); $LocalForm.Activate() })
    $localMenu = $trayMenu.Items.Add('Contatti e regole locali')
    $localMenu.Add_Click({ Show-ControlPanel; $LocalForm.Show($Form); $LocalForm.Activate() })
}
