#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:checks = 0
function Check { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message }; $script:checks++ }

# Compile actual traversal with a deterministic UIA provider, without WinForms.
$suffix = [guid]::NewGuid().ToString('N')
$fixtureNamespace = 'KtgPresenceFixture' + $suffix
$probeNamespace = 'KtgPresenceProbe' + $suffix
$fixture = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PresenceFixture.cs')).Replace('KtgPresenceFixture', $fixtureNamespace)
$reader = [IO.File]::ReadAllText((Join-Path $root 'local/PresenceReader.cs')).Replace('KeepTeamsGreenMonitoring', $probeNamespace).Replace('System.Windows.Automation', $fixtureNamespace).Replace('System.Windows.Rect', "$fixtureNamespace.Rect")
$text = [IO.File]::ReadAllText((Join-Path $root 'local/PresenceText.cs'))
$types = @(Add-Type -TypeDefinition ($fixture + "`nnamespace $probeNamespace {`n$text`n}`n" + $reader) -PassThru)
$elementType = $types | Where-Object FullName -EQ "$fixtureNamespace.AutomationElement"
$controlType = $types | Where-Object FullName -EQ "$fixtureNamespace.ControlType"
$probeType = $types | Where-Object FullName -EQ "$probeNamespace.TeamsPresenceProbe"
function Node { param([string]$Name, [string]$Id = ''); return New-Object $elementType.FullName -ArgumentList @($Name, $Id) }
function Window { param([int]$Handle); $node = Node 'Teams'; $node.Cached.BoundingRectangle = New-Object "$fixtureNamespace.Rect"; $elementType::Windows[[IntPtr]$Handle] = $node; return $node }
function Own { param([int]$Handle); return $probeType::BeginInspect([IntPtr]$Handle, [string[]]@()).Result }
function Contacts { param([int]$Handle); return $probeType::BeginInspectContacts([IntPtr]$Handle, [string[]]@('Mario Rossi')).Result }

$window = Window 41
$broken = Node 'Unrelated chat subtree'; $broken.Unavailable = $true
$account = Node 'Gestione account, Disponibile' 'me-control'
$window.Add($broken); $window.Add($account)
Check ((Own 41).State -eq 'Available') 'A broken chat branch must not discard a valid own-account reading'
$refreshes = $window.Refreshes
$account.Cached.Name = 'Gestione account, Assente'
Check ((Own 41).State -eq 'Away') 'Cache refresh must read a changed state, not reuse old green'
Check ($window.Refreshes -eq $refreshes) 'Cached own account must avoid another full-tree scan'
$account.Unavailable = $true
$replacement = Node 'Account manager, Busy' 'me-control'
$window.Add($replacement)
Check ((Own 41).State -eq 'Busy') 'Replaced account element must be reacquired'
$window = Window 42
$avatar = Node 'Mario Rossi, Available' 'avatar-presence'
$window.Add($avatar)
Check ((Own 42).State -eq 'Unknown') 'A colleague avatar is never the personal state'
Check ((Contacts 42).Contacts[0].State -eq 'Available') 'Read explicit list/row presence without opening a profile'
$avatar.Cached.Name = 'Mario Rossi'
$wrapper = Node 'Avatar wrapper'
$badge = Node 'Occupato' 'presence-indicator'; $badge.Cached.ControlType = $controlType::Image
$wrapper.Add($badge); $avatar.Add($wrapper)
Check ((Contacts 42).Contacts[0].State -eq 'Busy') 'Read a nested accessible avatar badge'
$window.Add((Node 'Mario Rossi, Available'))
Check ((Contacts 42).Contacts[0].State -eq 'Unknown') 'Conflicting matching identities must not trigger alerts'
$window = Window 43
$body = Node 'Message container' 'message-body'; $body.Add((Node 'Mario Rossi, Available')); $window.Add($body)
Check ((Contacts 43).Contacts[0].State -eq 'Unknown') 'Message contents are never presence evidence'
$window = Window 44
$window.Add((Node 'Mario Rossi, Available')); $broken = Node 'Unavailable branch'; $broken.Unavailable = $true; $window.Add($broken)
Check ((Contacts 44).Contacts[0].State -eq 'Unknown') 'Partial contact scans remain conservative about ambiguity'

