$script:TeamsJitterHandle = [IntPtr]::Zero
$script:AutoFocusSuppressed = $false
$script:AutoFocusRequest = $null
$script:AutoFocusLastAttempt = $null
$script:AutoFocusAwayFirstRead = $null
$script:AutoFocusPresenceReadAt = $null
$script:ManualFocusPending = $false
$script:FocusActionStatus = 'Nessun autofocus richiesto'
$script:SoundPlayer = $null
$script:SoundStream = $null
$script:LastSoundAt = $null
$script:SoundDiagnostic = 'Nessun suono richiesto'
$script:NotificationForm = $null
$script:NotificationTimer = $null
$script:MascotQuickMenu = $null
$script:SoundNames = [ordered]@{ System = 'Sistema Windows'; Alarm = 'Allarme'; Siren = 'Sirena'; Nuclear = 'Allarme nucleare'; Silent = 'Silenzioso' }
$script:TriggerNames = [ordered]@{ Away = 'Quando Teams diventa Assente'; Background = 'Quando Teams resta in background'; Both = 'Assente oppure background' }

function Stop-NotificationSound {
    if ($null -ne $script:SoundPlayer) { $script:SoundPlayer.Stop(); $script:SoundPlayer.Dispose(); $script:SoundPlayer = $null }
    if ($null -ne $script:SoundStream) { $script:SoundStream.Dispose(); $script:SoundStream = $null }
}

function Play-NotificationSound {
    param([string]$Profile = $Config['NotificationSound'], [int]$Volume = $Config['NotificationVolumePercent'], [switch]$Preview)
    $now = Get-Date
    if (-not $Preview -and $null -ne $script:LastSoundAt -and ($now - $script:LastSoundAt).TotalSeconds -lt 3) { return }
    try {
        Stop-NotificationSound
        if ($Profile -eq 'Silent') { $script:SoundDiagnostic = 'Silenzioso selezionato'; return }
        if ($Profile -ne 'System' -and $Volume -le 0) { $script:SoundDiagnostic = 'Volume effetti a zero'; return }
        $script:SoundDiagnostic = "Riproduzione richiesta: $Profile alle $($now.ToString('HH:mm:ss')) (uscita audio non verificabile)"
        $script:LastSoundAt = $now
        if ($Profile -eq 'System') { [System.Media.SystemSounds]::Exclamation.Play(); return }
        $bytes = [NotificationAudio]::CreateWave($Profile, $Volume)
        $script:SoundStream = New-Object IO.MemoryStream -ArgumentList (,$bytes)
        $script:SoundPlayer = New-Object System.Media.SoundPlayer -ArgumentList $script:SoundStream
        $script:SoundPlayer.Load()
        $script:SoundPlayer.Play()
    } catch {
        $script:SoundDiagnostic = 'Riproduzione fallita: ' + $_.Exception.GetBaseException().GetType().Name
        Write-LocalError 'SOUND' $script:SoundDiagnostic
    } finally {
        if ($Preview -and $null -ne $lblLocalFeedback) { $lblLocalFeedback.Text = $script:SoundDiagnostic }
    }
}

function Show-LocalNotification {
    param([string]$Title, [string]$Message, [switch]$Silent,
        [string]$Profile = $Config['NotificationSound'], [int]$Volume = $Config['NotificationVolumePercent'], [switch]$Preview)
    # App-owned popup avoids a second Windows balloon sound over the selected effect.
    try {
        $notificationTitle.Text = $Title
        $notificationBody.Text = $Message
        $area = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
        $y = $area.Bottom - $NotificationForm.Height - 16
        if ($MascotForm.Visible) { $y = [Math]::Min($y, $MascotForm.Top - $NotificationForm.Height - 8) }
        $NotificationForm.Location = New-Object Drawing.Point(($area.Right - $NotificationForm.Width - 16), ([Math]::Max($area.Top, $y)))
        $NotificationForm.Show()
        $NotificationTimer.Stop(); $NotificationTimer.Start()
    } catch {
        Write-LocalError 'NOTIFICATION' $_.Exception.GetType().Name
        try {
            if ($null -ne $Notify) { $Notify.ShowBalloonTip(6500, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::None) }
        } catch { Write-LocalError 'NOTIFICATION_FALLBACK' $_.Exception.GetType().Name }
    }
    # A visual failure must not suppress sound (or the other way round).
    if (-not $Silent) { Play-NotificationSound -Profile $Profile -Volume $Volume -Preview:$Preview }
}

