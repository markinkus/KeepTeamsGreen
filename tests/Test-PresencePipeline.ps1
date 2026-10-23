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
$reader = ([IO.File]::ReadAllText((Join-Path $root 'local/PresenceReader.cs')) + "`n" + [IO.File]::ReadAllText((Join-Path $root 'local/ConversationReader.cs'))).Replace('KeepTeamsGreenMonitoring', $probeNamespace).Replace('System.Windows.Automation', $fixtureNamespace).Replace('System.Windows.Rect', "$fixtureNamespace.Rect")
$screen = "$fixtureNamespace.Screen"
$nativeStubs = @{
    SetThreadDpiAwarenessContext = "return $screen.SetDpi(context);"
    WindowFromPhysicalPoint = "return $screen.Owner(point.X, point.Y);"
    GetAncestor = 'return window;'
    IsIconic = "return $screen.Minimized;"
    IsWindowVisible = "return $screen.Visible;"
    GetDC = "$screen.DcGets++; return $screen.DcFails ? System.IntPtr.Zero : new System.IntPtr(99);"
    ReleaseDC = "$screen.DcReleases++; return 1;"
    GetPixel = "return $screen.Pixel(x + $screen.CaptureX, y + $screen.CaptureY);"
    CreateCompatibleDC = 'return new System.IntPtr(100);'
    CreateCompatibleBitmap = 'return new System.IntPtr(101);'
    SelectObject = 'return new System.IntPtr(102);'
    BitBlt = "$screen.CaptureX = sourceX; $screen.CaptureY = sourceY; return !$screen.CopyFails;"
    DeleteObject = "$screen.BitmapDeletes++; return true;"
    DeleteDC = "$screen.MemoryDeletes++; return true;"
}
$reader = [regex]::Replace($reader, '\[DllImport\("[^"]+"\)\]\s+private static extern ([^;]+);', [Text.RegularExpressions.MatchEvaluator]{
    param($match)
    $signature = $match.Groups[1].Value
    $method = [regex]::Match($signature, '(\w+)\(').Groups[1].Value
    if (-not $nativeStubs.ContainsKey($method)) { throw "Missing OS test double: $method" }
    return 'private static ' + $signature + ' { ' + $nativeStubs[$method] + ' }'
})
$text = [IO.File]::ReadAllText((Join-Path $root 'local/PresenceText.cs'))
$types = @(Add-Type -TypeDefinition ($fixture + "`nnamespace $probeNamespace {`n$text`n}`n" + $reader) -PassThru)
$elementType = $types | Where-Object FullName -EQ "$fixtureNamespace.AutomationElement"
$controlType = $types | Where-Object FullName -EQ "$fixtureNamespace.ControlType"
$probeType = $types | Where-Object FullName -EQ "$probeNamespace.TeamsPresenceProbe"
$badgeType = $types | Where-Object FullName -EQ "$probeNamespace.VisiblePresenceBadge"
$conversationType = $types | Where-Object FullName -EQ "$probeNamespace.ConversationPresenceReader"
$screenType = $types | Where-Object FullName -EQ "$fixtureNamespace.Screen"
function Node { param([string]$Name, [string]$Id = ''); return New-Object $elementType.FullName -ArgumentList @($Name, $Id) }
function Bounds { param($Node, [double]$X, [double]$Y, [double]$Width, [double]$Height); $rect = New-Object "$fixtureNamespace.Rect"; $rect.Left = $X; $rect.Top = $Y; $rect.Width = $Width; $rect.Height = $Height; $Node.Cached.BoundingRectangle = $rect }
function Window { param([int]$Handle); $node = Node 'Teams'; Bounds $node 0 0 1400 900; $elementType::Windows[[IntPtr]$Handle] = $node; return $node }
function Column { param($Window); $node = Node 'Chat' 'chat-pane-list'; $node.Cached.ControlType = $controlType::Tree; Bounds $node 80 100 350 740; $Window.Add($node); return $node }
function ChatRow { param($Column, [string]$Name, [int]$Y = 150); $row = Node '' 'chat-list-item'; $row.Cached.ControlType = $controlType::ListItem; Bounds $row 90 $Y 330 40; $Column.Add($row); $label = Node $Name; $label.Cached.ControlType = $controlType::Text; Bounds $label 140 ($Y + 8) 200 24; $row.Add($label); return $row }
function Indicator { param($Row, [string]$State); $badge = Node $State 'presence'; $badge.Cached.ControlType = $controlType::Image; Bounds $badge 118 ($Row.Cached.BoundingRectangle.Top + 24) 8 8; $Row.Add($badge); return $badge }
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
$column = Column $window; $row = ChatRow $column 'Mario Rossi'; $null = Indicator $row 'Available'
Check ((Contacts 42).Contacts[0].State -eq 'Available') 'Read explicit list/row presence without opening a profile'
$row.Children.RemoveAt(1)
$wrapper = Node 'Avatar wrapper'
Bounds $wrapper 100 150 30 32
$badge = Node 'Occupato' 'presence-indicator'; $badge.Cached.ControlType = $controlType::Image
Bounds $badge 118 174 8 8
$wrapper.Add($badge); $row.Add($wrapper)
Check ((Contacts 42).Contacts[0].State -eq 'Busy') 'Read a nested accessible avatar badge'
$duplicate = ChatRow $column 'Mario Rossi' 200; $null = Indicator $duplicate 'Available'
Check ((Contacts 42).Contacts[0].State -eq 'Unknown') 'Conflicting matching identities must not trigger alerts'
$window = Window 43
$body = Node 'Message container' 'message-body'; $body.Add((Node 'Mario Rossi, Available')); $window.Add($body)
Check ((Contacts 43).Contacts[0].State -eq 'Unknown') 'Message contents are never presence evidence'
$window = Window 44
$column = Column $window; $row = ChatRow $column 'Mario Rossi'; $null = Indicator $row 'Available'
$broken = Node 'Unavailable branch'; Bounds $broken 90 200 330 40; $broken.Unavailable = $true; $column.Add($broken)
Check ((Contacts 44).Contacts[0].State -eq 'Unknown') 'Partial contact scans remain conservative about ambiguity'

