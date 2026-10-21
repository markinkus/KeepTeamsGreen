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
Assert-Equal ($presenceRules::OwnAccount('Account manager', 'me-control', $false)) $false 'Header boundary'

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
            Assert-Equal $Config['SchemaVersion'] 5 'Schema migration'
            Assert-Equal $Config['JitterIntervalSecondsMin'] $Scenario.Min 'Min preserved'
            Assert-Equal $Config['JitterIntervalSecondsMax'] $Scenario.Max 'Max preserved'
            $Config['Colleagues'] = @([pscustomobject]@{ Name = 'Test Person'; Rule = 'Change'; Days = 'Weekdays'; From = '22:00'; To = '02:00'; Enabled = $true })
            Assert-Equal (Save-Config) $true 'Nested rule save'
            $Config['Colleagues'] = @()
            Load-Config
            Assert-Equal @($Config['Colleagues']).Count 1 'Nested rule reload'
            Assert-Equal $Config['Colleagues'][0].From '22:00' 'Schedule preserved'
            Assert-Equal (Test-Path -LiteralPath $ConfigBackupPath) $true 'Backup exists'
        } finally { [IO.Directory]::Delete($AppDataDir, $true) }
    } $configCode $scenario
}

Write-Output "PASS: $script:checks checks (presence matching, debounce, freshness, schedules, migrations, storage)."