function Request-TeamsAutoFocus {
    param([string]$Reason)
    if ([bool]$Config['AutoFocusEnabled'] -and -not $script:AutoFocusSuppressed) {
        if ($Config['AutoFocusTrigger'] -ne 'Both' -and $Config['AutoFocusTrigger'] -ne $Reason) { return }
        $script:AutoFocusRequest = @{ Reason = $Reason; At = (Get-Date) }
    }
}

function Observe-AutoFocusPresence {
    param([string]$State)
    $now = Get-Date
    if ($null -ne $script:AutoFocusPresenceReadAt -and ($now - $script:AutoFocusPresenceReadAt).TotalSeconds -gt 20) { $script:AutoFocusAwayFirstRead = $null }
    $script:AutoFocusPresenceReadAt = $now
    if ($State -ne 'Away') {
        $script:AutoFocusAwayFirstRead = $null
        $script:AutoFocusRequest = $null
        return
    }
    if ($null -eq $script:AutoFocusAwayFirstRead) { $script:AutoFocusAwayFirstRead = Get-Date; return }
    if (((Get-Date) - $script:AutoFocusAwayFirstRead).TotalSeconds -ge 3) { Request-TeamsAutoFocus 'Away' }
}

function Request-ManualTeamsFocus {
    $script:ManualFocusPending = $true
    $lblLocalFeedback.Text = 'Autofocus rapido richiesto: esecuzione alla chiusura del menu.'
}

function Get-TeamsClientArea {
    param([IntPtr]$Handle)
    $native = [Win32Window]::ClientBounds($Handle)
    if ($native.Right -le $native.Left -or $native.Bottom -le $native.Top) { return $null }
    $rect = New-Object Drawing.Rectangle($native.Left, $native.Top, ($native.Right - $native.Left), ($native.Bottom - $native.Top))
    $rect = [Drawing.Rectangle]::Intersect($rect, [System.Windows.Forms.SystemInformation]::VirtualScreen)
    if ($rect.Width -lt 8 -or $rect.Height -lt 8) { return $null }
    return $rect
}

function Invoke-ScopedJitter {
    if ($script:TeamsJitterHandle -eq [IntPtr]::Zero) {
        Invoke-Jitter -Mode ([string]$Config['Mode']) -MaximumPixels ([int]$Config['MaxJitterPixels'])
        return $true
    }
    if (-not [Win32Window]::IsForeground($script:TeamsJitterHandle)) { return $false }
    $area = Get-TeamsClientArea $script:TeamsJitterHandle
    $start = Get-CursorPoint
    if ($null -eq $area -or -not $area.Contains($start)) { return $false }
    $delta = Get-RandomJitter ([int]$Config['MaxJitterPixels'])
    $point = New-Object Drawing.Point(($start.X + $delta[0]), ($start.Y + $delta[1]))
    $point = Clamp-ToBounds $point $area
    Set-CursorPoint $point
    if ($Config['Mode'] -eq 'stealth') { Start-Sleep -Milliseconds 15; Set-CursorPoint $start }
    return $true
}

