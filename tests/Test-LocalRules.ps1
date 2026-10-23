#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'local/Rules.ps1')
$testNamespace = 'KtgRules' + [guid]::NewGuid().ToString('N')
$presenceRules = Add-Type -TypeDefinition ("namespace $testNamespace {" + [Environment]::NewLine + [IO.File]::ReadAllText((Join-Path $project 'local/PresenceText.cs')) + [Environment]::NewLine + '}') -PassThru | Where-Object Name -EQ 'PresenceText'
$script:checks = 0
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message | actual=$Actual expected=$Expected" }
    $script:checks++
}

# Message text, name prefixes and other users' avatars must never become presence.
Assert-Equal ($presenceRules::NamedState('Mario Rossi, Disponibile', 'Mario Rossi')) 'Available' 'Exact named presence'
Assert-Equal ($presenceRules::NamedState('Mario Rossini, Disponibile', 'Mario Rossi')) 'Unknown' 'Similar name'
Assert-Equal ($presenceRules::NamedState('Mario Rossi: sono disponibile domani', 'Mario Rossi')) 'Unknown' 'Chat text'
Assert-Equal ($presenceRules::State('Unavailable')) 'Unknown' 'Substring state'
Assert-Equal ($presenceRules::State('status Available')) 'Available' 'Teams account status label'
Assert-Equal ($presenceRules::NamedState('Profile picture of Mario Rossi, Busy', 'Mario Rossi')) 'Busy' 'Avatar label'
Assert-Equal ($presenceRules::OwnAccount('Mario Rossi, Available', 'avatar-presence', $true)) $false 'Colleague is not self'
Assert-Equal ($presenceRules::OwnAccount('Account manager, Available', 'me-control', $true)) $true 'Account control'
Assert-Equal ($presenceRules::OwnAccount('Account manager', 'me-control', $false)) $true 'Explicit account ID works with custom DPI/layout'
Assert-Equal ($presenceRules::OwnAccount('Account manager', '', $false)) $false 'Generic label still needs header boundary'
Assert-Equal ($presenceRules::OwnAccount('Mario Rossi, Available', 'personButton', $false)) $false 'Generic person buttons outside account header are not self'
Assert-Equal ($presenceRules::ConversationIdentity('Chat con Mario Rossi, Stato: Disponibile', 'Mario Rossi')) $true 'Chat row identity'
Assert-Equal ($presenceRules::ConversationIdentity("Mario Rossi`nStato: Disponibile", 'Mario Rossi')) $true 'Multiline row identity'
Assert-Equal ($presenceRules::ConversationIdentity('Mario Rossini, Stato: Disponibile', 'Mario Rossi')) $false 'Chat row prefix collision'
Assert-Equal ($presenceRules::ConversationState('Mario Rossi, Stato: Disponibile, Ultimo messaggio ieri', 'Mario Rossi')) 'Available' 'Explicit row status'
Assert-Equal ($presenceRules::ConversationState('Mario Rossi, Disponibile', 'Mario Rossi')) 'Unknown' 'Unlabelled preview field is not presence'

# Windows crossing midnight belong to the day on which they started.
Assert-Equal (Test-LocalWindow ([datetime]'2026-10-23T23:00:00') 'Weekdays' '22:00' '02:00') $true 'Friday night'
Assert-Equal (Test-LocalWindow ([datetime]'2026-10-24T01:00:00') 'Weekdays' '22:00' '02:00') $true 'Saturday from Friday'
Assert-Equal (Test-LocalWindow ([datetime]'2026-10-26T01:00:00') 'Weekdays' '22:00' '02:00') $false 'Monday from Sunday'
Assert-Equal (Test-LocalWindow ([datetime]'2026-10-23T18:00:00') 'Weekdays' '09:00' '18:00') $false 'End exclusive'
Assert-Equal (Test-LocalWindow ([datetime]'2026-10-23T03:00:00') 'Everyday' '00:00' '00:00') $true 'All day'
Assert-Equal (Test-LocalTime '25:00') $false 'Invalid clock'

