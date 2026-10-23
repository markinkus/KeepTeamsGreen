#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$fakeName = 'KtgFocusTest' + [guid]::NewGuid().ToString('N')
$fake = Add-Type -TypeDefinition @"
public static class $fakeName {
    public static bool FocusAllowed = true;
    public static bool Foreground = true;
    public static bool FocusWindow(System.IntPtr handle) { return FocusAllowed; }
    public static bool IsForeground(System.IntPtr handle) { return Foreground; }
}
"@ -PassThru
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'local/Interactions.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
foreach ($name in @('Invoke-ScopedJitter', 'Invoke-TeamsFocusAction', 'Request-TeamsAutoFocus')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($node.Extent.Text.Replace('[Win32Window]', "[$fakeName]")))
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
$moves = $script:Moves
$fake::Foreground = $false
Check (-not (Invoke-ScopedJitter)) 'Do not jitter another foreground window'
Check ($script:Moves -eq $moves) 'No pointer movement after losing focus'
$fake::Foreground = $true
$script:Pointer = New-Object Drawing.Point(10, 10)
Check (-not (Invoke-ScopedJitter)) 'Do not jitter when pointer is outside Teams'
$fake::FocusAllowed = $false
$script:IsRunning = $false
Invoke-TeamsFocusAction
Check (-not $script:IsRunning -and $script:Moves -eq $moves) 'Denied focus must not move pointer or start engine'
$fake::FocusAllowed = $true
$script:Paused = $true
Invoke-TeamsFocusAction
Check (-not $script:IsRunning -and $script:Moves -eq $moves) 'Schedule or desktop pause blocks focus actions'
$script:Paused = $false
$Config.AutoFocusStartJitter = $false
$Config.AutoFocusMovePointer = $false
Invoke-TeamsFocusAction
Check (-not $script:IsRunning -and $script:Moves -eq $moves) 'Focus-only configuration must not start jitter or move pointer'
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
$mainAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'script.gui.ps1'), [ref]$tokens, [ref]$errors)
$stop = $mainAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-Engine' }, $true)
. ([scriptblock]::Create($stop.Extent.Text))
function Update-Dashboard {}
$script:IsRunning = $false; $script:AutoFocusSuppressed = $false; $script:ManualFocusPending = $true
Stop-Engine
Check $script:AutoFocusSuppressed 'Stop disarms autofocus even while jitter is stopped'
Check (-not $script:ManualFocusPending -and $script:TeamsJitterHandle -eq [IntPtr]::Zero) 'Stop clears queued manual work and target'
Write-Output "PASS: $script:checks interaction checks (focus denial, mouse bounds, auto-start, saved settings, pause, original engine)."