function Invoke-TeamsFocusAction {
    param([switch]$Automatic)
    if ($Automatic) { $script:AutoFocusLastAttempt = Get-Date }
    $pause = Get-EnginePauseReason
    if ($pause) { $script:FocusActionStatus = 'Autofocus sospeso: ' + $pause; return }
    $script:AutoFocusLastAttempt = Get-Date
    try {
        $window = Get-TeamsWindow
        if ($null -eq $window) { $script:FocusActionStatus = 'Nessuna finestra Teams trovata'; return }
        if (-not [Win32Window]::FocusWindow($window.Handle) -or -not [Win32Window]::IsForeground($window.Handle)) {
            $script:FocusActionStatus = 'Windows non ha concesso il focus a Teams'
            return
        }
        $script:AutoFocusSuppressed = $false
        if ([bool]$Config['AutoFocusMovePointer']) {
            $area = Get-TeamsClientArea $window.Handle
            if ($null -eq $area) { $script:FocusActionStatus = 'Finestra Teams senza area client utilizzabile'; return }
            Set-CursorPoint (New-Object Drawing.Point(($area.Left + [int]($area.Width / 2)), ($area.Top + [int]($area.Height / 2))))
        }
        $script:FocusActionStatus = 'Focus Teams confermato'
        if ([bool]$Config['AutoFocusStartJitter']) {
            $script:TeamsJitterHandle = $window.Handle
            if (-not $script:IsRunning) { Start-Engine -UseSavedConfig }
            if (Invoke-ScopedJitter) {
                $script:LastJitterAt = Get-Date
                $script:JitterCount++
                $script:NextJitterAt = $null
                $script:FocusActionStatus += ' | jitter avviato nella finestra'
            } else { $script:FocusActionStatus += ' | jitter in attesa del mouse nella finestra' }
        }
        $script:TeamsFocusState = 'Focused'
        Add-LocalEvent 'Autofocus' $script:FocusActionStatus
    } catch { Write-LocalError 'AUTOFOCUS' $_.Exception.GetType().Name; $script:FocusActionStatus = 'Errore durante autofocus Teams' }
    finally { $lblLocalFeedback.Text = $script:FocusActionStatus }
}