$now = [datetime]'2026-10-21T10:00:00'
$runtime = New-ContactRuntime
Assert-Equal (Update-ContactObservation $runtime 'Available' $now 'Available' 45 120) $false 'First observation'
Assert-Equal (Update-ContactObservation $runtime 'Available' $now.AddSeconds(15) 'Available' 45 120) $true 'Confirmed available'
Assert-Equal (Update-ContactObservation $runtime 'Available' $now.AddSeconds(30) 'Available' 45 120) $false 'No repeated alert'
Assert-Equal (Update-ContactObservation $runtime 'Unknown' $now.AddSeconds(40) 'Available' 45 120) $false 'Unknown is not offline'
Assert-Equal $runtime.State 'Unknown' 'Missing data expires state'
Assert-Equal (Update-ContactObservation $runtime 'Available' $now.AddSeconds(50) 'Available' 45 120) $false 'Reacquire candidate'
Assert-Equal (Update-ContactObservation $runtime 'Available' $now.AddSeconds(65) 'Available' 45 120) $false 'Cooldown'
$runtime = New-ContactRuntime
Assert-Equal (Update-ContactObservation $runtime 'Busy' $now 'Change' 45 120) $false 'Baseline candidate'
Assert-Equal (Update-ContactObservation $runtime 'Busy' $now.AddSeconds(15) 'Change' 45 120) $false 'Baseline is not change'
Assert-Equal (Update-ContactObservation $runtime 'Available' $now.AddSeconds(30) 'Change' 45 120) $false 'Change debounce'
Assert-Equal (Update-ContactObservation $runtime 'Available' $now.AddSeconds(45) 'Change' 45 120) $true 'Confirmed change'
Assert-Equal (Update-ContactObservation $runtime 'Offline' $now.AddMinutes(5) 'Change' 45 120) $false 'Stale gap candidate'
Assert-Equal (Update-ContactObservation $runtime 'Offline' $now.AddMinutes(5).AddSeconds(15) 'Change' 45 120) $false 'Stale gap is new baseline'
$runtime = New-ContactRuntime
Update-ContactObservation $runtime 'Available' $now 'Change' 45 60 | Out-Null
Update-ContactObservation $runtime 'Available' $now.AddSeconds(5) 'Change' 45 60 | Out-Null
Assert-Equal (Update-ContactObservation $runtime 'BusyOrDnd' $now.AddSeconds(10) 'Change' 45 60) $false 'Red visual reading needs confirmation'
Assert-Equal (Update-ContactObservation $runtime 'BusyOrDnd' $now.AddSeconds(15) 'Change' 45 60) $true 'Confirmed green to red alerts'
Assert-Equal $runtime.State 'BusyOrDnd' 'Keep uncertain red explicit'
Update-ContactObservation $runtime 'Dnd' $now.AddSeconds(20) 'Change' 45 60 | Out-Null
Assert-Equal (Update-ContactObservation $runtime 'Dnd' $now.AddSeconds(85) 'Change' 120 60) $false 'Improved precision from red to Dnd is not a presence change'
Update-ContactObservation $runtime 'BusyOrDnd' $now.AddSeconds(90) 'Change' 120 60 | Out-Null
Assert-Equal (Update-ContactObservation $runtime 'BusyOrDnd' $now.AddSeconds(95) 'Change' 120 60) $false 'Losing red precision does not generate a change alert'

