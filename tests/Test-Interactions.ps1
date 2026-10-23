#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$fakeName = 'KtgFocusTest' + [guid]::NewGuid().ToString('N')
$fake = Add-Type -TypeDefinition @"
public static class $fakeName {
    public static bool FocusAllowed = true;
    public static bool Foreground = true;
    public static int FocusCalls;
    public static System.IntPtr OtherWindow = new System.IntPtr(7);
    public static bool FocusWindow(System.IntPtr handle) { FocusCalls++; return FocusAllowed; }
    public static bool IsForeground(System.IntPtr handle) { return Foreground; }
    public static System.IntPtr GetForegroundSnapshot() { return Foreground ? new System.IntPtr(42) : OtherWindow; }
}
"@ -PassThru
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'local/Interactions.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
foreach ($name in @('Invoke-ScopedJitter', 'Invoke-TeamsFocusAction', 'Complete-TeamsFocusAction', 'Receive-TeamsFocusAction', 'Request-TeamsAutoFocus')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($node.Extent.Text.Replace('[Win32Window]', "[$fakeName]").Replace('$foreground.Handle', '$foreground')))
}
function Get-TeamsWindow { return [pscustomobject]@{ Handle = [IntPtr]42 } }
function Get-EnginePauseReason { if ($script:Paused) { return 'Test pause' } }
function Get-TeamsClientArea { return New-Object Drawing.Rectangle(-1920, 20, 1280, 720) }
function Set-CursorPoint { param($Point); $script:Pointer = $Point; $script:Moves++ }
function Get-CursorPoint { return $script:Pointer }
function Get-RandomJitter { param($Maximum); return ,@(10000, -10000) }
function Clamp-ToBounds {
    param($Point, $Bounds)
    return New-Object Drawing.Point(([Math]::Min($Bounds.Right - 1, [Math]::Max($Bounds.Left, $Point.X))), ([Math]::Min($Bounds.Bottom - 1, [Math]::Max($Bounds.Top, $Point.Y))))
}
function Start-Engine { param([switch]$UseSavedConfig); if (-not $UseSavedConfig) { throw 'Unsaved UI settings used' }; $script:IsRunning = $true; $script:Starts++ }
function Add-LocalEvent { param($Kind, $Message) }
function Write-LocalError { param($Code, $Detail); throw "$Code : $Detail" }
function Invoke-Jitter { param($Mode, $MaximumPixels); $script:GlobalJitter++ }
$script:checks = 0
function Check { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message }; $script:checks++ }
$Config = @{ AutoFocusMovePointer = $true; AutoFocusStartJitter = $true; Mode = 'visible'; MaxJitterPixels = 5 }
$lblLocalFeedback = [pscustomobject]@{ Text = '' }
$script:Paused = $false; $script:Moves = 0; $script:Starts = 0; $script:IsRunning = $false
$script:Pointer = New-Object Drawing.Point(10, 10)
$script:TeamsJitterHandle = [IntPtr]::Zero; $script:JitterCount = 0
Invoke-TeamsFocusAction
Check ($script:IsRunning -and $script:Starts -eq 1) 'Focus action must start a stopped engine using saved settings'
Check ($script:TeamsJitterHandle -eq [IntPtr]42) 'Jitter must target the focused Teams handle'
Check ($script:JitterCount -eq 1) 'One immediate jitter'
Check ($script:Pointer.X -eq -641 -and $script:Pointer.Y -eq 20) 'Jitter must clamp to client bounds on a negative-coordinate monitor'
Invoke-TeamsFocusAction
Check ($script:Starts -eq 1) 'Do not restart an already-running engine'
$baselineMoves = $script:Moves
$fake::Foreground = $false
Check (-not (Invoke-ScopedJitter)) 'Do not jitter another foreground window'
Check ($script:Moves -eq $baselineMoves) 'No pointer movement after losing focus'
$fake::Foreground = $true
$script:Pointer = New-Object Drawing.Point(10, 10)
Check (-not (Invoke-ScopedJitter)) 'Do not jitter when pointer is outside Teams'
$fake::FocusAllowed = $false
$script:IsRunning = $false
Invoke-TeamsFocusAction
Check (-not $script:IsRunning -and $script:Moves -eq $baselineMoves) 'Denied focus must not move pointer or start engine'
$fake::FocusAllowed = $true
$script:Paused = $true
Invoke-TeamsFocusAction
Check (-not $script:IsRunning -and $script:Moves -eq $baselineMoves) 'Schedule or desktop pause blocks focus actions'
$script:Paused = $false
$Config.AutoFocusStartJitter = $false
$Config.AutoFocusMovePointer = $false
Invoke-TeamsFocusAction
Check (-not $script:IsRunning -and $script:Moves -eq $baselineMoves) 'Focus-only configuration must not start jitter or move pointer'
$script:TeamsJitterHandle = [IntPtr]::Zero; $script:GlobalJitter = 0
Check (Invoke-ScopedJitter) 'Untargeted engine keeps original jitter behavior'
Check ($script:GlobalJitter -eq 1) 'Untargeted mode invokes original engine'
$Config.AutoFocusEnabled = $true; $Config.AutoFocusTrigger = 'Background'
$script:AutoFocusSuppressed = $false; $script:AutoFocusRequest = $null
Request-TeamsAutoFocus 'Away'
Check ($null -eq $script:AutoFocusRequest) 'Away requests must not shadow a background-only trigger'
$Config.AutoFocusTrigger = 'Both'
Request-TeamsAutoFocus 'Away'
Check ($script:AutoFocusRequest.Reason -eq 'Away') 'Combined trigger queues away requests'