# Conversation column layouts: name and badge are siblings, not one label.
$window = Window 46; $column = Column $window
$row = ChatRow $column 'Mario Rossi'; $null = Indicator $row 'Disponibile'
$broken = Node 'Huge selected conversation'; $broken.Unavailable = $true; $window.Add($broken)
Check ((Contacts 46).Contacts[0].State -eq 'Available') 'A broken selected conversation on the right cannot invalidate the sidebar'
$row.Children[0].Cached.Name = 'Mario Rossini'
Check ((Contacts 46).Contacts[0].State -eq 'Unknown') 'Similar conversation names are not the saved contact'
$row.Children[0].Cached.Name = 'Mario Rossi'; $row.Cached.IsOffscreen = $true
Check ((Contacts 46).Contacts[0].State -eq 'Unknown') 'Offscreen chat rows cannot supply a fresh visible presence'
$row.Cached.IsOffscreen = $false; $row.Cached.AutomationId = 'group-chat-item'
Check ((Contacts 46).Contacts[0].State -eq 'Unknown') 'Group conversation avatars are not individual contact presence'
$row.Cached.AutomationId = 'chat-list-item'; $row.Children[1].Cached.HelpText = 'Available'; $row.Children[1].Cached.Name = ''
Check ((Contacts 46).Contacts[0].State -eq 'Available') 'Explicit badge HelpText is supported'
$row.Children[1].Cached.HelpText = ''; $row.Children[1].Cached.AutomationId = ''; $row.Children[1].Cached.Name = 'Available'; $row.Children[1].Cached.ControlType = $controlType::Text
Check ((Contacts 46).Contacts[0].State -eq 'Unknown') 'A message preview saying Available is not a badge'
$row.Cached.Name = 'Chat con Mario Rossi, Stato: Non disturbare, Ultima attivita ieri'
Check ((Contacts 46).Contacts[0].State -eq 'Dnd') 'Explicit labelled status on an identified conversation row is supported'
$row.Cached.Name = 'Chat con Mario Rossi, Available'
Check ((Contacts 46).Contacts[0].State -eq 'Unknown') 'Unlabelled preview fields must not become presence'
$row.Cached.Name = ''; $row.Children[1].Cached.ControlType = $controlType::Image; $row.Children[1].Cached.Name = 'Available'
$duplicate = ChatRow $column 'Mario Rossi' 200
Check ((Contacts 46).Contacts[0].State -eq 'Unknown') 'Even an unreadable duplicate row makes identity ambiguous'
$column.Children.Remove($duplicate) | Out-Null
Check (($conversationType::Inspect([IntPtr]46, [string[]]@('Mario Rossi'), $false)).Contacts[0].State -eq 'Available') 'Disabling pixel fallback does not disable UIA row reading'
$null = Indicator $row 'Busy'
Check ((Contacts 46).Contacts[0].State -eq 'Unknown') 'Conflicting badges within one row must not pick the first state'
$window = Window 47; $column = Column $window
$section = Node 'Preferiti'; $section.Cached.ControlType = $controlType::TreeItem; Bounds $section 90 120 330 30; $column.Add($section)
$row = ChatRow $section 'Mario Rossi' 170; $null = Indicator $row 'Available'
Check ((Contacts 47).Contacts[0].State -eq 'Available') 'Favorite/Chat sections that are TreeItems must not hide their child conversation rows'
$selected = Node 'Selected conversation'; Bounds $selected 430 100 970 740; $window.Add($selected)
$null = Contacts 47
Check ($selected.ChildReads -eq 0) 'Use the discovered column boundary, not half-window geometry, to skip the selected conversation'
$row.Cached.AutomationId = ''; $row.Cached.ControlType = $controlType::Group
Check ((Contacts 47).Contacts[0].State -eq 'Available') 'Conversation containers can be groups with a separate name text and badge'
$row.Cached.ControlType = $controlType::Button
Check ((Contacts 47).Contacts[0].State -eq 'Available') 'Conversation rows can be wide buttons without a stable AutomationId'
$window = Window 49; $column = Column $window
$section = Node ''; $section.Cached.ControlType = $controlType::Group; Bounds $section 90 140 330 160; $column.Add($section)
$label = Node 'Mario Rossi'; $label.Cached.ControlType = $controlType::Text; Bounds $label 140 155 200 24; $section.Add($label)
$otherBadge = Node 'Available' 'presence'; $otherBadge.Cached.ControlType = $controlType::Image; Bounds $otherBadge 118 225 8 8; $section.Add($otherBadge)
Check ((Contacts 49).Contacts[0].State -eq 'Unknown') 'A badge on another vertical row must not attach to the saved name'
$anotherLabel = Node 'Mario Rossi'; $anotherLabel.Cached.ControlType = $controlType::Text; Bounds $anotherLabel 140 220 200 24; $section.Add($anotherLabel)
Check ((Contacts 49).Contacts[0].State -eq 'Unknown') 'Repeated identity text on different rows is ambiguous even in an anonymous group container'