# Run actual config implementation without starting Forms or touching the user's APPDATA.
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'script.gui.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-Equal $parseErrors.Count 0 'Main script syntax'
$source = [IO.File]::ReadAllText((Join-Path $project 'script.gui.ps1'))
$start = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$ConfigDefaults' }, $true)
$end = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-IdleSeconds' }, $true)
$configCode = $source.Substring($start.Extent.StartOffset, $end.Extent.StartOffset - $start.Extent.StartOffset)
foreach ($scenario in @(
    @{ Json = '{}'; Min = 3; Max = 3 },
    @{ Json = '{"SchemaVersion":3,"JitterIntervalSeconds":7}'; Min = 7; Max = 7 },
    @{ Json = '{"SchemaVersion":4,"JitterIntervalSecondsMin":4,"JitterIntervalSecondsMax":9}'; Min = 4; Max = 9 }
)) {
    & {
        param($Code, $Scenario)
        $AppDataDir = Join-Path ([IO.Path]::GetTempPath()) ('ktg-rules-test-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($AppDataDir) | Out-Null
        $ConfigPath = Join-Path $AppDataDir 'config.json'
        $ConfigBackupPath = Join-Path $AppDataDir 'config.backup.json'
        function Write-AppLog { param([string]$Message) }
        try {
            [IO.File]::WriteAllText($ConfigPath, $Scenario.Json)
            . ([scriptblock]::Create($Code))
            Assert-Equal $Config['SchemaVersion'] 6 'Schema migration'
            Assert-Equal $Config['JitterIntervalSecondsMin'] $Scenario.Min 'Min preserved'
            Assert-Equal $Config['JitterIntervalSecondsMax'] $Scenario.Max 'Max preserved'
            $Config['Colleagues'] = @([pscustomobject]@{ Name = 'Test Person'; Rule = 'Change'; Days = 'Weekdays'; From = '22:00'; To = '02:00'; Enabled = $true })
            Assert-Equal (Save-Config) $true 'Nested rule save'
            $Config['Colleagues'] = @()
            Load-Config
            Assert-Equal @($Config['Colleagues']).Count 1 'Nested rule reload'
            Assert-Equal $Config['Colleagues'][0].From '22:00' 'Schedule preserved'
            Assert-Equal (Test-Path -LiteralPath $ConfigBackupPath) $true 'Backup exists'
            Assert-Equal $Config['AutoFocusEnabled'] $false 'Autofocus opt in'
            Assert-Equal $Config['MascotOpacityPercent'] 96 'Default widget opacity'
            Assert-Equal $Config['ColleagueReadVisibleBadges'] $true 'Visible badge fallback default'
            $Config['AutoFocusEnabled'] = $true
            $Config['MascotScalePercent'] = 150
            $Config['NotificationSound'] = 'Nuclear'
            $Config['ColleagueReadVisibleBadges'] = $false
            Assert-Equal (Save-Config) $true 'Interaction settings save'
            $Config['AutoFocusEnabled'] = $false; $Config['MascotScalePercent'] = 100; $Config['NotificationSound'] = 'System'
            Load-Config
            Assert-Equal $Config['AutoFocusEnabled'] $true 'Autofocus reload'
            Assert-Equal $Config['MascotScalePercent'] 150 'Widget reload'
            Assert-Equal $Config['NotificationSound'] 'Nuclear' 'Sound reload'
            Assert-Equal $Config['ColleagueReadVisibleBadges'] $false 'Visual fallback opt-out survives reload'
        } finally { [IO.Directory]::Delete($AppDataDir, $true) }
    } $configCode $scenario
}

$focusConfig = @{ AutoFocusEnabled = $true; AutoFocusTrigger = 'Away'; AutoFocusIdleSeconds = 5; AutoFocusCooldownSeconds = 60 }
Assert-Equal (Test-AutoFocusDue $focusConfig 'Away' 5 $now $null $false $false) $true 'Autofocus allowed'
Assert-Equal (Test-AutoFocusDue $focusConfig 'Background' 5 $now $null $false $false) $false 'Other trigger ignored'
Assert-Equal (Test-AutoFocusDue $focusConfig 'Away' 4 $now $null $false $false) $false 'Typing guard'
Assert-Equal (Test-AutoFocusDue $focusConfig 'Away' 5 $now $now.AddSeconds(-30) $false $false) $false 'Autofocus cooldown'
Assert-Equal (Test-AutoFocusDue $focusConfig 'Away' 5 $now $null $true $false) $false 'Manual stop suppresses autofocus'
Assert-Equal (Test-AutoFocusDue $focusConfig 'Away' 5 $now $null $false $true) $false 'Schedule and desktop gate'
$focusConfig.AutoFocusTrigger = 'Both'
Assert-Equal (Test-AutoFocusDue $focusConfig 'Background' 5 $now $null $false $false) $true 'Combined trigger'

$people = @()
foreach ($name in @('A Person', 'B Person', 'C Person', 'D Person')) {
    $people += [pscustomobject]@{ Name = $name; Enabled = $true; Days = 'Everyday'; From = '00:00'; To = '00:00' }
}
$people[0].Enabled = $false
$runtimeMap = @{ 'B Person' = @{ State = 'Available'; LastSeen = $now.AddSeconds(-10) }; 'C Person' = @{ State = 'Busy'; LastSeen = $now.AddSeconds(-60) } }
$quick = @(Get-QuickContacts $people $runtimeMap $now $true $true 45)
Assert-Equal $quick.Count 3 'Only three active contacts'
Assert-Equal $quick[0].Name 'B Person' 'Saved order and disabled skip'
Assert-Equal $quick[0].State 'Available' 'Fresh contact in widget'
Assert-Equal $quick[1].State 'Unknown' 'Stale contact in widget'
$quick = @(Get-QuickContacts $people $runtimeMap $now $false $true 45)
Assert-Equal $quick[0].State 'Unknown' 'Monitor disabled in widget'
$quick = @(Get-QuickContacts $people $runtimeMap $now $true $false 45)
Assert-Equal $quick[0].State 'Unknown' 'Teams missing in widget'
foreach ($scale in @(60, 100, 200)) {
    $layout = Get-MascotLayout $scale
    Assert-Equal ($layout.Margin + $layout.StatusWidth + $layout.ArrowWidth -le $layout.Width) $true 'Arrow inside widget'
    Assert-Equal ($layout.StatusY + $layout.StatusHeight -le $layout.Height) $true 'Status inside widget'
}

$audioNamespace = 'KtgAudio' + [guid]::NewGuid().ToString('N')
$audio = Add-Type -TypeDefinition ("namespace $audioNamespace {" + [Environment]::NewLine + [IO.File]::ReadAllText((Join-Path $project 'local/NotificationAudio.cs')) + [Environment]::NewLine + '}') -PassThru | Where-Object Name -EQ 'NotificationAudio'
Assert-Equal ($audio::CreateWave('Silent', 60).Length) 0 'Silent sound'
foreach ($profile in @('Alarm', 'Siren', 'Nuclear')) {
    $wave = $audio::CreateWave($profile, 60)
    Assert-Equal ([Text.Encoding]::ASCII.GetString($wave, 0, 4)) 'RIFF' 'WAV header'
    Assert-Equal ([BitConverter]::ToInt32($wave, 4)) ($wave.Length - 8) 'RIFF length'
    Assert-Equal ([BitConverter]::ToInt32($wave, 40)) ($wave.Length - 44) 'PCM data length'
    Assert-Equal ([BitConverter]::ToInt32($wave, 24)) 24000 'Sample rate'
}
$silentWave = $audio::CreateWave('Alarm', 0)
Assert-Equal (@($silentWave[44..($silentWave.Length - 1)] | Where-Object { $_ -ne 0 }).Count) 0 'Zero volume PCM'

Write-Output "PASS: $script:checks checks (presence, schedules, storage, autofocus, widget, synthesized audio)."