# A queued activation is NOT confirmed keyboard focus. Exercise the real
# continuation with a controlled clock; no sleeps or Windows input required.
$script:testNow = Get-Date
function Get-Date { return $script:testNow }
function Get-IdleSeconds { return $script:testIdle }
$script:testIdle = 20; $script:LocalGeneration = 1
$Config.AutoFocusEnabled = $true; $Config.AutoFocusIdleSeconds = 5
$Config.AutoFocusMovePointer = $true; $Config.AutoFocusStartJitter = $true
$script:PendingFocusAction = $null; $script:IsRunning = $false; $script:AutoFocusSuppressed = $false
$fake::Foreground = $false; $fake::FocusCalls = 0
$baselineMoves = $script:Moves; $baselineStarts = $script:Starts; $baselineJitters = $script:JitterCount
Invoke-TeamsFocusAction -Automatic
Check ($null -ne $script:PendingFocusAction -and $script:Moves -eq $baselineMoves -and $script:Starts -eq $baselineStarts) 'Queued activation must not move the pointer or start jitter'
$script:testNow = $script:testNow.AddSeconds(1)
Receive-TeamsFocusAction
Receive-TeamsFocusAction
Check ($fake::FocusCalls -eq 2) 'One bounded retry, never an activation loop'
$fake::Foreground = $true
$script:testNow = $script:testNow.AddSeconds(1)
Receive-TeamsFocusAction
Receive-TeamsFocusAction
Check ($null -eq $script:PendingFocusAction -and $script:Starts -eq $baselineStarts + 1 -and $script:JitterCount -eq $baselineJitters + 1) 'Delayed real foreground confirmation executes actions exactly once'

$fake::Foreground = $false; $script:IsRunning = $false
$baselineMoves = $script:Moves; $baselineStarts = $script:Starts
Invoke-TeamsFocusAction -Automatic
$script:testNow = $script:testNow.AddSeconds(3)
Receive-TeamsFocusAction
Check ($null -eq $script:PendingFocusAction -and $script:Moves -eq $baselineMoves -and $script:Starts -eq $baselineStarts) 'Taskbar flashing without real focus must not trigger pointer/jitter actions'
Check ($script:FocusActionStatus -like '*solo lampeggio*') 'Explain an OS-denied foreground request in diagnostics'