# Exercise the real fallback dispatch/capture against controlled OS responses.
$window = Window 48; $column = Column $window; $row = ChatRow $column 'Mario Rossi'
$avatar = Node 'Foto del profilo di Mario Rossi' 'avatar-image'; $avatar.Cached.ControlType = $controlType::Image
Bounds $avatar 100 150 24 24; $row.Add($avatar)
$screenType::Reset()
Check ((Contacts 48).Contacts[0].State -eq 'Available') 'An identified row with no UIA status can use its visible avatar badge'
Check ($screenType::PixelCalls -gt 0 -and $screenType::DcGets -eq $screenType::DcReleases -and $screenType::DpiRestores -eq 1) 'Visual capture releases the DC and restores only its own thread DPI context'
Check ($screenType::BitmapDeletes -eq 1 -and $screenType::MemoryDeletes -eq 1) 'The in-memory badge bitmap and its DC must be disposed'
$screenType::Reset(); $screenType::CopyFails = $true
Check ((Contacts 48).Contacts[0].State -eq 'Unknown' -and $screenType::BitmapDeletes -eq 1 -and $screenType::MemoryDeletes -eq 1) 'A failed screen copy cannot provide presence and must release its resources'
$screenType::Reset(); $screenType::Blocked = $true
Check ((Contacts 48).Contacts[0].State -eq 'Unknown' -and $screenType::PixelCalls -eq 0) 'A badge covered by another window must not be sampled'
Check ($screenType::DcGets -eq $screenType::DcReleases -and $screenType::DpiRestores -eq 1) 'An occlusion early return must still clean up native state'
$screenType::Reset(); $screenType::CoverDuringRead = $true
Check ((Contacts 48).Contacts[0].State -eq 'Unknown') 'A covering window appearing during capture invalidates the badge'
$screenType::Reset(); $screenType::Minimized = $true
Check ((Contacts 48).Contacts[0].State -eq 'Unknown' -and $screenType::PixelCalls -eq 0) 'Minimized Teams cannot produce visual evidence'
$screenType::Reset(); $screenType::DpiAllowed = $false
Check ((Contacts 48).Contacts[0].State -eq 'Unknown' -and $screenType::PixelCalls -eq 0) 'No physical DPI coordinate context means no visual guess'
$screenType::Reset()
$null = $conversationType::Inspect([IntPtr]48, [string[]]@('Mario Rossi'), $false)
Check ($screenType::PixelCalls -eq 0 -and $screenType::DcGets -eq 0) 'Visual opt-out must not access screen pixels'
$screenType::Reset(); $label = $row.Children[0]; $label.ChangeOnRefresh = $label.Refreshes + 2; $label.ChangedName = 'Another Person'
Check ((Contacts 48).Contacts[0].State -eq 'Unknown') 'A recycled row changing identity during capture must not leak the old name into a new badge'
$label.ChangeOnRefresh = 0; $label.Cached.Name = 'Mario Rossi'
$screenType::Reset(); $screenType::CenterX = -1901; Bounds $avatar -1924 150 24 24
Check ($badgeType::Read([IntPtr]48, $avatar.Cached.BoundingRectangle) -eq 'Available') 'Physical pixel sampling supports negative-coordinate monitors'

