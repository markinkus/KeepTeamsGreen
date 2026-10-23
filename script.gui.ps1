#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# Keep Windows Forms on Windows PowerShell 5.1 and on an STA thread.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $self = "`"$PSCommandPath`""
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File $self" -WindowStyle Normal
    exit
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $self = "`"$PSCommandPath`""
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File $self" -WindowStyle Normal
    exit
}

$AppName = 'KeepTeamsGreen'
$AppVersion = '2.3.3'
$AppDataDir = Join-Path $env:APPDATA $AppName
$LogPath = Join-Path $AppDataDir 'last_run.log'
$ConfigPath = Join-Path $AppDataDir 'config.json'
$ConfigBackupPath = Join-Path $AppDataDir 'config.backup.json'
$BaseDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BaseDir)) {
    $BaseDir = [System.AppDomain]::CurrentDomain.BaseDirectory
}
$LogoPath = Join-Path $BaseDir 'logo.png'
if (-not (Test-Path -LiteralPath $LogoPath)) {
    $embeddedLogoPath = if (-not [string]::IsNullOrWhiteSpace($env:KTG_ASSET_DIR)) {
        Join-Path $env:KTG_ASSET_DIR 'logo.png'
    } else {
        Join-Path $AppDataDir 'assets\logo.png'
    }
    if (Test-Path -LiteralPath $embeddedLogoPath) {
        $LogoPath = $embeddedLogoPath
    }
}

if (-not (Test-Path -LiteralPath $AppDataDir)) {
    New-Item -ItemType Directory -Path $AppDataDir -Force | Out-Null
}

function Get-AppResourceText {
    param([string]$Name)
    # EXE resources take precedence so source files beside the EXE cannot replace them.
    $assembly = [Reflection.Assembly]::GetEntryAssembly()
    if ($null -ne $assembly) {
        $stream = $assembly.GetManifestResourceStream($Name)
        if ($null -ne $stream) {
            $reader = New-Object IO.StreamReader -ArgumentList $stream, ([Text.Encoding]::UTF8), $true
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
    }
    return [IO.File]::ReadAllText((Join-Path $BaseDir $Name))
}

. ([scriptblock]::Create((Get-AppResourceText 'local/Rules.ps1')))

function Write-AppLog {
    param([string]$Message)

    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -ge 1MB) {
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.previous') -Force
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss} | {1}' -f (Get-Date), $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

try { Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue } catch { }

trap {
    Write-AppLog ("Errore non gestito: {0}" -f $_.Exception.Message)
    try {
        [System.Environment]::SetEnvironmentVariable('KTG_ERROR_SHOWN', '1', 'Process')
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            $_.ToString(),
            'KeepTeamsGreen - Errore',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch { }
    try {
        if ($null -ne $EngineTimer) { $EngineTimer.Stop() }
        if ($null -ne $OperationsTimer) { $OperationsTimer.Stop() }
        if ($null -ne $AlertTimer) { $AlertTimer.Stop() }
        if ($null -ne $Notify) { $Notify.Visible = $false; $Notify.Dispose() }
        if ($null -ne $MascotForm) { $MascotForm.Dispose() }
        if ($null -ne $Form) { $Form.Dispose() }
    } catch { }
    break
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$win32Source = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class Win32Idle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll")]
    private static extern uint GetTickCount();

    public static uint GetIdleTimeMs() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info)) {
            return 0;
        }
        return unchecked(GetTickCount() - info.dwTime);
    }
}

public static class Win32Cursor {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);
}

public sealed class WindowSnapshot {
    public IntPtr Handle { get; set; }
    public int ProcessId { get; set; }
    public string ProcessName { get; set; }
    public string Title { get; set; }
}

public static class Win32Window {
    private delegate bool EnumWindowsProc(IntPtr handle, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr handle);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowText(IntPtr handle, StringBuilder text, int maximumCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr handle);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr iconHandle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")]
    private static extern bool CloseDesktop(IntPtr handle);
    [DllImport("user32.dll")]
    private static extern bool SwitchDesktop(IntPtr handle);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr handle);
    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr handle, int command);
    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr handle, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr handle);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr handle);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr handle, out RECT rect);
    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr handle, ref Win32Cursor.POINT point);

    public static bool IsForeground(IntPtr handle) { return GetForegroundWindow() == handle; }

    public static RECT ClientBounds(IntPtr handle) {
        RECT rect;
        if (IsIconic(handle) || !GetClientRect(handle, out rect)) return new RECT();
        Win32Cursor.POINT point = new Win32Cursor.POINT();
        if (!ClientToScreen(handle, ref point)) return new RECT();
        rect.Right += point.X; rect.Bottom += point.Y;
        rect.Left += point.X; rect.Top += point.Y;
        return rect;
    }

    public static bool IsDesktopUnlocked() {
        IntPtr desktop = OpenInputDesktop(0, false, 0x0100);
        if (desktop == IntPtr.Zero) return false;
        try { return SwitchDesktop(desktop); }
        finally { CloseDesktop(desktop); }
    }

    public static bool FocusWindow(IntPtr handle) {
        if (handle == IntPtr.Zero || !IsWindow(handle)) return false;
        if (IsForeground(handle)) return true;
        // Restore a minimized window; otherwise activate it without changing
        // its size/maximized state. Cross-process show/Z-order calls are async.
        bool shown = ShowWindowAsync(handle, IsIconic(handle) ? 9 : 5);
        bool raised = SetWindowPos(handle, IntPtr.Zero, 0, 0, 0, 0, 0x4000 | 0x0200 | 0x0040 | 0x0002 | 0x0001);
        bool requested = SetForegroundWindow(handle);
        // Accepted means only "request queued". The UI timer must verify the
        // real foreground window before moving the pointer or starting jitter.
        return IsForeground(handle) || shown || raised || requested;
    }

    private static WindowSnapshot ReadWindow(IntPtr handle) {
        if (handle == IntPtr.Zero) {
            return null;
        }

        int length = GetWindowTextLength(handle);
        StringBuilder title = new StringBuilder(Math.Max(length + 1, 2));
        GetWindowText(handle, title, title.Capacity);

        uint processId;
        GetWindowThreadProcessId(handle, out processId);
        string processName = String.Empty;
        try {
            processName = Process.GetProcessById((int)processId).ProcessName;
        } catch { }

        return new WindowSnapshot {
            Handle = handle,
            ProcessId = (int)processId,
            ProcessName = processName,
            Title = title.ToString()
        };
    }

    public static WindowSnapshot GetForegroundSnapshot() {
        return ReadWindow(GetForegroundWindow());
    }

    public static WindowSnapshot[] GetVisibleWindows() {
        List<WindowSnapshot> windows = new List<WindowSnapshot>();
        EnumWindows(delegate(IntPtr handle, IntPtr parameter) {
            if (IsWindowVisible(handle) && GetWindowTextLength(handle) > 0) {
                WindowSnapshot snapshot = ReadWindow(handle);
                if (snapshot != null) {
                    windows.Add(snapshot);
                }
            }
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
public class PassiveOverlayForm : System.Windows.Forms.Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override System.Windows.Forms.CreateParams CreateParams {
        get {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000080;
            return cp;
        }
    }
}
"@
Add-Type -TypeDefinition $win32Source -ReferencedAssemblies @([object].Assembly.Location, [Diagnostics.Process].Assembly.Location, [System.Windows.Forms.Form].Assembly.Location, [System.Drawing.Point].Assembly.Location)
if ($null -eq ('NotificationAudio' -as [type])) {
    Add-Type -TypeDefinition (Get-AppResourceText 'local/NotificationAudio.cs')
}

$script:UIAutomationAvailable = $false
$presenceProbeSource = (Get-AppResourceText 'local/PresenceText.cs') + [Environment]::NewLine + (Get-AppResourceText 'local/PresenceReader.cs') + [Environment]::NewLine + (Get-AppResourceText 'local/ConversationReader.cs')

try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName WindowsBase
    $uiaReferences = @(
        [object].Assembly.Location,
        [Diagnostics.Process].Assembly.Location,
        [System.Linq.Enumerable].Assembly.Location,
        [System.Windows.Automation.AutomationElement].Assembly.Location,
        [System.Windows.Automation.AutomationIdentifier].Assembly.Location,
        [System.Windows.Rect].Assembly.Location
    ) | Select-Object -Unique
    if ($null -eq ('KeepTeamsGreenMonitoring.TeamsPresenceProbe' -as [type])) {
        Add-Type -TypeDefinition $presenceProbeSource -ReferencedAssemblies $uiaReferences
    }
    $script:UIAutomationAvailable = $true
} catch {
    Write-AppLog ("UI Automation non disponibile: {0}" -f $_.Exception.Message)
}

$ConfigDefaults = [ordered]@{
    SchemaVersion               = 6
    IdleThresholdSeconds        = 120
    JitterIntervalSecondsMin    = 3
    JitterIntervalSecondsMax    = 3
    MaxJitterPixels             = 5
    Mode                        = 'visible'
    StartMinimizedToTray        = $false
    MonitorTeamsPresence        = $true
    AlertOnPresenceDrop         = $true
    ShowMascotWhenRunning       = $false
    MonitorColleagues           = $false
    ColleagueReadVisibleBadges  = $true
    ColleagueScanSeconds        = 15
    ColleagueCooldownSeconds    = 120
    Colleagues                  = @()
    ScheduleEnabled             = $false
    ScheduleDays                = 'Weekdays'
    ScheduleFrom                = '09:00'
    ScheduleTo                  = '18:00'
    RecoverAway                 = $false
    AutoFocusEnabled            = $false
    AutoFocusTrigger            = 'Away'
    AutoFocusIdleSeconds        = 5
    AutoFocusCooldownSeconds    = 60
    AutoFocusMovePointer        = $true
    AutoFocusStartJitter        = $true
    MascotScalePercent          = 100
    MascotOpacityPercent        = 96
    NotificationSound           = 'System'
    NotificationVolumePercent   = 60
}

$Config = [ordered]@{}
foreach ($key in $ConfigDefaults.Keys) {
    $Config[$key] = $ConfigDefaults[$key]
}
$script:LastConfigError = $null

function Convert-ToBoundedInt {
    param(
        $Value,
        [int]$Default,
        [int]$Minimum,
        [int]$Maximum
    )

    $parsed = 0
    if ($null -eq $Value -or -not [int]::TryParse([string]$Value, [ref]$parsed)) {
        return $Default
    }
    return [Math]::Min([Math]::Max($parsed, $Minimum), $Maximum)
}

function Convert-ToBoolean {
    param($Value, [bool]$Default)

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($null -eq $Value) {
        return $Default
    }

    switch -Regex ([string]$Value) {
        '^(true|1|yes|si)$'  { return $true }
        '^(false|0|no)$'     { return $false }
        default              { return $Default }
    }
}

function Normalize-Config {
    $Config['SchemaVersion'] = 6
    $Config['IdleThresholdSeconds'] = Convert-ToBoundedInt -Value $Config['IdleThresholdSeconds'] -Default 120 -Minimum 5 -Maximum 3600
    $Config['JitterIntervalSecondsMin'] = Convert-ToBoundedInt -Value $Config['JitterIntervalSecondsMin'] -Default 3 -Minimum 1 -Maximum 600
    $Config['JitterIntervalSecondsMax'] = Convert-ToBoundedInt -Value $Config['JitterIntervalSecondsMax'] -Default 3 -Minimum 1 -Maximum 600
    if ($Config['JitterIntervalSecondsMin'] -gt $Config['JitterIntervalSecondsMax']) {
        $Config['JitterIntervalSecondsMax'] = $Config['JitterIntervalSecondsMin']
    }
    $Config['MaxJitterPixels'] = Convert-ToBoundedInt -Value $Config['MaxJitterPixels'] -Default 5 -Minimum 1 -Maximum 50
    if ([string]$Config['Mode'] -notin @('visible', 'stealth')) {
        $Config['Mode'] = 'visible'
    }
    $Config['StartMinimizedToTray'] = Convert-ToBoolean $Config['StartMinimizedToTray'] $false
    $Config['MonitorTeamsPresence'] = Convert-ToBoolean $Config['MonitorTeamsPresence'] $true
    $Config['AlertOnPresenceDrop'] = Convert-ToBoolean $Config['AlertOnPresenceDrop'] $true
    $Config['ShowMascotWhenRunning'] = Convert-ToBoolean $Config['ShowMascotWhenRunning'] $false
    $Config['MonitorColleagues'] = Convert-ToBoolean $Config['MonitorColleagues'] $false
    $Config['ColleagueReadVisibleBadges'] = Convert-ToBoolean $Config['ColleagueReadVisibleBadges'] $true
    $Config['ScheduleEnabled'] = Convert-ToBoolean $Config['ScheduleEnabled'] $false
    $Config['RecoverAway'] = Convert-ToBoolean $Config['RecoverAway'] $false
    $Config['AutoFocusEnabled'] = Convert-ToBoolean $Config['AutoFocusEnabled'] $false
    $Config['AutoFocusMovePointer'] = Convert-ToBoolean $Config['AutoFocusMovePointer'] $true
    $Config['AutoFocusStartJitter'] = Convert-ToBoolean $Config['AutoFocusStartJitter'] $true
    if ($Config['AutoFocusTrigger'] -notin @('Away', 'Background', 'Both')) { $Config['AutoFocusTrigger'] = 'Away' }
    $Config['AutoFocusIdleSeconds'] = Convert-ToBoundedInt -Value $Config['AutoFocusIdleSeconds'] -Default 5 -Minimum 1 -Maximum 120
    $Config['AutoFocusCooldownSeconds'] = Convert-ToBoundedInt -Value $Config['AutoFocusCooldownSeconds'] -Default 60 -Minimum 15 -Maximum 3600
    $Config['MascotScalePercent'] = Convert-ToBoundedInt -Value $Config['MascotScalePercent'] -Default 100 -Minimum 60 -Maximum 200
    $Config['MascotOpacityPercent'] = Convert-ToBoundedInt -Value $Config['MascotOpacityPercent'] -Default 96 -Minimum 25 -Maximum 100
    if ($Config['NotificationSound'] -notin @('System', 'Alarm', 'Siren', 'Nuclear', 'Silent')) { $Config['NotificationSound'] = 'System' }
    $Config['NotificationVolumePercent'] = Convert-ToBoundedInt -Value $Config['NotificationVolumePercent'] -Default 60 -Minimum 0 -Maximum 100
    $Config['ColleagueScanSeconds'] = Convert-ToBoundedInt -Value $Config['ColleagueScanSeconds'] -Default 15 -Minimum 5 -Maximum 300
    $Config['ColleagueCooldownSeconds'] = Convert-ToBoundedInt -Value $Config['ColleagueCooldownSeconds'] -Default 120 -Minimum 60 -Maximum 3600
    if ($Config['ScheduleDays'] -notin @('Everyday', 'Weekdays', 'Weekend')) { $Config['ScheduleDays'] = 'Weekdays' }
    if (-not (Test-LocalTime $Config['ScheduleFrom'])) { $Config['ScheduleFrom'] = '09:00' }
    if (-not (Test-LocalTime $Config['ScheduleTo'])) { $Config['ScheduleTo'] = '18:00' }
    $validContacts = @()
    $names = @{}
    foreach ($person in @($Config['Colleagues'])) {
        if ($null -eq $person) { continue }
        $name = ([string]$person.Name).Trim()
        if ($name.Length -lt 3 -or $name.Length -gt 100 -or $names.ContainsKey($name) -or $validContacts.Count -ge 40) { continue }
        $names[$name] = $true
        $rule = [string]$person.Rule
        if ($rule -notin @('Available', 'Change')) { $rule = 'Available' }
        $days = [string]$person.Days
        if ($days -notin @('Everyday', 'Weekdays', 'Weekend')) { $days = 'Weekdays' }
        $from = [string]$person.From; $to = [string]$person.To
        if (-not (Test-LocalTime $from)) { $from = '09:00' }
        if (-not (Test-LocalTime $to)) { $to = '18:00' }
        $validContacts += [pscustomobject]@{ Name = $name; Rule = $rule; Days = $days; From = $from; To = $to; Enabled = (Convert-ToBoolean $person.Enabled $true) }
    }
    $Config['Colleagues'] = @($validContacts)
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return
    }

    try {
        $json = [System.IO.File]::ReadAllText($ConfigPath)
        $loaded = $json | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in $ConfigDefaults.Keys) {
            if ($loaded.PSObject.Properties.Name -contains $key) {
                $Config[$key] = $loaded.$key
            }
        }
        if ($loaded.PSObject.Properties.Name -contains 'JitterIntervalSeconds' -and
            $loaded.PSObject.Properties.Name -notcontains 'JitterIntervalSecondsMin' -and
            $loaded.PSObject.Properties.Name -notcontains 'JitterIntervalSecondsMax') {
            $legacyInterval = Convert-ToBoundedInt -Value $loaded.JitterIntervalSeconds -Default 3 -Minimum 1 -Maximum 600
            $Config['JitterIntervalSecondsMin'] = $legacyInterval
            $Config['JitterIntervalSecondsMax'] = $legacyInterval
        }
        Normalize-Config
        Write-AppLog 'Configurazione caricata.'
    } catch {
        $script:LastConfigError = "Configurazione non leggibile; caricati i valori sicuri. $($_.Exception.Message)"
        Write-AppLog $script:LastConfigError
    }
}

function Save-Config {
    $temporaryPath = Join-Path $AppDataDir ("config.{0}.tmp" -f $PID)
    try {
        Normalize-Config
        $json = [pscustomobject]$Config | ConvertTo-Json -Depth 5
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8WithoutBom)

        if (Test-Path -LiteralPath $ConfigPath) {
            [System.IO.File]::Replace($temporaryPath, $ConfigPath, $ConfigBackupPath, $true)
        } else {
            [System.IO.File]::Move($temporaryPath, $ConfigPath)
        }
        $script:LastConfigError = $null
        Write-AppLog 'Configurazione salvata.'
        return $true
    } catch {
        $script:LastConfigError = $_.Exception.Message
        Write-AppLog ("Salvataggio configurazione fallito: {0}" -f $script:LastConfigError)
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

Normalize-Config
Load-Config

function Get-IdleSeconds {
    return [int][Math]::Round([Win32Idle]::GetIdleTimeMs() / 1000.0, 0)
}

function Get-CursorPoint {
    $nativePoint = New-Object Win32Cursor+POINT
    [Win32Cursor]::GetCursorPos([ref]$nativePoint) | Out-Null
    return New-Object System.Drawing.Point -ArgumentList $nativePoint.X, $nativePoint.Y
}

function Set-CursorPoint {
    param([System.Drawing.Point]$Point)
    [Win32Cursor]::SetCursorPos([int]$Point.X, [int]$Point.Y) | Out-Null
}

function Clamp-ToBounds {
    param([System.Drawing.Point]$Point, [System.Drawing.Rectangle]$Bounds)

    $x = [Math]::Min([Math]::Max($Point.X, $Bounds.X), $Bounds.X + $Bounds.Width - 1)
    $y = [Math]::Min([Math]::Max($Point.Y, $Bounds.Y), $Bounds.Y + $Bounds.Height - 1)
    return New-Object System.Drawing.Point -ArgumentList $x, $y
}

function Get-RandomJitter {
    param([int]$Maximum)

    $deltaX = Get-Random -Minimum (-1 * $Maximum) -Maximum ($Maximum + 1)
    $deltaY = Get-Random -Minimum (-1 * $Maximum) -Maximum ($Maximum + 1)
    return ,@($deltaX, $deltaY)
}

function Invoke-Jitter {
    param([string]$Mode, [int]$MaximumPixels)

    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $start = Get-CursorPoint
    $delta = Get-RandomJitter -Maximum $MaximumPixels
    $target = New-Object System.Drawing.Point -ArgumentList ($start.X + $delta[0]), ($start.Y + $delta[1])
    $target = Clamp-ToBounds -Point $target -Bounds $bounds
    Set-CursorPoint -Point $target

    if ($Mode -eq 'stealth') {
        Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 26)
        Set-CursorPoint -Point $start
    }
}

function Color-Hex {
    param([string]$Hex)
    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

$ColorBackground = Color-Hex '#0B1410'
$ColorCard = Color-Hex '#132019'
$ColorCardAlt = Color-Hex '#182A20'
$ColorBorder = Color-Hex '#294334'
$ColorText = Color-Hex '#E9F5ED'
$ColorMuted = Color-Hex '#8DA398'
$ColorGreen = Color-Hex '#42D77D'
$ColorGreenDark = Color-Hex '#207A45'
$ColorYellow = Color-Hex '#F2C94C'
$ColorOrange = Color-Hex '#F2994A'
$ColorRed = Color-Hex '#EB5757'
$ColorBlue = Color-Hex '#56A8E8'
$ColorGray = Color-Hex '#60736A'

$script:LogoImage = $null
$script:AppIcon = $null
$script:OwnsAppIcon = $false
if (Test-Path -LiteralPath $LogoPath) {
    try {
        $sourceImage = [System.Drawing.Image]::FromFile($LogoPath)
        $script:LogoImage = New-Object System.Drawing.Bitmap -ArgumentList $sourceImage
        $sourceImage.Dispose()

        $iconBitmap = New-Object System.Drawing.Bitmap -ArgumentList 64, 64, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($iconBitmap)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($script:LogoImage, 0, 0, 64, 64)
        $iconHandle = $iconBitmap.GetHicon()
        $temporaryIcon = [System.Drawing.Icon]::FromHandle($iconHandle)
        $script:AppIcon = $temporaryIcon.Clone()
        $script:OwnsAppIcon = $true
        $temporaryIcon.Dispose()
        $graphics.Dispose()
        $iconBitmap.Dispose()
        [Win32Window]::DestroyIcon($iconHandle) | Out-Null
    } catch {
        Write-AppLog ("Logo non caricato: {0}" -f $_.Exception.Message)
    }
}
if ($null -eq $script:AppIcon) {
    $script:AppIcon = [System.Drawing.SystemIcons]::Application
}

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [float]$Size = 9,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [System.Drawing.Color]$Color = $ColorText
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $label.Size = New-Object System.Drawing.Size -ArgumentList $Width, $Height
    $label.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', $Size, $Style
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    return $label
}

function New-Card {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $panel.Size = New-Object System.Drawing.Size -ArgumentList $Width, $Height
    $panel.BackColor = $ColorCard
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    return $panel
}

function New-StatusRow {
    param(
        [System.Windows.Forms.Control]$Parent,
        [int]$Y,
        [string]$Caption
    )

    $row = New-Object System.Windows.Forms.Panel
    $row.Location = New-Object System.Drawing.Point -ArgumentList 20, $Y
    $row.Size = New-Object System.Drawing.Size -ArgumentList 388, 52
    $row.BackColor = $ColorCardAlt

    $dot = New-Object System.Windows.Forms.Panel
    $dot.Location = New-Object System.Drawing.Point -ArgumentList 14, 19
    $dot.Size = New-Object System.Drawing.Size -ArgumentList 12, 12
    $dot.BackColor = $ColorGray

    $captionLabel = New-Label -Text $Caption -X 38 -Y 6 -Width 128 -Height 18 -Size 8 -Style ([System.Drawing.FontStyle]::Regular) -Color $ColorMuted
    $valueLabel = New-Label -Text '-' -X 168 -Y 7 -Width 202 -Height 20 -Size 9 -Style ([System.Drawing.FontStyle]::Bold) -Color $ColorText
    $detailLabel = New-Label -Text '-' -X 38 -Y 27 -Width 332 -Height 18 -Size 8 -Style ([System.Drawing.FontStyle]::Regular) -Color $ColorMuted
    $row.Controls.AddRange(@($dot, $captionLabel, $valueLabel, $detailLabel))
    $Parent.Controls.Add($row)

    return [pscustomobject]@{
        Panel = $row
        Dot = $dot
        Value = $valueLabel
        Detail = $detailLabel
    }
}

function Set-ButtonStyle {
    param(
        [System.Windows.Forms.Button]$Button,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor
    )

    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = $BackColor
    $Button.ForeColor = $ForeColor
    $Button.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9, ([System.Drawing.FontStyle]::Bold)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
}

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "KeepTeamsGreen $AppVersion - Centrale operativa"
$Form.ClientSize = New-Object System.Drawing.Size -ArgumentList 920, 650
$Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$Form.MaximizeBox = $false
$Form.MinimizeBox = $true
$Form.BackColor = $ColorBackground
$Form.ForeColor = $ColorText
$Form.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9
$Form.Icon = $script:AppIcon

$headerLogo = New-Object System.Windows.Forms.PictureBox
$headerLogo.Location = New-Object System.Drawing.Point -ArgumentList 20, 12
$headerLogo.Size = New-Object System.Drawing.Size -ArgumentList 78, 78
$headerLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$headerLogo.BackColor = [System.Drawing.Color]::Transparent
if ($null -ne $script:LogoImage) { $headerLogo.Image = $script:LogoImage }

$lblTitle = New-Label -Text 'KeepTeamsGreen' -X 108 -Y 20 -Width 520 -Height 38 -Size 22 -Style ([System.Drawing.FontStyle]::Bold) -Color $ColorText
$lblSubtitle = New-Label -Text 'Centrale operativa per presenza, focus e auto-jitter' -X 111 -Y 59 -Width 560 -Height 24 -Size 9 -Color $ColorMuted
$lblLive = New-Label -Text 'LIVE' -X 826 -Y 33 -Width 58 -Height 26 -Size 9 -Style ([System.Drawing.FontStyle]::Bold) -Color $ColorGreen
$lblLive.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$lblLive.BackColor = $ColorCardAlt

$operationsCard = New-Card -X 20 -Y 105 -Width 430 -Height 475
$settingsCard = New-Card -X 470 -Y 105 -Width 430 -Height 475

$operationsTitle = New-Label -Text 'CENTRALE OPERATIVA' -X 20 -Y 15 -Width 260 -Height 24 -Size 10 -Style ([System.Drawing.FontStyle]::Bold) -Color $ColorGreen
$operationsCard.Controls.Add($operationsTitle)

$rowEngine = New-StatusRow -Parent $operationsCard -Y 48 -Caption 'MOTORE'
$rowTeams = New-StatusRow -Parent $operationsCard -Y 108 -Caption 'STATO TEAMS'
$rowFocus = New-StatusRow -Parent $operationsCard -Y 168 -Caption 'FOCUS TEAMS'
$rowActivity = New-StatusRow -Parent $operationsCard -Y 228 -Caption 'ATTIVITA'

$lblAlertBanner = New-Label -Text '' -X 20 -Y 292 -Width 388 -Height 44 -Size 8 -Style ([System.Drawing.FontStyle]::Bold) -Color $ColorText
$lblAlertBanner.BackColor = $ColorGreenDark
$lblAlertBanner.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$lblAlertBanner.Visible = $false
$operationsCard.Controls.Add($lblAlertBanner)

$lblTimelineTitle = New-Label -Text 'ULTIMO EVENTO' -X 22 -Y 342 -Width 120 -Height 18 -Size 8 -Color $ColorMuted
$lblTimeline = New-Label -Text 'In attesa di attivazione' -X 142 -Y 340 -Width 265 -Height 36 -Size 8 -Color $ColorText
$operationsCard.Controls.AddRange(@($lblTimelineTitle, $lblTimeline))

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = 'AVVIA PROTEZIONE'
$btnStart.Location = New-Object System.Drawing.Point -ArgumentList 20, 397
$btnStart.Size = New-Object System.Drawing.Size -ArgumentList 190, 48
Set-ButtonStyle -Button $btnStart -BackColor $ColorGreen -ForeColor (Color-Hex '#07120B')

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'STOP'
$btnStop.Location = New-Object System.Drawing.Point -ArgumentList 218, 397
$btnStop.Size = New-Object System.Drawing.Size -ArgumentList 190, 48
$btnStop.Enabled = $false
Set-ButtonStyle -Button $btnStop -BackColor $ColorCardAlt -ForeColor $ColorMuted
$operationsCard.Controls.AddRange(@($btnStart, $btnStop))

$settingsTitle = New-Label -Text 'IMPOSTAZIONI' -X 20 -Y 15 -Width 220 -Height 24 -Size 10 -Style ([System.Drawing.FontStyle]::Bold) -Color $ColorGreen
$settingsCard.Controls.Add($settingsTitle)

$lblIdle = New-Label -Text 'Soglia inattivita' -X 20 -Y 55 -Width 210 -Height 22 -Size 9 -Color $ColorText
$nudIdle = New-Object System.Windows.Forms.NumericUpDown
$nudIdle.Minimum = 5
$nudIdle.Maximum = 3600
$nudIdle.Value = [decimal]$Config['IdleThresholdSeconds']
$nudIdle.Location = New-Object System.Drawing.Point -ArgumentList 305, 52
$nudIdle.Size = New-Object System.Drawing.Size -ArgumentList 90, 26
$nudIdle.BackColor = $ColorCardAlt
$nudIdle.ForeColor = $ColorText
$lblIdleUnit = New-Label -Text 'secondi' -X 235 -Y 57 -Width 65 -Height 18 -Size 8 -Color $ColorMuted

$lblInterval = New-Label -Text 'Tempo jitter: min / max' -X 20 -Y 96 -Width 210 -Height 22 -Size 9 -Color $ColorText
$nudIntMin = New-Object System.Windows.Forms.NumericUpDown
$nudIntMin.Minimum = 1
$nudIntMin.Maximum = 600
$nudIntMin.Value = [decimal]$Config['JitterIntervalSecondsMin']
$nudIntMin.Location = New-Object System.Drawing.Point -ArgumentList 253, 93
$nudIntMin.Size = New-Object System.Drawing.Size -ArgumentList 65, 26
$nudIntMin.BackColor = $ColorCardAlt
$nudIntMin.ForeColor = $ColorText
$nudIntMax = New-Object System.Windows.Forms.NumericUpDown
$nudIntMax.Minimum = 1
$nudIntMax.Maximum = 600
$nudIntMax.Value = [decimal]$Config['JitterIntervalSecondsMax']
$nudIntMax.Location = New-Object System.Drawing.Point -ArgumentList 330, 93
$nudIntMax.Size = New-Object System.Drawing.Size -ArgumentList 65, 26
$nudIntMax.BackColor = $ColorCardAlt
$nudIntMax.ForeColor = $ColorText
$lblIntervalDash = New-Label -Text '-' -X 320 -Y 98 -Width 12 -Height 18 -Size 9 -Color $ColorMuted

$lblJitter = New-Label -Text 'Ampiezza movimento' -X 20 -Y 137 -Width 210 -Height 22 -Size 9 -Color $ColorText
$nudJitter = New-Object System.Windows.Forms.NumericUpDown
$nudJitter.Minimum = 1
$nudJitter.Maximum = 50
$nudJitter.Value = [decimal]$Config['MaxJitterPixels']
$nudJitter.Location = New-Object System.Drawing.Point -ArgumentList 305, 134
$nudJitter.Size = New-Object System.Drawing.Size -ArgumentList 90, 26
$nudJitter.BackColor = $ColorCardAlt
$nudJitter.ForeColor = $ColorText
$lblJitterUnit = New-Label -Text 'pixel' -X 260 -Y 139 -Width 42 -Height 18 -Size 8 -Color $ColorMuted

$lblMode = New-Label -Text 'Modalita movimento' -X 20 -Y 178 -Width 210 -Height 22 -Size 9 -Color $ColorText
$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbMode.Items.AddRange(@('Visibile', 'Stealth'))
$cmbMode.SelectedIndex = if ($Config['Mode'] -eq 'stealth') { 1 } else { 0 }
$cmbMode.Location = New-Object System.Drawing.Point -ArgumentList 253, 175
$cmbMode.Size = New-Object System.Drawing.Size -ArgumentList 142, 28
$cmbMode.BackColor = $ColorCardAlt
$cmbMode.ForeColor = $ColorText

$separator = New-Object System.Windows.Forms.Panel
$separator.Location = New-Object System.Drawing.Point -ArgumentList 20, 218
$separator.Size = New-Object System.Drawing.Size -ArgumentList 375, 1
$separator.BackColor = $ColorBorder

function Update-DarkCheckBoxStyle {
    param([System.Windows.Forms.CheckBox]$CheckBox)

    $prefix = if ($CheckBox.Checked) { '[X]' } else { '[ ]' }
    $CheckBox.Text = '{0}  {1}' -f $prefix, [string]$CheckBox.Tag

    if (-not $CheckBox.Enabled) {
        $CheckBox.BackColor = $ColorCard
        $CheckBox.ForeColor = $ColorGray
        $CheckBox.FlatAppearance.BorderColor = $ColorBorder
    } elseif ($CheckBox.Checked) {
        $CheckBox.BackColor = $ColorGreenDark
        $CheckBox.ForeColor = $ColorText
        $CheckBox.FlatAppearance.BorderColor = $ColorGreen
    } else {
        $CheckBox.BackColor = $ColorCardAlt
        $CheckBox.ForeColor = $ColorText
        $CheckBox.FlatAppearance.BorderColor = $ColorGray
    }
}

function New-DarkCheckBox {
    param([string]$Text, [int]$Y, [bool]$Checked)

    $checkBox = New-Object System.Windows.Forms.CheckBox
    $checkBox.Tag = $Text
    $checkBox.Location = New-Object System.Drawing.Point -ArgumentList 20, $Y
    $checkBox.Size = New-Object System.Drawing.Size -ArgumentList 375, 28
    $checkBox.Checked = $Checked
    $checkBox.Appearance = [System.Windows.Forms.Appearance]::Button
    $checkBox.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $checkBox.FlatAppearance.BorderSize = 1
    $checkBox.FlatAppearance.MouseOverBackColor = $ColorGreenDark
    $checkBox.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $checkBox.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 10, 0, 0, 0
    $checkBox.Cursor = [System.Windows.Forms.Cursors]::Hand
    $checkBox.UseVisualStyleBackColor = $false
    $checkBox.Add_CheckedChanged({ Update-DarkCheckBoxStyle -CheckBox $this })
    $checkBox.Add_EnabledChanged({ Update-DarkCheckBoxStyle -CheckBox $this })
    Update-DarkCheckBoxStyle -CheckBox $checkBox
    return $checkBox
}

$chkMinTray = New-DarkCheckBox -Text 'Avvia minimizzato nell area di notifica' -Y 235 -Checked ([bool]$Config['StartMinimizedToTray'])
$chkMonitorTeams = New-DarkCheckBox -Text 'Monitora lo stato di Microsoft Teams' -Y 269 -Checked ([bool]$Config['MonitorTeamsPresence'])
$chkAlerts = New-DarkCheckBox -Text 'Avvisami quando Teams lascia lo stato verde' -Y 303 -Checked ([bool]$Config['AlertOnPresenceDrop'])
$chkMascot = New-DarkCheckBox -Text 'Mostra il mostriciattolo quando la protezione e attiva' -Y 337 -Checked ([bool]$Config['ShowMascotWhenRunning'])

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'SALVA IMPOSTAZIONI'
$btnSave.Location = New-Object System.Drawing.Point -ArgumentList 20, 382
$btnSave.Size = New-Object System.Drawing.Size -ArgumentList 375, 42
Set-ButtonStyle -Button $btnSave -BackColor $ColorGreenDark -ForeColor $ColorText

$lblSaveState = New-Label -Text 'Le modifiche vengono validate prima del salvataggio.' -X 20 -Y 434 -Width 375 -Height 30 -Size 8 -Color $ColorMuted
$settingsCard.Controls.AddRange(@(
    $lblIdle, $nudIdle, $lblIdleUnit,
    $lblInterval, $nudIntMin, $nudIntMax, $lblIntervalDash,
    $lblJitter, $nudJitter, $lblJitterUnit,
    $lblMode, $cmbMode, $separator,
    $chkMinTray, $chkMonitorTeams, $chkAlerts, $chkMascot,
    $btnSave, $lblSaveState
))

$lblFooter = New-Label -Text "KeepTeamsGreen $AppVersion  |  Stato Teams letto tramite Accessibilita Windows" -X 20 -Y 599 -Width 880 -Height 24 -Size 8 -Color $ColorMuted
$lblFooter.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$Form.Controls.AddRange(@($headerLogo, $lblTitle, $lblSubtitle, $lblLive, $operationsCard, $settingsCard, $lblFooter))

$ToolTip = New-Object System.Windows.Forms.ToolTip
$ToolTip.AutoPopDelay = 8000
$ToolTip.InitialDelay = 400
$ToolTip.ReshowDelay = 200
$ToolTip.SetToolTip($chkMonitorTeams, 'Teams deve esporre la presenza tramite i controlli accessibili di Windows.')
$ToolTip.SetToolTip($chkMascot, 'Mostra il logo in un piccolo widget sempre in primo piano mentre il motore e attivo.')
$ToolTip.SetToolTip($cmbMode, 'Stealth riporta il puntatore alla posizione iniziale dopo ogni micro-movimento.')
$ToolTip.SetToolTip($nudIntMin, 'Attesa minima in secondi tra due jitter.')
$ToolTip.SetToolTip($nudIntMax, 'Attesa massima in secondi tra due jitter. Imposta min e max a 3 per un intervallo fisso di 3 secondi.')

$Notify = New-Object System.Windows.Forms.NotifyIcon
$Notify.Icon = $script:AppIcon
$Notify.Visible = $true
$Notify.Text = $AppName

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $trayMenu.Items.Add('Apri centrale operativa')
$miStatus = $trayMenu.Items.Add('Stato: inizializzazione')
$miStatus.Enabled = $false
$trayMenu.Items.Add('-') | Out-Null
$miStart = $trayMenu.Items.Add('Avvia protezione')
$miStop = $trayMenu.Items.Add('Ferma protezione')
$miStop.Enabled = $false
$trayMenu.Items.Add('-') | Out-Null
$miExit = $trayMenu.Items.Add('Esci')
$Notify.ContextMenuStrip = $trayMenu

$MascotForm = New-Object PassiveOverlayForm
$MascotForm.Text = 'KeepTeamsGreen Monster'
$MascotForm.ClientSize = New-Object System.Drawing.Size -ArgumentList 148, 164
$MascotForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$MascotForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$MascotForm.ShowInTaskbar = $false
$MascotForm.TopMost = $true
$MascotForm.BackColor = $ColorCard
$MascotForm.Opacity = 0.96
$MascotForm.Icon = $script:AppIcon

$mascotPicture = New-Object System.Windows.Forms.PictureBox
$mascotPicture.Location = New-Object System.Drawing.Point -ArgumentList 8, 4
$mascotPicture.Size = New-Object System.Drawing.Size -ArgumentList 132, 128
$mascotPicture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$mascotPicture.BackColor = [System.Drawing.Color]::Transparent
if ($null -ne $script:LogoImage) { $mascotPicture.Image = $script:LogoImage }

$lblMascot = New-Label -Text 'STATO NON LETTO' -X 8 -Y 134 -Width 132 -Height 24 -Size 8 -Style ([System.Drawing.FontStyle]::Bold) -Color $ColorYellow
$lblMascot.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$lblMascot.BackColor = $ColorCardAlt
$MascotForm.Controls.AddRange(@($mascotPicture, $lblMascot))
$ToolTip.SetToolTip($mascotPicture, 'Doppio clic per aprire la centrale. Trascina per spostarmi.')

$mascotMenu = New-Object System.Windows.Forms.ContextMenuStrip
$mascotOpen = $mascotMenu.Items.Add('Apri centrale')
$mascotHide = $mascotMenu.Items.Add('Nascondi mostriciattolo')
$mascotStop = $mascotMenu.Items.Add('Ferma protezione')
$MascotForm.ContextMenuStrip = $mascotMenu
$mascotPicture.ContextMenuStrip = $mascotMenu

$script:IsRunning = $false
$script:AllowExit = $false
$script:CleanupComplete = $false
$script:NextJitterAt = $null
$script:LastJitterAt = $null
$script:JitterCount = 0
$script:CurrentIdleSeconds = 0
$script:EngineActivity = 'Inattivo'
$script:TeamsWindow = $null
$script:TeamsFocusState = 'Closed'
$script:CommittedPresence = 'Unknown'
$script:PendingPresence = $null
$script:PendingPresenceSince = $null
$script:LastReliablePresence = $null
$script:LastReliablePresenceAt = $null
$script:PresenceDiagnostic = 'In attesa del primo controllo'
$script:PresenceTask = $null
$script:PresenceTaskHandle = [IntPtr]::Zero
$script:PresenceTaskStartedAt = $null
$script:ContactTask = $null
$script:ContactTaskHandle = [IntPtr]::Zero
$script:ContactTaskStartedAt = $null
$script:ContactTaskGeneration = 0
$script:LastPresenceReadAt = $null
$script:ProbeFailureCount = 0
$script:NextPresenceProbeAt = Get-Date
$script:LastPresenceChangeAt = $null
$script:MascotDismissed = $false
$script:MascotDragging = $false
$script:MascotDragStart = $null
$script:MascotFormStart = $null

$EngineTimer = New-Object System.Windows.Forms.Timer
$EngineTimer.Interval = 1000
$OperationsTimer = New-Object System.Windows.Forms.Timer
$OperationsTimer.Interval = 1000
$AlertTimer = New-Object System.Windows.Forms.Timer
$AlertTimer.Interval = 8000

function Set-NotifyText {
    param([string]$Text)

    if ($Text.Length -gt 63) {
        $Text = $Text.Substring(0, 63)
    }
    $Notify.Text = $Text
}

function Show-StatusBanner {
    param(
        [string]$Text,
        [System.Drawing.Color]$BackColor = $ColorGreenDark,
        [int]$DurationMilliseconds = 5000
    )

    $lblAlertBanner.Text = $Text
    $lblAlertBanner.BackColor = $BackColor
    $lblAlertBanner.Visible = $true
    $AlertTimer.Stop()
    $AlertTimer.Interval = $DurationMilliseconds
    $AlertTimer.Start()
}

function Set-Timeline {
    param([string]$Text)
    $lblTimeline.Text = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Text
}

function Apply-ConfigFromUI {
    if ($nudIntMin.Value -gt $nudIntMax.Value) {
        [System.Windows.Forms.MessageBox]::Show(
            'Il tempo minimo tra i jitter non puo superare quello massimo.',
            'Impostazioni non valide',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $false
    }

    $Config['IdleThresholdSeconds'] = [int]$nudIdle.Value
    $Config['JitterIntervalSecondsMin'] = [int]$nudIntMin.Value
    $Config['JitterIntervalSecondsMax'] = [int]$nudIntMax.Value
    $Config['MaxJitterPixels'] = [int]$nudJitter.Value
    $Config['Mode'] = if ($cmbMode.SelectedIndex -eq 1) { 'stealth' } else { 'visible' }
    $Config['StartMinimizedToTray'] = [bool]$chkMinTray.Checked
    $Config['MonitorTeamsPresence'] = [bool]$chkMonitorTeams.Checked
    $Config['AlertOnPresenceDrop'] = [bool]$chkAlerts.Checked
    $Config['ShowMascotWhenRunning'] = [bool]$chkMascot.Checked
    return $true
}

function Save-SettingsFromUI {
    param([bool]$ShowConfirmation = $true)

    if (-not (Apply-ConfigFromUI)) {
        return $false
    }

    if (Save-Config) {
        $lblSaveState.Text = 'Impostazioni salvate correttamente alle ' + (Get-Date).ToString('HH:mm:ss')
        $lblSaveState.ForeColor = $ColorGreen
        if ($ShowConfirmation) {
            Show-StatusBanner -Text 'Impostazioni salvate' -BackColor $ColorGreenDark -DurationMilliseconds 3500
        }
        if ($script:IsRunning) {
            Update-MascotVisibility
        }
        return $true
    }

    $lblSaveState.Text = 'Salvataggio fallito: ' + $script:LastConfigError
    $lblSaveState.ForeColor = $ColorRed
    if ($ShowConfirmation) {
        [System.Windows.Forms.MessageBox]::Show(
            "Impossibile salvare le impostazioni.`r`n`r`n$($script:LastConfigError)`r`n`r`nPercorso: $ConfigPath",
            'Errore di salvataggio',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    return $false
}

function Test-IsTeamsSnapshot {
    param($Snapshot)

    if ($null -eq $Snapshot) { return $false }
    $processName = [string]$Snapshot.ProcessName
    $title = [string]$Snapshot.Title
    if ($processName -match '^(?i:teams|ms-teams|msteams)$') {
        return $true
    }
    if ($processName -match '^(?i:msedge|chrome|firefox|brave|opera)$' -and $title -match '(?i:Microsoft Teams|Teams \|)') {
        return $true
    }
    return $false
}

function Get-TeamsWindow {
    try {
        $windows = [Win32Window]::GetVisibleWindows()
        foreach ($window in $windows) {
            if (Test-IsTeamsSnapshot $window) {
                return $window
            }
        }
    } catch {
        Write-AppLog ("Rilevamento finestra Teams fallito: {0}" -f $_.Exception.Message)
    }
    return $null
}

function Get-PresenceDisplayName {
    param([string]$State)

    switch ($State) {
        'Available' { return 'Disponibile' }
        'Away'      { return 'Assente' }
        'Busy'      { return 'Occupato' }
        'Dnd'       { return 'Non disturbare' }
        'BusyOrDnd' { return 'Rosso (Occupato / Non disturbare)' }
        'Offline'   { return 'Offline' }
        'Closed'    { return 'Teams chiuso' }
        'Disabled'  { return 'Monitor disattivato' }
        default     { return 'Non rilevato' }
    }
}

function Show-PresenceDropAlert {
    param([string]$NewState)

    $display = Get-PresenceDisplayName $NewState
    $message = "Teams non e piu verde. Stato rilevato: $display."
    Set-Timeline $message
    Show-StatusBanner -Text $message -BackColor $ColorRed -DurationMilliseconds 10000
    Show-LocalNotification -Title 'Cambio stato Teams' -Message $message
    Write-AppLog ("ALERT: presenza Teams Available -> {0}" -f $NewState)
}

function Commit-Presence {
    param([string]$State)

    if ([string]::IsNullOrWhiteSpace($State)) { $State = 'Unknown' }
    $now = Get-Date
    if ($State -in @('Disabled', 'Unknown')) {
        if ($State -eq 'Disabled') {
            $script:LastReliablePresence = $null
            $script:LastReliablePresenceAt = $null
        }
        $changed = $State -ne $script:CommittedPresence
        $script:CommittedPresence = $State
        $script:PendingPresence = $null
        $script:PendingPresenceSince = $null
        if ($changed) { Set-Timeline (Get-PresenceDisplayName $State) }
        return
    }

    # A brief unavailable UIA read is not a new baseline. Keep the last reliable
    # state for at most 20s, but always display Unknown while data is missing.
    $previous = $script:LastReliablePresence
    if ($null -eq $script:LastReliablePresenceAt -or ($now - $script:LastReliablePresenceAt).TotalSeconds -gt 20) { $previous = $null }
    if ($State -eq $previous) {
        $script:CommittedPresence = $State
        $script:LastReliablePresenceAt = $now
        $script:PendingPresence = $null
        $script:PendingPresenceSince = $null
        return
    }

    if ($State -ne $script:PendingPresence) {
        $script:PendingPresence = $State
        $script:PendingPresenceSince = $now
        if ($previous -eq 'Available') { return }
    }

    $minimumSeconds = if ($State -eq 'Closed') { 5 } else { 2 }
    if ($previous -eq 'Available' -and ($now - $script:PendingPresenceSince).TotalSeconds -lt $minimumSeconds) { return }

    $script:CommittedPresence = $State
    $script:LastReliablePresence = $State
    $script:LastReliablePresenceAt = $now
    $script:PendingPresence = $null
    $script:PendingPresenceSince = $null
    $script:LastPresenceChangeAt = $now
    Set-Timeline ("Stato Teams: {0}" -f (Get-PresenceDisplayName $State))
    Write-AppLog ("Presenza Teams: {0} -> {1}" -f $previous, $State)

    if ($previous -eq 'Available' -and $State -notin @('Available', 'Unknown', 'Disabled') -and [bool]$Config['AlertOnPresenceDrop']) {
        Show-PresenceDropAlert -NewState $State
    }
    if ($State -eq 'Away') { Request-TeamsAutoFocus -Reason 'Away' }
    if ($previous -eq 'Available' -and $State -eq 'Away' -and -not [bool]$Config['AutoFocusEnabled']) { Invoke-AwayRecovery }
}

function Start-PresenceProbe {
    param([IntPtr]$WindowHandle)

    if (-not $script:UIAutomationAvailable) {
        $script:PresenceDiagnostic = 'Accessibilita Windows non disponibile'
        Commit-Presence -State 'Unknown'
        $script:NextPresenceProbeAt = (Get-Date).AddSeconds(10)
        return
    }

    try {
        $script:PresenceTaskHandle = $WindowHandle
        $script:ProbeGeneration = $script:LocalGeneration
        $script:PresenceTaskStartedAt = Get-Date
        $script:PresenceTask = [KeepTeamsGreenMonitoring.TeamsPresenceProbe]::BeginInspect($WindowHandle, [string[]]@())
        $script:NextPresenceProbeAt = (Get-Date).AddSeconds(2)
    } catch {
        $script:PresenceDiagnostic = $_.Exception.Message
        $script:PresenceTask = $null
        $script:NextPresenceProbeAt = (Get-Date).AddSeconds(10)
        Write-LocalError -Code 'UIA_START' -Detail $_.Exception.GetType().Name
    }
}

function Receive-PresenceProbe {
    if ($null -eq $script:PresenceTask) { return }
    if (-not $script:PresenceTask.IsCompleted) {
        if ($null -ne $script:PresenceTaskStartedAt -and ((Get-Date) - $script:PresenceTaskStartedAt).TotalSeconds -gt 12) {
            $script:PresenceDiagnostic = 'Lettura Teams in timeout; attesa del provider Windows'
            Commit-Presence -State 'Unknown'
            Write-LocalError -Code 'UIA_TIMEOUT' -Detail 'Provider senza risposta; nessun nuovo worker avviato'
        }
        return
    }

    try {
        if ($script:PresenceTask.IsFaulted) {
            $script:ProbeFailureCount = [Math]::Min(5, $script:ProbeFailureCount + 1)
            $script:PresenceDiagnostic = 'Lettura presenza non riuscita'
            Commit-Presence -State 'Unknown'
            Write-LocalError -Code 'UIA_READ' -Detail 'Lettura asincrona fallita'
        } else {
            $result = $script:PresenceTask.Result
            if ($null -ne $script:TeamsWindow -and $script:TeamsWindow.Handle -eq $script:PresenceTaskHandle) {
                $script:PresenceDiagnostic = [string]$result.Diagnostic
                if (((Get-Date) - $script:PresenceTaskStartedAt).TotalSeconds -le 12 -and $script:ProbeGeneration -eq $script:LocalGeneration) {
                    $script:LastPresenceReadAt = Get-Date
                    if ([bool]$Config['MonitorTeamsPresence']) {
                        Commit-Presence -State ([string]$result.State)
                        Observe-AutoFocusPresence ([string]$result.State)
                    }
                    Complete-AwayRecovery ([string]$result.State)
                    if ($result.Diagnostic -like 'Lettura accessibilita fallita*') {
                        $script:ProbeFailureCount = [Math]::Min(5, $script:ProbeFailureCount + 1)
                        Write-LocalError -Code 'UIA_READ' -Detail 'Provider Windows non disponibile'
                    } else { $script:ProbeFailureCount = 0 }
                } else {
                    Commit-Presence -State 'Unknown'
                }
            }
        }
    } catch {
        $script:ProbeFailureCount = [Math]::Min(5, $script:ProbeFailureCount + 1)
        $script:PresenceDiagnostic = $_.Exception.Message
        Commit-Presence -State 'Unknown'
        Write-LocalError -Code 'UIA_READ' -Detail $_.Exception.GetType().Name
    } finally {
        $script:PresenceTask = $null
        $script:PresenceTaskHandle = [IntPtr]::Zero
        $script:PresenceTaskStartedAt = $null
        if ($script:ProbeFailureCount -gt 0) {
            $script:NextPresenceProbeAt = (Get-Date).AddSeconds([Math]::Min(120, 5 * [Math]::Pow(2, $script:ProbeFailureCount)))
        }
    }
}

function Update-ContactProbe {
    # A slow colleague tree must never delay or overwrite the personal reader.
    if ($null -ne $script:ContactTask) {
        if (-not $script:ContactTask.IsCompleted) {
            if (((Get-Date) - $script:ContactTaskStartedAt).TotalSeconds -gt 12) {
                Write-LocalError 'UIA_CONTACT_TIMEOUT' 'Provider contatti occupato; nessun worker duplicato'
            }
            return
        }
        try {
            if ($script:ContactTask.IsFaulted) { Write-LocalError 'UIA_CONTACT_READ' 'Lettura contatti fallita' }
            elseif ($script:ContactTaskGeneration -eq $script:LocalGeneration -and $null -ne $script:TeamsWindow -and
                $script:ContactTaskHandle -eq $script:TeamsWindow.Handle -and
                ((Get-Date) - $script:ContactTaskStartedAt).TotalSeconds -le 12) {
                $script:ContactDiagnostic = [string]$script:ContactTask.Result.Diagnostic
                Receive-ContactReadings $script:ContactTask.Result.Contacts
            }
        } catch { Write-LocalError 'UIA_CONTACT_READ' $_.Exception.GetType().Name }
        finally { $script:ContactTask = $null }
    }
    if (-not $script:UIAutomationAvailable) { return }
    $names = @(Get-DueContactNames)
    if ($names.Count -eq 0) { return }
    try {
        $script:ContactTaskHandle = $script:TeamsWindow.Handle
        $script:ContactTaskGeneration = $script:LocalGeneration
        $script:ContactTaskStartedAt = Get-Date
        $script:ContactTask = [KeepTeamsGreenMonitoring.TeamsPresenceProbe]::BeginInspectContacts($script:TeamsWindow.Handle, [string[]]$names, [bool]$Config['ColleagueReadVisibleBadges'])
    } catch { Write-LocalError 'UIA_CONTACT_START' $_.Exception.GetType().Name }
}

function Update-TeamsMonitor {
    try {
        if (-not [Win32Window]::IsDesktopUnlocked()) {
            $script:PresenceDiagnostic = 'Monitor sospeso: Windows bloccato'
            Commit-Presence -State 'Unknown'
            return
        }
        $oldHandle = if ($null -ne $script:TeamsWindow) { $script:TeamsWindow.Handle } else { [IntPtr]::Zero }
        $script:TeamsWindow = Get-TeamsWindow
        if ($null -ne $script:TeamsWindow -and $oldHandle -ne $script:TeamsWindow.Handle) {
            $script:LastReliablePresence = $null
            $script:LastReliablePresenceAt = $null
            $script:LastPresenceReadAt = $null
            $script:NextPresenceProbeAt = Get-Date
            Commit-Presence 'Unknown'
        }
        $foreground = [Win32Window]::GetForegroundSnapshot()

        if ($null -eq $script:TeamsWindow) {
            if ($null -ne $script:PresenceTask -and $script:PresenceTask.IsCompleted) {
                $script:PresenceTask = $null
                $script:PresenceTaskHandle = [IntPtr]::Zero
            }
            $script:TeamsFocusState = 'Closed'
            $script:PresenceDiagnostic = 'Nessuna finestra Teams rilevata'
            Commit-Presence -State 'Closed'
            return
        }
        if ($null -ne $script:LastPresenceReadAt -and ((Get-Date) - $script:LastPresenceReadAt).TotalSeconds -gt 20) {
            Commit-Presence -State 'Unknown'
        }

        if (Test-IsTeamsSnapshot $foreground) {
            $script:TeamsFocusState = 'Focused'
        } else {
            $script:TeamsFocusState = 'Background'
        }

        if (-not [bool]$Config['MonitorTeamsPresence']) {
            $script:PresenceDiagnostic = 'Monitor disattivato nelle impostazioni'
            Commit-Presence -State 'Disabled'
            if (-not [bool]$Config['MonitorColleagues']) { return }
        }

        if ([bool]$Config['MonitorTeamsPresence']) { Receive-PresenceProbe }
        if ([bool]$Config['MonitorTeamsPresence'] -and $null -eq $script:PresenceTask -and (Get-Date) -ge $script:NextPresenceProbeAt) {
            Start-PresenceProbe -WindowHandle $script:TeamsWindow.Handle
        }
        Update-ContactProbe
    } catch {
        $script:PresenceDiagnostic = $_.Exception.Message
        Write-LocalError -Code 'MONITOR' -Detail $_.Exception.GetType().Name
    }
}

function Set-RowState {
    param(
        $Row,
        [string]$Value,
        [string]$Detail,
        [System.Drawing.Color]$Color
    )

    $Row.Dot.BackColor = $Color
    $Row.Value.Text = $Value
    $Row.Value.ForeColor = $Color
    $Row.Detail.Text = $Detail
}

function Get-TimeText {
    param($DateValue)
    if ($null -eq $DateValue) { return '-' }
    return $DateValue.ToString('HH:mm:ss')
}

function Update-MascotStatus {
    if (-not $script:IsRunning) {
        $lblMascot.Text = 'KTG IN PAUSA'
        $lblMascot.ForeColor = $ColorMuted
        return
    }
    if (Get-EnginePauseReason) {
        $lblMascot.Text = 'KTG IN ATTESA'
        $lblMascot.ForeColor = $ColorYellow
        return
    }

    switch ($script:CommittedPresence) {
        'Available' {
            $lblMascot.Text = 'GREEN OK'
            $lblMascot.ForeColor = $ColorGreen
        }
        { $_ -in @('Away', 'Busy', 'Dnd', 'Offline', 'Closed') } {
            $lblMascot.Text = 'CHECK TEAMS'
            $lblMascot.ForeColor = $ColorRed
        }
        default {
            $lblMascot.Text = if ($script:CommittedPresence -eq 'Disabled') { 'MONITOR SPENTO' } else { 'STATO NON LETTO' }
            $lblMascot.ForeColor = $ColorYellow
        }
    }
}

function Show-Mascot {
    if ($script:MascotDismissed -or -not $script:IsRunning -or -not [bool]$Config['ShowMascotWhenRunning']) {
        return
    }
    if (-not $MascotForm.Visible) {
        Update-MascotAppearance -Scale $Config['MascotScalePercent'] -Opacity $Config['MascotOpacityPercent']
        $cursor = Get-CursorPoint
        $screen = [System.Windows.Forms.Screen]::FromPoint($cursor)
        $workingArea = $screen.WorkingArea
        $MascotForm.Location = New-Object System.Drawing.Point -ArgumentList ($workingArea.Right - $MascotForm.Width - 18), ($workingArea.Bottom - $MascotForm.Height - 18)
        $MascotForm.Show()
    }
    Update-MascotStatus
}

function Update-MascotVisibility {
    if ($script:IsRunning -and [bool]$Config['ShowMascotWhenRunning'] -and -not $script:MascotDismissed) {
        Show-Mascot
    } else {
        $MascotForm.Hide()
    }
}

function Update-Dashboard {
    if ($script:IsRunning) {
        $detail = "Idle: $($script:CurrentIdleSeconds)s  |  soglia: $($Config['IdleThresholdSeconds'])s"
        $pauseReason = Get-EnginePauseReason
        if ($pauseReason) {
            Set-RowState -Row $rowEngine -Value 'IN ATTESA' -Detail $pauseReason -Color $ColorYellow
        } else {
            Set-RowState -Row $rowEngine -Value 'PROTEZIONE ATTIVA' -Detail $detail -Color $ColorGreen
        }
    } else {
        Set-RowState -Row $rowEngine -Value 'IN PAUSA' -Detail 'Premi Avvia protezione per iniziare' -Color $ColorGray
    }

    switch ($script:CommittedPresence) {
        'Available' {
            $detail = if ($script:IsRunning) { 'Verde confermato; protezione attiva' } else { 'Verde confermato; protezione in pausa' }
            Set-RowState -Row $rowTeams -Value 'VERDE CONFERMATO' -Detail $detail -Color $ColorGreen
        }
        'Away' { Set-RowState -Row $rowTeams -Value 'ASSENTE' -Detail $script:PresenceDiagnostic -Color $ColorYellow }
        'Busy' { Set-RowState -Row $rowTeams -Value 'OCCUPATO' -Detail $script:PresenceDiagnostic -Color $ColorOrange }
        'Dnd' { Set-RowState -Row $rowTeams -Value 'NON DISTURBARE' -Detail $script:PresenceDiagnostic -Color $ColorRed }
        'Offline' { Set-RowState -Row $rowTeams -Value 'OFFLINE' -Detail $script:PresenceDiagnostic -Color $ColorRed }
        'Closed' { Set-RowState -Row $rowTeams -Value 'TEAMS CHIUSO' -Detail 'Nessuna finestra Teams rilevata' -Color $ColorGray }
        'Disabled' { Set-RowState -Row $rowTeams -Value 'MONITOR SPENTO' -Detail 'Attivalo nelle impostazioni' -Color $ColorGray }
        default { Set-RowState -Row $rowTeams -Value 'NON RILEVATO' -Detail $script:PresenceDiagnostic -Color $ColorBlue }
    }

    switch ($script:TeamsFocusState) {
        'Focused' { Set-RowState -Row $rowFocus -Value 'IN PRIMO PIANO' -Detail 'La finestra attiva appartiene a Teams' -Color $ColorGreen }
        'Background' { Set-RowState -Row $rowFocus -Value 'IN BACKGROUND' -Detail 'Teams e aperto ma non ha il focus' -Color $ColorYellow }
        default { Set-RowState -Row $rowFocus -Value 'NON APERTO' -Detail 'Nessuna finestra Teams rilevata' -Color $ColorGray }
    }

    if ($script:IsRunning -and $pauseReason) {
        Set-RowState -Row $rowActivity -Value 'SOSPESO' -Detail $pauseReason -Color $ColorYellow
    } elseif ($script:IsRunning -and $script:TeamsJitterHandle -ne [IntPtr]::Zero -and -not [Win32Window]::IsForeground($script:TeamsJitterHandle)) {
        Set-RowState -Row $rowActivity -Value 'ATTESA TEAMS' -Detail 'Jitter limitato a Teams; riprendi il focus per continuare' -Color $ColorYellow
    } elseif (-not $script:IsRunning) {
        Set-RowState -Row $rowActivity -Value 'FERMO' -Detail 'Nessun movimento automatico' -Color $ColorGray
    } elseif ($script:CurrentIdleSeconds -lt [int]$Config['IdleThresholdSeconds']) {
        $lastText = Get-TimeText $script:LastJitterAt
        Set-RowState -Row $rowActivity -Value 'UTENTE ATTIVO' -Detail "Ultimo jitter: $lastText  |  totali: $($script:JitterCount)" -Color $ColorGreen
    } else {
        $nextText = Get-TimeText $script:NextJitterAt
        Set-RowState -Row $rowActivity -Value 'AUTO-JITTER' -Detail "Prossimo: $nextText  |  totali: $($script:JitterCount)" -Color $ColorBlue
    }

    $btnStart.Enabled = -not $script:IsRunning
    $canStop = $script:IsRunning -or ([bool]$Config['AutoFocusEnabled'] -and -not $script:AutoFocusSuppressed)
    $btnStop.Enabled = $canStop
    $btnStop.BackColor = if ($canStop) { $ColorRed } else { $ColorCardAlt }
    $btnStop.ForeColor = if ($canStop) { $ColorText } else { $ColorMuted }
    $miStart.Enabled = -not $script:IsRunning
    $miStop.Enabled = $canStop
    $miStatus.Text = if ($script:IsRunning) { 'Stato: protezione attiva' } else { 'Stato: in pausa' }
    $notificationText = if ($script:IsRunning) { 'KeepTeamsGreen - Protezione attiva' } else { 'KeepTeamsGreen - In pausa' }
    Set-NotifyText -Text $notificationText
    Update-MascotStatus
}

function Start-Engine {
    param([switch]$UseSavedConfig)
    if ($script:IsRunning) { return }
    if (-not $UseSavedConfig -and -not (Apply-ConfigFromUI)) { return }
    if (-not $UseSavedConfig -and -not (Save-SettingsFromUI -ShowConfirmation $false)) {
        [System.Windows.Forms.MessageBox]::Show(
            "La protezione puo partire, ma le impostazioni non sono state salvate.`r`n$($script:LastConfigError)",
            'KeepTeamsGreen',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }

    $script:IsRunning = $true
    $script:AutoFocusSuppressed = $false
    $script:NextJitterAt = $null
    $script:EngineActivity = 'In ascolto'
    $script:MascotDismissed = $false
    $EngineTimer.Start()
    Set-Timeline 'Protezione avviata'
    Show-StatusBanner -Text 'Protezione attiva' -BackColor $ColorGreenDark -DurationMilliseconds 3500
    Write-AppLog 'Motore avviato.'
    Update-MascotVisibility
    Update-Dashboard
}

function Stop-Engine {
    $script:AutoFocusSuppressed = $true
    $script:TeamsJitterHandle = [IntPtr]::Zero
    $script:AutoFocusRequest = $null
    if ($null -ne $script:PendingFocusAction) { $script:FocusActionStatus = 'Autofocus annullato da Stop' }
    $script:PendingFocusAction = $null
    $script:ManualFocusPending = $false
    if (-not $script:IsRunning) { Update-Dashboard; return }
    $script:IsRunning = $false
    $script:NextJitterAt = $null
    $script:EngineActivity = 'Inattivo'
    $EngineTimer.Stop()
    $MascotForm.Hide()
    Set-Timeline 'Protezione fermata'
    Write-AppLog 'Motore fermato.'
    Update-Dashboard
}

function Show-ControlPanel {
    $Form.ShowInTaskbar = $true
    $Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    if (-not $Form.Visible) {
        $Form.Show()
    }
    $Form.BringToFront()
    $Form.Activate()
}

function Hide-ControlPanel {
    param([bool]$ShowHint = $false)

    $Form.Hide()
    $Form.ShowInTaskbar = $false
    if ($ShowHint) {
        try {
            Show-LocalNotification -Title 'KeepTeamsGreen' -Message 'Il tool continua a funzionare nell area di notifica.' -Silent
        } catch { }
    }
}

function Cleanup-Application {
    if ($script:CleanupComplete) { return }
    $script:CleanupComplete = $true
    try { Close-InteractionResources } catch { }
    try { if ($null -ne $LocalForm) { $LocalForm.Dispose() } } catch { }
    try { $EngineTimer.Stop() } catch { }
    try { $OperationsTimer.Stop() } catch { }
    try { $AlertTimer.Stop() } catch { }
    try { $MascotForm.Hide(); $MascotForm.Dispose() } catch { }
    try { $Notify.Visible = $false; $Notify.Dispose() } catch { }
    try { $trayMenu.Dispose(); $mascotMenu.Dispose(); $ToolTip.Dispose() } catch { }
    try {
        if ($null -ne $script:LogoImage) { $script:LogoImage.Dispose() }
        if ($script:OwnsAppIcon -and $null -ne $script:AppIcon) { $script:AppIcon.Dispose() }
    } catch { }
    Write-AppLog 'Applicazione chiusa.'
}

function Exit-Application {
    if ($script:AllowExit) { return }
    $script:AllowExit = $true
    if ($script:IsRunning) { Stop-Engine }
    try { $Form.Close() } catch { }
    Cleanup-Application
    [System.Windows.Forms.Application]::ExitThread()
}

$EngineTimer.Add_Tick({
    if (-not $script:IsRunning) { return }
    try {
        $pauseReason = Get-EnginePauseReason
        if ($pauseReason) {
            $script:NextJitterAt = $null
            $script:EngineActivity = $pauseReason
            return
        }
        $script:CurrentIdleSeconds = Get-IdleSeconds
        $threshold = [int]$Config['IdleThresholdSeconds']

        if ($script:CurrentIdleSeconds -lt $threshold) {
            $script:NextJitterAt = $null
            $script:EngineActivity = 'Utente attivo'
            return
        }
        if ($script:TeamsJitterHandle -ne [IntPtr]::Zero -and -not [Win32Window]::IsForeground($script:TeamsJitterHandle)) {
            $script:NextJitterAt = $null
            return
        }

        if ($null -eq $script:NextJitterAt) {
            $waitSeconds = Get-Random -Minimum ([int]$Config['JitterIntervalSecondsMin']) -Maximum ([int]$Config['JitterIntervalSecondsMax'] + 1)
            $script:NextJitterAt = (Get-Date).AddSeconds($waitSeconds)
            $script:EngineActivity = 'Auto-jitter in attesa'
            return
        }

        if ((Get-Date) -ge $script:NextJitterAt) {
            if (-not (Invoke-ScopedJitter)) { $script:NextJitterAt = $null; return }
            $script:LastJitterAt = Get-Date
            $script:JitterCount++
            $waitSeconds = Get-Random -Minimum ([int]$Config['JitterIntervalSecondsMin']) -Maximum ([int]$Config['JitterIntervalSecondsMax'] + 1)
            $script:NextJitterAt = (Get-Date).AddSeconds($waitSeconds)
            $script:EngineActivity = 'Auto-jitter eseguito'
            Set-Timeline ("Jitter #{0} eseguito" -f $script:JitterCount)
        }
    } catch {
        Write-LocalError -Code 'ENGINE' -Detail $_.Exception.GetType().Name
        Show-StatusBanner -Text 'Errore nel motore: controlla il log' -BackColor $ColorRed -DurationMilliseconds 8000
    }
})

$OperationsTimer.Add_Tick({
    try {
        if ($script:IsRunning) {
            $script:CurrentIdleSeconds = Get-IdleSeconds
        }
        Update-TeamsMonitor
        Update-LocalOperations
        Update-Dashboard
    } catch {
        Write-LocalError -Code 'DASHBOARD' -Detail $_.Exception.GetType().Name
    }
})

$AlertTimer.Add_Tick({
    $AlertTimer.Stop()
    $lblAlertBanner.Visible = $false
})

$btnStart.Add_Click({ Start-Engine })
$btnStop.Add_Click({ Stop-Engine })
$btnSave.Add_Click({ Save-SettingsFromUI -ShowConfirmation $true | Out-Null })
$chkMonitorTeams.Add_CheckedChanged({ $chkAlerts.Enabled = $chkMonitorTeams.Checked })

$miShow.Add_Click({ Show-ControlPanel })
$miStart.Add_Click({ Start-Engine })
$miStop.Add_Click({ Stop-Engine })
$miExit.Add_Click({ Exit-Application })
$Notify.Add_DoubleClick({ Show-ControlPanel })

$mascotOpen.Add_Click({ Show-ControlPanel })
$mascotHide.Add_Click({
    $script:MascotDismissed = $true
    $MascotForm.Hide()
})
$mascotStop.Add_Click({ Stop-Engine })
$MascotForm.Add_DoubleClick({ Show-ControlPanel })
$mascotPicture.Add_DoubleClick({ Show-ControlPanel })

$mascotPicture.Add_MouseDown({
    param($eventSource, $mouseEvent)
    $null = $eventSource
    if ($mouseEvent.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:MascotDragging = $true
        $script:MascotDragStart = [System.Windows.Forms.Cursor]::Position
        $script:MascotFormStart = $MascotForm.Location
    }
})
$mascotPicture.Add_MouseMove({
    param($eventSource, $mouseEvent)
    $null = $eventSource
    $null = $mouseEvent
    if ($script:MascotDragging) {
        $current = [System.Windows.Forms.Cursor]::Position
        $MascotForm.Location = New-Object System.Drawing.Point -ArgumentList (
            $script:MascotFormStart.X + $current.X - $script:MascotDragStart.X
        ), (
            $script:MascotFormStart.Y + $current.Y - $script:MascotDragStart.Y
        )
    }
})
$mascotPicture.Add_MouseUp({ $script:MascotDragging = $false })

$Form.Add_Resize({
    if ($Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        Hide-ControlPanel
    }
})

$Form.Add_FormClosing({
    param($eventSource, $closingEvent)
    $null = $eventSource
    if (-not $script:AllowExit -and $closingEvent.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $closingEvent.Cancel = $true
        Hide-ControlPanel -ShowHint $true
    } elseif (-not $script:AllowExit) {
        $script:AllowExit = $true
        Cleanup-Application
    }
})

$Form.Add_FormClosed({
    Cleanup-Application
    [System.Windows.Forms.Application]::ExitThread()
})

. ([scriptblock]::Create((Get-AppResourceText 'local/Operations.ps1')))
. ([scriptblock]::Create((Get-AppResourceText 'local/Interactions.ps1')))
Initialize-LocalOperations

$chkAlerts.Enabled = $chkMonitorTeams.Checked
if ($script:LastConfigError) {
    $lblSaveState.Text = $script:LastConfigError
    $lblSaveState.ForeColor = $ColorYellow
}

Write-AppLog ("Avvio KeepTeamsGreen {0}." -f $AppVersion)
$OperationsTimer.Start()
Update-TeamsMonitor
Update-Dashboard

if ([bool]$Config['StartMinimizedToTray']) {
    $Form.ShowInTaskbar = $false
} else {
    Show-ControlPanel
}

try {
    Show-LocalNotification -Title 'KeepTeamsGreen' -Message 'Centrale operativa pronta. Avvia la protezione quando vuoi.' -Silent
} catch { }

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    Cleanup-Application
}