Invoke-TeamsFocusAction -Automatic
$script:testNow = $script:testNow.AddMinutes(10); $fake::Foreground = $true
Receive-TeamsFocusAction
Check ($null -eq $script:PendingFocusAction -and $script:Moves -eq $baselineMoves -and $script:Starts -eq $baselineStarts) 'Stale activation after suspend must not execute actions even if Teams is now foreground'
$fake::Foreground = $false

Invoke-TeamsFocusAction -Automatic
$script:testIdle = 0
Receive-TeamsFocusAction
Check ($null -eq $script:PendingFocusAction -and $script:Moves -eq $baselineMoves) 'New user input cancels automatic activation follow-up'
$script:testIdle = 20
Invoke-TeamsFocusAction -Automatic
$script:Paused = $true
Receive-TeamsFocusAction
Check ($null -eq $script:PendingFocusAction -and $script:Moves -eq $baselineMoves) 'Desktop lock or schedule pause cancels pending activation'
$script:Paused = $false
Invoke-TeamsFocusAction -Automatic
$script:LocalGeneration++
Receive-TeamsFocusAction
Check ($null -eq $script:PendingFocusAction) 'Saving different rules invalidates pending activation'
Invoke-TeamsFocusAction
$fake::OtherWindow = [IntPtr]99
Receive-TeamsFocusAction
Check ($null -eq $script:PendingFocusAction -and $script:Moves -eq $baselineMoves) 'Choosing another foreground app cancels the pending retry'
$fake::OtherWindow = [IntPtr]7
Invoke-TeamsFocusAction
$fake::Foreground = $true; $script:testIdle = 0
Receive-TeamsFocusAction
Check ($null -eq $script:PendingFocusAction -and $script:Starts -eq $baselineStarts + 1) 'Explicit manual focus may complete without automatic idle delay'
$mainAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'script.gui.ps1'), [ref]$tokens, [ref]$errors)
$stop = $mainAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-Engine' }, $true)
. ([scriptblock]::Create($stop.Extent.Text))
function Update-Dashboard {}
$script:IsRunning = $false; $script:AutoFocusSuppressed = $false; $script:ManualFocusPending = $true
$script:PendingFocusAction = @{ Handle = [IntPtr]42 }
Stop-Engine
Check $script:AutoFocusSuppressed 'Stop disarms autofocus even while jitter is stopped'
Check (-not $script:ManualFocusPending -and $script:TeamsJitterHandle -eq [IntPtr]::Zero) 'Stop clears queued manual work and target'
Check ($null -eq $script:PendingFocusAction) 'Stop clears delayed activation follow-up even when jitter is already stopped'