function Update-InteractionState {
    if ($script:ManualFocusPending) {
        $script:ManualFocusPending = $false
        Invoke-TeamsFocusAction
    } else {
        $reason = $null
        if ($null -ne $script:AutoFocusRequest -and $script:CommittedPresence -eq 'Away' -and
            ((Get-Date) - $script:AutoFocusRequest.At).TotalSeconds -le 30) { $reason = 'Away' }
        if ($null -eq $reason -and $script:TeamsFocusState -eq 'Background') { $reason = 'Background' }
        if ($reason -and (Test-AutoFocusDue -Config $Config -Reason $reason -IdleSeconds (Get-IdleSeconds) -Now (Get-Date) `
            -LastAttempt $script:AutoFocusLastAttempt -Suppressed $script:AutoFocusSuppressed -Paused ([bool](Get-EnginePauseReason)))) {
            $script:AutoFocusRequest = $null
            Invoke-TeamsFocusAction -Automatic
        }
    }
    if ($null -ne $MascotQuickMenu -and $MascotQuickMenu.Visible) { Update-MascotQuickMenu }
}

function Update-MascotAppearance {
    param([int]$Scale, [int]$Opacity)
    $layout = Get-MascotLayout $Scale
    $MascotForm.ClientSize = New-Object Drawing.Size($layout.Width, $layout.Height)
    $mascotPicture.Location = New-Object Drawing.Point($layout.Margin, $layout.Margin)
    $mascotPicture.Size = New-Object Drawing.Size($layout.PictureWidth, $layout.PictureHeight)
    $lblMascot.Location = New-Object Drawing.Point($layout.Margin, $layout.StatusY)
    $lblMascot.Size = New-Object Drawing.Size($layout.StatusWidth, $layout.StatusHeight)
    $oldFont = $lblMascot.Font
    $lblMascot.Font = New-Object Drawing.Font('Segoe UI', $layout.FontSize, ([Drawing.FontStyle]::Bold))
    if ($null -ne $oldFont) { $oldFont.Dispose() }
    $mascotArrow.Location = New-Object Drawing.Point(($layout.Margin + $layout.StatusWidth), $layout.StatusY)
    $mascotArrow.Size = New-Object Drawing.Size($layout.ArrowWidth, $layout.StatusHeight)
    $MascotForm.Opacity = [Math]::Max(25, [Math]::Min(100, $Opacity)) / 100.0
    if ($MascotForm.Visible) {
        $area = [System.Windows.Forms.Screen]::FromControl($MascotForm).WorkingArea
        $MascotForm.Left = [Math]::Max($area.Left, [Math]::Min($MascotForm.Left, $area.Right - $MascotForm.Width))
        $MascotForm.Top = [Math]::Max($area.Top, [Math]::Min($MascotForm.Top, $area.Bottom - $MascotForm.Height))
    }
}

function Update-MascotQuickMenu {
    $now = Get-Date
    $entries = @(Get-QuickContacts -People $Config['Colleagues'] -Runtime $script:ContactRuntime -Now $now `
        -MonitorEnabled ([bool]$Config['MonitorColleagues']) -WindowAvailable ($null -ne $script:TeamsWindow -and [Win32Window]::IsDesktopUnlocked()) `
        -StaleSeconds ([Math]::Max(45, 3 * [int]$Config['ColleagueScanSeconds'])))
    for ($index = 0; $index -lt 3; $index++) {
        $item = $script:QuickContactItems[$index]
        $item.Visible = $index -lt $entries.Count
        if ($index -lt $entries.Count) {
            $entry = $entries[$index]
            $item.Text = '{0} : {1}' -f $entry.Name.Replace('&', '&&'), (Get-PresenceDisplayName $entry.State)
            $item.ForeColor = if ($entry.State -eq 'Available') { $ColorGreen } elseif ($entry.State -in @('Busy', 'Dnd')) { $ColorRed } else { $ColorText }
            $item.ToolTipText = 'Ultima lettura: ' + (Get-TimeText $entry.LastSeen)
        }
    }
    $quickEmpty.Visible = $entries.Count -eq 0
    $quickHeading.Text = if ([bool]$Config['MonitorColleagues']) { 'Primi 3 contatti attivi' } else { 'Contatti: monitor disattivato' }
}

function Show-MascotQuickMenu {
    Update-MascotQuickMenu
    $area = [System.Windows.Forms.Screen]::FromControl($MascotForm).WorkingArea
    $menuSize = $MascotQuickMenu.GetPreferredSize([Drawing.Size]::Empty)
    # Leave room for the dropdown even when the widget starts at the screen bottom.
    if ($MascotForm.Bottom + $menuSize.Height -gt $area.Bottom) {
        $MascotForm.Top = [Math]::Max($area.Top, $area.Bottom - $MascotForm.Height - $menuSize.Height - 4)
    }
    $MascotQuickMenu.Show($MascotForm, (New-Object Drawing.Point(0, $MascotForm.Height)))
}

function Close-InteractionResources {
    Stop-NotificationSound
    if ($null -ne $NotificationTimer) { $NotificationTimer.Stop(); $NotificationTimer.Dispose() }
    if ($null -ne $NotificationForm) { $NotificationForm.Dispose() }
    if ($null -ne $MascotQuickMenu) { $MascotQuickMenu.Dispose() }
}

function Initialize-InteractionUI {
    param([System.Windows.Forms.TabControl]$Tabs)
    $focusTab = New-Object System.Windows.Forms.TabPage
    $focusTab.Text = 'Autofocus'
    $widgetTab = New-Object System.Windows.Forms.TabPage
    $widgetTab.Text = 'Widget e suoni'
    foreach ($tab in @($focusTab, $widgetTab)) { $tab.BackColor = $ColorCard; $tab.ForeColor = $ColorText; $Tabs.TabPages.Add($tab) }
    $script:chkAutoFocus = New-DarkCheckBox 'Abilita autofocus automatico di Teams' 20 ([bool]$Config['AutoFocusEnabled'])
    $chkAutoFocus.Width = 620
    $focusTab.Controls.Add($chkAutoFocus)
    $focusTab.Controls.Add((New-Label 'Quando intervenire' 20 70 200 24))
    $script:cmbAutoFocusTrigger = New-Object System.Windows.Forms.ComboBox
    $cmbAutoFocusTrigger.DropDownStyle = 'DropDownList'
    $cmbAutoFocusTrigger.Items.AddRange([object[]]@($script:TriggerNames.Values))
    $cmbAutoFocusTrigger.SelectedItem = $script:TriggerNames[$Config['AutoFocusTrigger']]
    $cmbAutoFocusTrigger.Location = New-Object Drawing.Point(250, 68); $cmbAutoFocusTrigger.Width = 470
    $focusTab.Controls.Add($cmbAutoFocusTrigger)
    $focusTab.Controls.Add((New-Label 'Attendi inattivita input (s)' 20 115 220 24))
    $script:nudAutoFocusIdle = New-Object System.Windows.Forms.NumericUpDown
    $nudAutoFocusIdle.Minimum = 1; $nudAutoFocusIdle.Maximum = 120; $nudAutoFocusIdle.Value = $Config['AutoFocusIdleSeconds']
    $nudAutoFocusIdle.Location = New-Object Drawing.Point(250, 112); $focusTab.Controls.Add($nudAutoFocusIdle)
    $focusTab.Controls.Add((New-Label 'Pausa tra interventi (s)' 20 158 220 24))
    $script:nudAutoFocusCooldown = New-Object System.Windows.Forms.NumericUpDown
    $nudAutoFocusCooldown.Minimum = 15; $nudAutoFocusCooldown.Maximum = 3600; $nudAutoFocusCooldown.Value = $Config['AutoFocusCooldownSeconds']
    $nudAutoFocusCooldown.Location = New-Object Drawing.Point(250, 155); $focusTab.Controls.Add($nudAutoFocusCooldown)
    $script:chkAutoFocusMouse = New-DarkCheckBox 'Sposta il puntatore al centro della finestra Teams' 210 ([bool]$Config['AutoFocusMovePointer'])
    $script:chkAutoFocusJitter = New-DarkCheckBox 'Avvia auto-jitter su Teams anche se il motore e fermo' 252 ([bool]$Config['AutoFocusStartJitter'])
    $chkAutoFocusMouse.Width = 700; $chkAutoFocusJitter.Width = 700
    $focusTab.Controls.AddRange(@($chkAutoFocusMouse, $chkAutoFocusJitter))
    $focusTab.Controls.Add((New-Label 'Il jitter resta nella finestra Teams e attende se sposti il focus o il mouse fuori. Dopo il primo intervento rispetta soglia e range salvati.' 20 306 880 50))
    $focusTab.Controls.Add((New-Label 'Stop sospende anche l autofocus automatico fino ad Avvia o a un autofocus rapido. Fasce orarie e blocco Windows restano rispettati.' 20 366 880 50))
    $quickButton = New-LocalButton $focusTab 'Autofocus rapido' 20 440 210
    $quickButton.Add_Click({ Request-ManualTeamsFocus })
    $focusTab.Controls.Add((New-Label 'Il comando rapido usa le azioni salvate e non attende inattivita. Windows puo negare il cambio di focus.' 20 486 880 40))

    $widgetTab.Controls.Add((New-Label 'Dimensione mostriciattolo (%)' 20 25 260 24))
    $script:nudMascotScale = New-Object System.Windows.Forms.NumericUpDown
    $nudMascotScale.Minimum = 60; $nudMascotScale.Maximum = 200; $nudMascotScale.Increment = 10; $nudMascotScale.Value = $Config['MascotScalePercent']
    $nudMascotScale.Location = New-Object Drawing.Point(300, 22); $widgetTab.Controls.Add($nudMascotScale)
    $widgetTab.Controls.Add((New-Label 'Opacita mostriciattolo (%)' 20 70 260 24))
    $script:nudMascotOpacity = New-Object System.Windows.Forms.NumericUpDown
    $nudMascotOpacity.Minimum = 25; $nudMascotOpacity.Maximum = 100; $nudMascotOpacity.Value = $Config['MascotOpacityPercent']
    $nudMascotOpacity.Location = New-Object Drawing.Point(300, 67); $widgetTab.Controls.Add($nudMascotOpacity)
    $widgetTab.Controls.Add((New-Label 'Le dimensioni e l opacita cambiano in anteprima. Premi SALVA REGOLE per mantenerle al prossimo avvio.' 20 112 880 40))
    $widgetTab.Controls.Add((New-Label 'Suono degli avvisi' 20 180 240 24))
    $script:cmbNotificationSound = New-Object System.Windows.Forms.ComboBox
    $cmbNotificationSound.DropDownStyle = 'DropDownList'
    $cmbNotificationSound.Items.AddRange([object[]]@($script:SoundNames.Values))
    $cmbNotificationSound.SelectedItem = $script:SoundNames[$Config['NotificationSound']]
    $cmbNotificationSound.Location = New-Object Drawing.Point(300, 177); $cmbNotificationSound.Width = 250
    $widgetTab.Controls.Add($cmbNotificationSound)
    $widgetTab.Controls.Add((New-Label 'Volume effetti (%)' 20 226 240 24))
    $script:nudNotificationVolume = New-Object System.Windows.Forms.NumericUpDown
    $nudNotificationVolume.Minimum = 0; $nudNotificationVolume.Maximum = 100; $nudNotificationVolume.Value = $Config['NotificationVolumePercent']
    $nudNotificationVolume.Location = New-Object Drawing.Point(300, 223); $widgetTab.Controls.Add($nudNotificationVolume)
    $previewButton = New-LocalButton $widgetTab 'Ascolta anteprima' 20 280 210
    $previewButton.Add_Click({
        $profile = @($script:SoundNames.Keys | Where-Object { $script:SoundNames[$_] -eq [string]$cmbNotificationSound.SelectedItem })[0]
        Play-NotificationSound -Profile $profile -Volume ([int]$nudNotificationVolume.Value) -Preview
    })
    $stopSoundButton = New-LocalButton $widgetTab 'Ferma suono' 245 280 150
    $stopSoundButton.Add_Click({ Stop-NotificationSound })
    $testAlertButton = New-LocalButton $widgetTab 'Prova popup + suono' 410 280 230
    $testAlertButton.Add_Click({
        $profile = @($script:SoundNames.Keys | Where-Object { $script:SoundNames[$_] -eq [string]$cmbNotificationSound.SelectedItem })[0]
        Show-LocalNotification -Title 'Test notifiche KeepTeamsGreen' -Message 'Test manuale indipendente da Teams. Verifica popup e audio; non cambia gli stati.' -Profile $profile -Volume ([int]$nudNotificationVolume.Value) -Preview
    })
    $widgetTab.Controls.Add((New-Label 'Il volume regola gli effetti sintetizzati; Sistema Windows usa il volume di sistema. Silenzioso mantiene gli avvisi visivi.' 20 332 880 45))
    $widgetTab.Controls.Add((New-Label 'La freccia accanto allo stato apre il menu con autofocus rapido e i primi tre contatti salvati attivi nella fascia corrente.' 20 396 880 45))

    $script:mascotArrow = New-Object System.Windows.Forms.Button
    $mascotArrow.Text = [string][char]0x25BE
    Set-ButtonStyle $mascotArrow $ColorGreenDark $ColorText
    $MascotForm.Controls.Add($mascotArrow)
    $script:MascotQuickMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $MascotQuickMenu.BackColor = $ColorCardAlt; $MascotQuickMenu.ForeColor = $ColorText; $MascotQuickMenu.ShowItemToolTips = $true
    $quickFocus = $MascotQuickMenu.Items.Add('Autofocus rapido')
    $quickFocus.Add_Click({ Request-ManualTeamsFocus })
    $MascotQuickMenu.Items.Add('-') | Out-Null
    $script:quickHeading = $MascotQuickMenu.Items.Add('Primi 3 contatti attivi'); $quickHeading.Enabled = $false
    $script:QuickContactItems = @()
    for ($index = 0; $index -lt 3; $index++) { $script:QuickContactItems += $MascotQuickMenu.Items.Add('In attesa') }
    $script:quickEmpty = $MascotQuickMenu.Items.Add('Nessuna regola attiva in questa fascia'); $quickEmpty.Enabled = $false
    $mascotArrow.Add_Click({ Show-MascotQuickMenu })
    $nudMascotScale.Add_ValueChanged({ Update-MascotAppearance ([int]$nudMascotScale.Value) ([int]$nudMascotOpacity.Value) })
    $nudMascotOpacity.Add_ValueChanged({ Update-MascotAppearance ([int]$nudMascotScale.Value) ([int]$nudMascotOpacity.Value) })
    Update-MascotAppearance $Config['MascotScalePercent'] $Config['MascotOpacityPercent']

    $script:NotificationForm = New-Object PassiveOverlayForm
    $NotificationForm.FormBorderStyle = 'None'; $NotificationForm.ShowInTaskbar = $false; $NotificationForm.TopMost = $true
    $NotificationForm.StartPosition = 'Manual'; $NotificationForm.BackColor = $ColorCardAlt
    $NotificationForm.ClientSize = New-Object Drawing.Size(370, 110)
    $script:notificationTitle = New-Label '' 14 10 342 26 10 ([Drawing.FontStyle]::Bold) $ColorGreen
    $script:notificationBody = New-Label '' 14 40 342 64 9
    $NotificationForm.Controls.AddRange(@($notificationTitle, $notificationBody))
    $script:NotificationTimer = New-Object System.Windows.Forms.Timer
    $NotificationTimer.Interval = 6500
    $NotificationTimer.Add_Tick({ $NotificationTimer.Stop(); $NotificationForm.Hide() })
}