# Run real personal state machine with a controlled clock and captured alerts.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'script.gui.ps1'), [ref]$tokens, [ref]$errors)
foreach ($name in @('Commit-Presence', 'Update-MascotStatus')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:clock = [datetime]'2026-10-22T10:00:00'
function Get-Date { return $script:clock }
function Set-Timeline { param($Text) }
function Write-AppLog { param($Text) }
function Get-PresenceDisplayName { param($State); return $State }
function Show-PresenceDropAlert { param($NewState); $script:alerts += $NewState }
function Request-TeamsAutoFocus { param($Reason) }
function Invoke-AwayRecovery { }
function Get-EnginePauseReason { }
function Reset-Observation {
    $script:CommittedPresence = 'Unknown'; $script:PendingPresence = $null; $script:PendingPresenceSince = $null
    $script:LastReliablePresence = $null; $script:LastReliablePresenceAt = $null; $script:alerts = @()
}
$Config = @{ AlertOnPresenceDrop = $true; AutoFocusEnabled = $false }
Reset-Observation
Commit-Presence 'Available'
Check ($script:CommittedPresence -eq 'Available') 'Expose the first reliable green immediately'
$script:clock = $script:clock.AddSeconds(2); Commit-Presence 'Unknown'
Check ($script:CommittedPresence -eq 'Unknown' -and $script:alerts.Count -eq 0) 'Missing data is visible and never a drop alert'
$script:clock = $script:clock.AddSeconds(2); Commit-Presence 'Away'
Check ($script:alerts.Count -eq 0) 'A drop after a short gap still needs confirmation'
$script:clock = $script:clock.AddSeconds(2); Commit-Presence 'Away'
Check ($script:CommittedPresence -eq 'Away' -and $script:alerts.Count -eq 1) 'A confirmed drop must alert across a short Unknown gap'
$script:clock = $script:clock.AddSeconds(2); Commit-Presence 'Away'
Check ($script:alerts.Count -eq 1) 'A stable non-green state must not repeat alerts'
Commit-Presence 'Available'; $script:clock = $script:clock.AddSeconds(2); Commit-Presence 'Busy'
Commit-Presence 'Available'; $script:clock = $script:clock.AddSeconds(3); Commit-Presence 'Busy'
Check ($script:alerts.Count -eq 1) 'A transient drop interrupted by green must not alert'
$script:clock = $script:clock.AddSeconds(2); Commit-Presence 'Busy'
Check ($script:alerts.Count -eq 2) 'A new confirmed drop must alert again'
Reset-Observation; Commit-Presence 'Available'; Commit-Presence 'Unknown'
$script:clock = $script:clock.AddSeconds(30); Commit-Presence 'Away'
Check ($script:alerts.Count -eq 0 -and $script:CommittedPresence -eq 'Away') 'A stale gap becomes a new baseline, not a fabricated transition'
Reset-Observation; Commit-Presence 'Available'; Commit-Presence 'Disabled'; Commit-Presence 'Busy'
Check ($script:alerts.Count -eq 0) 'Disabling monitoring resets the reference state'
Reset-Observation; Commit-Presence 'Available'; Commit-Presence 'Closed'
$script:clock = $script:clock.AddSeconds(3); Commit-Presence 'Closed'
Check ($script:alerts.Count -eq 0) 'Window closure requires five seconds'
$script:clock = $script:clock.AddSeconds(2); Commit-Presence 'Closed'
Check ($script:alerts.Count -eq 1) 'Confirmed closure alerts exactly once'
$script:IsRunning = $true; $script:CommittedPresence = 'Unknown'
$lblMascot = [pscustomobject]@{ Text = ''; ForeColor = '' }; $ColorYellow = 'Yellow'; $ColorGreen = 'Green'
Update-MascotStatus
Check ($lblMascot.Text -eq 'STATO NON LETTO' -and $lblMascot.ForeColor -eq 'Yellow') 'Unknown must not look green in the widget'

# Exercise actual worker orchestration: an unfinished contact probe cannot hold
# up the own-state task, and outdated settings generations are never applied.
foreach ($name in @('Start-PresenceProbe', 'Receive-PresenceProbe', 'Update-ContactProbe')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($node.Extent.Text.Replace('[KeepTeamsGreenMonitoring.TeamsPresenceProbe]', ('[' + $probeType.FullName + ']'))))
}
function Observe-AutoFocusPresence { param($State) }
function Complete-AwayRecovery { param($State) }
function Write-LocalError { param($Code, $Detail) }
function Get-DueContactNames { $script:dueCalls++; return $script:dueNames }
function Receive-ContactReadings { param($Readings); $script:contactResults += @($Readings) }
$window = Window 45; $window.Add((Node 'Account manager, Available' 'me-control'))
$script:TeamsWindow = [pscustomobject]@{ Handle = [IntPtr]45 }
$script:UIAutomationAvailable = $true; $script:LocalGeneration = 5; $script:ProbeFailureCount = 0
$Config.MonitorTeamsPresence = $true; $script:dueCalls = 0; $script:dueNames = @(); $script:contactResults = @()
$pending = New-Object 'System.Threading.Tasks.TaskCompletionSource[object]'
$script:ContactTask = $pending.Task; $script:ContactTaskStartedAt = $script:clock
Reset-Observation
Start-PresenceProbe ([IntPtr]45)
Check ($script:PresenceTask.Wait(2000)) 'Own task must finish without waiting for an unfinished contact worker'
Receive-PresenceProbe
Check ($script:CommittedPresence -eq 'Available' -and -not $script:ContactTask.IsCompleted) 'Contact work must not block personal state commits'
Check ($script:dueCalls -eq 0) 'Personal polling must not consume contact scan deadlines'
$pending.SetResult([pscustomobject]@{ Contacts = @([pscustomobject]@{ Name = 'Mario Rossi'; State = 'Busy' }) })
$script:ContactTaskGeneration = 4; $script:ContactTaskHandle = [IntPtr]45
Update-ContactProbe
Check ($script:contactResults.Count -eq 0 -and $null -eq $script:ContactTask) 'A contact result from old rules must be discarded and drained'
$script:dueNames = @('Mario Rossi')
Update-ContactProbe
Check ($script:ContactTask.Wait(2000)) 'Contact reader has an independent task slot'
$script:dueNames = @()
Update-ContactProbe
Check ($script:contactResults.Count -eq 1 -and $script:contactResults[0].State -eq 'Unknown') 'Contact data is delivered without borrowing the personal state'

# Visual popup failure must not prevent the independent sound request.
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'local/Interactions.ps1'), [ref]$tokens, [ref]$errors)
$node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-LocalNotification' }, $true)
. ([scriptblock]::Create($node.Extent.Text))
$notificationTitle = $null; $Notify = $null; $script:sounds = 0; $script:popupErrors = 0
function Play-NotificationSound { param($Profile, $Volume, [switch]$Preview); $script:sounds++ }
function Write-LocalError { param($Code, $Detail); $script:popupErrors++ }
Show-LocalNotification 'Test' 'Test'
Check ($script:sounds -eq 1 -and $script:popupErrors -eq 1) 'Popup exceptions must not suppress audio'
Show-LocalNotification 'Test' 'Test' -Silent
Check ($script:sounds -eq 1) 'Minimize/startup silent notices stay silent'
Write-Output "PASS: $script:checks presence pipeline checks (actual reader with fake provider, real alert state machine, independent sound dispatch; not a live Teams/audio test)."