# Compile the actual inline native helper, replacing ONLY its OS calls. This
# checks activation commands for minimized vs already-open windows on Linux too.
$assignment = $mainAst.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$win32Source' }, $true)
$nativeLiteral = $assignment.Right.Find({ param($n) $n -is [Management.Automation.Language.ExpandableStringExpressionAst] -or $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true)
$nativeSource = $nativeLiteral.Value
$nativeSource = $nativeSource.Substring(0, $nativeSource.IndexOf('public class PassiveOverlayForm'))
$nativeNamespace = 'KtgNativeFocus' + [guid]::NewGuid().ToString('N')
$stubs = @{
    GetForegroundWindow = 'return FocusBackend.Foreground;'
    IsWindow = 'return FocusBackend.Valid;'
    IsIconic = 'return FocusBackend.Minimized;'
    ShowWindowAsync = 'FocusBackend.ShowCommand = command; FocusBackend.ShowCalls++; return FocusBackend.ShowAccepted;'
    SetWindowPos = 'FocusBackend.After = after; FocusBackend.Flags = flags; FocusBackend.RaiseCalls++; return FocusBackend.RaiseAccepted;'
    SetForegroundWindow = 'FocusBackend.ActivateCalls++; if (FocusBackend.Confirm) FocusBackend.Foreground = handle; return FocusBackend.ActivateAccepted;'
}
$nativeSource = [regex]::Replace($nativeSource, '(\[DllImport\([^\r\n]+\)\]\s+)private static extern ([^;]+);', [Text.RegularExpressions.MatchEvaluator]{
    param($match)
    $signature = $match.Groups[2].Value
    $method = [regex]::Match($signature, '(\w+)\(').Groups[1].Value
    if ($stubs.ContainsKey($method)) { return 'private static ' + $signature + ' { ' + $stubs[$method] + ' }' }
    return $match.Value
})
$backendSource = @'
public static class FocusBackend {
    public static System.IntPtr Foreground, After;
    public static bool Valid, Minimized, ShowAccepted, RaiseAccepted, ActivateAccepted, Confirm;
    public static int ShowCommand, ShowCalls, RaiseCalls, ActivateCalls;
    public static uint Flags;
    public static void Reset() {
        Foreground = new System.IntPtr(7); After = new System.IntPtr(-99);
        Valid = true; Minimized = false; ShowAccepted = RaiseAccepted = true;
        ActivateAccepted = Confirm = false;
        ShowCommand = ShowCalls = RaiseCalls = ActivateCalls = 0; Flags = 0;
    }
}
'@
$nativeTypes = @(Add-Type -TypeDefinition ("namespace $nativeNamespace {`n" + $nativeSource + $backendSource + "`n}") -PassThru)
$native = $nativeTypes | Where-Object FullName -EQ "$nativeNamespace.Win32Window"
$backend = $nativeTypes | Where-Object FullName -EQ "$nativeNamespace.FocusBackend"
$backend::Reset()
Check ($native::FocusWindow([IntPtr]42)) 'Asynchronous show/Z-order acceptance keeps the request pending even if SetForegroundWindow returns false'
Check ($backend::ShowCommand -eq 5) 'An already-open background window receives SW_SHOW, preserving its maximized state'
Check ($backend::RaiseCalls -eq 1 -and $backend::After -eq [IntPtr]::Zero) 'Bring Teams to normal HWND_TOP, never force permanent topmost'
Check (($backend::Flags -band 0x4000) -ne 0 -and ($backend::Flags -band 3) -eq 3) 'Z-order activation is asynchronous and cannot resize or move Teams'
Check (-not $native::IsForeground([IntPtr]42)) 'A queued API success must not masquerade as actual foreground'
$backend::Reset(); $backend::Minimized = $true
$null = $native::FocusWindow([IntPtr]42)
Check ($backend::ShowCommand -eq 9) 'A minimized Teams window still receives SW_RESTORE'
$backend::Reset(); $backend::Confirm = $true
Check ($native::FocusWindow([IntPtr]42) -and $native::IsForeground([IntPtr]42)) 'Actual foreground confirmation is authoritative'
$backend::Reset(); $backend::Foreground = [IntPtr]42
Check ($native::FocusWindow([IntPtr]42) -and $backend::ShowCalls -eq 0 -and $backend::ActivateCalls -eq 0) 'An already-focused window is not reactivated unnecessarily'
$backend::Reset(); $backend::Valid = $false
Check (-not $native::FocusWindow([IntPtr]42) -and $backend::ShowCalls -eq 0) 'Do not queue activation for a destroyed window'
$backend::Reset()
Check (-not $native::FocusWindow([IntPtr]::Zero) -and $backend::ShowCalls -eq 0) 'Null window handles cannot receive activation'
$backend::Reset(); $backend::ShowAccepted = $false; $backend::RaiseAccepted = $false
Check (-not $native::FocusWindow([IntPtr]42)) 'All activation requests rejected must return failure'
Write-Output "PASS: $script:checks interaction checks (native activation with OS doubles, delayed focus confirmation, cancellation, bounds, original engine; not live Windows verification)."