# Synthetic badge tiles test the actual color/shape classifier, not live capture.
function Tile {
    param([uint32]$Color)
    $pixels = New-Object 'uint32[]' 256
    for ($y = 0; $y -lt 16; $y++) { for ($x = 0; $x -lt 16; $x++) {
        $pixels[$y * 16 + $x] = 0x202020
        if (($x - 8) * ($x - 8) + ($y - 8) * ($y - 8) -le 16) { $pixels[$y * 16 + $x] = $Color }
    } }
    return ,$pixels
}
Check ($badgeType::Classify((Tile 0x30a030), 16) -eq 'Available') 'Compact green badge'
Check ($badgeType::Classify((Tile 0x20c0f0), 16) -eq 'Away') 'Compact yellow badge (COLORREF channel order)'
Check ($badgeType::Classify((Tile 0x3030d0), 16) -eq 'BusyOrDnd') 'Red cannot safely distinguish Busy from Dnd'
Check ($badgeType::Classify((Tile 0x888888), 16) -eq 'Unknown') 'Gray does not mean Offline by deduction'
$pixels = Tile 0x30a030; $pixels[0] = [uint32]::MaxValue
Check ($badgeType::Classify($pixels, 16) -eq 'Unknown') 'Failed native pixel reads invalidate the tile'
$pixels = New-Object 'uint32[]' 256; for ($i = 0; $i -lt 256; $i++) { $pixels[$i] = 0x30a030 }
Check ($badgeType::Classify($pixels, 16) -eq 'Unknown') 'A green avatar/photo/background is not a compact presence dot'
$pixels = Tile 0x30a030; for ($x = 0; $x -lt 16; $x++) { $pixels[8 * 16 + $x] = 0x30a030 }
Check ($badgeType::Classify($pixels, 16) -eq 'Unknown') 'Clipped/elongated colored patches are not badges'
Check ($badgeType::Classify((New-Object 'uint32[]' 4), 16) -eq 'Unknown') 'Malformed tile is rejected'

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
