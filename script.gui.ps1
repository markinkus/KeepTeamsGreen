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
$AppVersion = '2.1.1'
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

function Write-AppLog {
    param([string]$Message)

    try {
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
"@
Add-Type -TypeDefinition $win32Source

$script:UIAutomationAvailable = $false
$presenceProbeSource = @"
using System;
using System.Threading.Tasks;
using System.Windows.Automation;

public sealed class PresenceProbeResult {
    public string State { get; set; }
    public string Diagnostic { get; set; }
}

public static class TeamsPresenceProbe {
    private static bool Has(string text, string value) {
        return text.IndexOf(value, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static string Classify(string text) {
        if (Has(text, "do not disturb") || Has(text, "non disturbare")) {
            return "Dnd";
        }
        if (Has(text, "offline") || Has(text, "non in linea") || Has(text, "appear offline")) {
            return "Offline";
        }
        if (Has(text, "busy") || Has(text, "occupato") || Has(text, "appear busy") || Has(text, "in a call") || Has(text, "in a meeting")) {
            return "Busy";
        }
        if (Has(text, "away") || Has(text, "assente") || Has(text, "be right back") || Has(text, "torno subito")) {
            return "Away";
        }
        if (Has(text, "available") || Has(text, "disponibile")) {
            return "Available";
        }
        return null;
    }

    private static bool LooksLikeAccountControl(string text, string automationId) {
        string combined = text + " " + automationId;
        return Has(combined, "account") || Has(combined, "profile") ||
               Has(combined, "avatar") || Has(combined, "presence") ||
               Has(combined, "availability") || Has(combined, "profilo") ||
               Has(combined, "gestione account") || Has(combined, "me-control") ||
               Has(combined, "personbutton");
    }

    public static PresenceProbeResult Inspect(IntPtr windowHandle) {
        PresenceProbeResult result = new PresenceProbeResult {
            State = "Unknown",
            Diagnostic = "Stato non esposto da Teams"
        };

        try {
            AutomationElement root = AutomationElement.FromHandle(windowHandle);
            if (root == null) {
                result.Diagnostic = "Finestra Teams non accessibile";
                return result;
            }

            System.Windows.Rect windowRect = root.Current.BoundingRectangle;
            AutomationElementCollection elements = root.FindAll(TreeScope.Descendants, Condition.TrueCondition);
            int bestScore = -1;
            string bestState = null;

            for (int index = 0; index < elements.Count && index < 3000; index++) {
                try {
                    AutomationElement element = elements[index];
                    string name = element.Current.Name ?? String.Empty;
                    string help = element.Current.HelpText ?? String.Empty;
                    string automationId = element.Current.AutomationId ?? String.Empty;
                    string content = name + " " + help;
                    string state = Classify(content);
                    if (state == null) {
                        continue;
                    }

                    int score = 0;
                    if (LooksLikeAccountControl(content, automationId)) {
                        score += 100;
                    }

                    System.Windows.Rect elementRect = element.Current.BoundingRectangle;
                    if (!windowRect.IsEmpty && !elementRect.IsEmpty) {
                        bool inHeader = elementRect.Top <= windowRect.Top + 180;
                        bool onRight = elementRect.Left >= windowRect.Left + (windowRect.Width * 0.45);
                        if (inHeader && onRight) {
                            score += 70;
                        } else if (inHeader) {
                            score += 20;
                        }
                    }

                    ControlType type = element.Current.ControlType;
                    if (type == ControlType.Button || type == ControlType.Image) {
                        score += 15;
                    }
                    if (String.Equals(name.Trim(), "Available", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name.Trim(), "Disponibile", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name.Trim(), "Away", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name.Trim(), "Assente", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name.Trim(), "Busy", StringComparison.OrdinalIgnoreCase) ||
                        String.Equals(name.Trim(), "Occupato", StringComparison.OrdinalIgnoreCase)) {
                        score += 10;
                    }

                    if (score >= 60 && score > bestScore) {
                        bestScore = score;
                        bestState = state;
                    }
                } catch { }
            }

            if (bestState != null) {
                result.State = bestState;
                result.Diagnostic = "Stato letto dai controlli accessibili di Teams";
            }
        } catch (Exception exception) {
            result.Diagnostic = exception.Message;
        }
        return result;
    }

    public static Task<PresenceProbeResult> BeginInspect(IntPtr windowHandle) {
        return Task.Factory.StartNew<PresenceProbeResult>(delegate {
            return Inspect(windowHandle);
        });
    }
}
"@

try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName WindowsBase
    $uiaReferences = @(
        [System.Windows.Automation.AutomationElement].Assembly.Location,
        [System.Windows.Automation.AutomationIdentifier].Assembly.Location,
        [System.Windows.Rect].Assembly.Location
    ) | Select-Object -Unique
    Add-Type -TypeDefinition $presenceProbeSource -ReferencedAssemblies $uiaReferences
    $script:UIAutomationAvailable = $true
} catch {
    Write-AppLog ("UI Automation non disponibile: {0}" -f $_.Exception.Message)
}

$ConfigDefaults = [ordered]@{
    SchemaVersion               = 4
    IdleThresholdSeconds        = 120
    JitterIntervalSecondsMin    = 3
    JitterIntervalSecondsMax    = 3
    MaxJitterPixels             = 5
    Mode                        = 'visible'
    StartMinimizedToTray        = $false
    MonitorTeamsPresence        = $true
    AlertOnPresenceDrop         = $true
    ShowMascotWhenRunning       = $false
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
    $Config['SchemaVersion'] = 4
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

$MascotForm = New-Object System.Windows.Forms.Form
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

$lblMascot = New-Label -Text 'KTG ATTIVO' -X 8 -Y 134 -Width 132 -Height 24 -Size 8 -Style ([System.Drawing.FontStyle]::Bold) -Color $ColorGreen
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
$script:PresenceDiagnostic = 'In attesa del primo controllo'
$script:PresenceTask = $null
$script:PresenceTaskHandle = [IntPtr]::Zero
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
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    try {
        $Notify.ShowBalloonTip(
            7000,
            'KeepTeamsGreen - Cambio stato Teams',
            $message,
            [System.Windows.Forms.ToolTipIcon]::Warning
        )
    } catch { }
    Write-AppLog ("ALERT: presenza Teams Available -> {0}" -f $NewState)
}

function Commit-Presence {
    param([string]$State)

    if ([string]::IsNullOrWhiteSpace($State)) { $State = 'Unknown' }
    if ($State -eq $script:CommittedPresence) {
        $script:PendingPresence = $null
        $script:PendingPresenceSince = $null
        return
    }

    if ($State -eq 'Disabled') {
        $previous = $script:CommittedPresence
        $script:CommittedPresence = 'Disabled'
        $script:PendingPresence = $null
        $script:PendingPresenceSince = $null
        Set-Timeline 'Monitor Teams disattivato'
        Write-AppLog ("Presenza Teams: {0} -> Disabled" -f $previous)
        return
    }

    $now = Get-Date
    if ($State -ne $script:PendingPresence) {
        $script:PendingPresence = $State
        $script:PendingPresenceSince = $now

        # The first reliable reading is safe to expose immediately. A drop from
        # green is confirmed by a second reading (or a few seconds of closure).
        if ($script:CommittedPresence -ne 'Available') {
            $oldState = $script:CommittedPresence
            $script:CommittedPresence = $State
            $script:LastPresenceChangeAt = $now
            Set-Timeline ("Stato Teams: {0}" -f (Get-PresenceDisplayName $State))
            Write-AppLog ("Presenza Teams: {0} -> {1}" -f $oldState, $State)
        }
        return
    }

    $minimumSeconds = if ($State -eq 'Closed') { 5 } else { 4 }
    if (($now - $script:PendingPresenceSince).TotalSeconds -lt $minimumSeconds) {
        return
    }

    $previous = $script:CommittedPresence
    $script:CommittedPresence = $State
    $script:PendingPresence = $null
    $script:PendingPresenceSince = $null
    $script:LastPresenceChangeAt = $now
    Set-Timeline ("Stato Teams: {0}" -f (Get-PresenceDisplayName $State))
    Write-AppLog ("Presenza Teams: {0} -> {1}" -f $previous, $State)

    if ($previous -eq 'Available' -and $State -notin @('Available', 'Unknown', 'Disabled') -and [bool]$Config['AlertOnPresenceDrop']) {
        Show-PresenceDropAlert -NewState $State
    }
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
        $script:PresenceTask = [TeamsPresenceProbe]::BeginInspect($WindowHandle)
        $script:NextPresenceProbeAt = (Get-Date).AddSeconds(6)
    } catch {
        $script:PresenceDiagnostic = $_.Exception.Message
        $script:PresenceTask = $null
        $script:NextPresenceProbeAt = (Get-Date).AddSeconds(10)
        Write-AppLog ("Avvio lettura presenza fallito: {0}" -f $_.Exception.Message)
    }
}

function Receive-PresenceProbe {
    if ($null -eq $script:PresenceTask -or -not $script:PresenceTask.IsCompleted) {
        return
    }

    try {
        if ($script:PresenceTask.IsFaulted) {
            $script:PresenceDiagnostic = 'Lettura presenza non riuscita'
            Commit-Presence -State 'Unknown'
        } else {
            $result = $script:PresenceTask.Result
            if ($null -ne $script:TeamsWindow -and $script:TeamsWindow.Handle -eq $script:PresenceTaskHandle) {
                $script:PresenceDiagnostic = [string]$result.Diagnostic
                Commit-Presence -State ([string]$result.State)
            }
        }
    } catch {
        $script:PresenceDiagnostic = $_.Exception.Message
        Commit-Presence -State 'Unknown'
        Write-AppLog ("Lettura presenza fallita: {0}" -f $_.Exception.Message)
    } finally {
        $script:PresenceTask = $null
        $script:PresenceTaskHandle = [IntPtr]::Zero
    }
}

function Update-TeamsMonitor {
    try {
        $script:TeamsWindow = Get-TeamsWindow
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

        if (Test-IsTeamsSnapshot $foreground) {
            $script:TeamsFocusState = 'Focused'
        } else {
            $script:TeamsFocusState = 'Background'
        }

        if (-not [bool]$Config['MonitorTeamsPresence']) {
            $script:PresenceDiagnostic = 'Monitor disattivato nelle impostazioni'
            Commit-Presence -State 'Disabled'
            return
        }

        Receive-PresenceProbe
        if ($null -eq $script:PresenceTask -and (Get-Date) -ge $script:NextPresenceProbeAt) {
            Start-PresenceProbe -WindowHandle $script:TeamsWindow.Handle
        }
    } catch {
        $script:PresenceDiagnostic = $_.Exception.Message
        Write-AppLog ("Monitor Teams: {0}" -f $_.Exception.Message)
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
            $lblMascot.Text = 'KTG ATTIVO'
            $lblMascot.ForeColor = $ColorGreen
        }
    }
}

function Show-Mascot {
    if ($script:MascotDismissed -or -not $script:IsRunning -or -not [bool]$Config['ShowMascotWhenRunning']) {
        return
    }
    if (-not $MascotForm.Visible) {
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
        Set-RowState -Row $rowEngine -Value 'PROTEZIONE ATTIVA' -Detail $detail -Color $ColorGreen
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

    if (-not $script:IsRunning) {
        Set-RowState -Row $rowActivity -Value 'FERMO' -Detail 'Nessun movimento automatico' -Color $ColorGray
    } elseif ($script:CurrentIdleSeconds -lt [int]$Config['IdleThresholdSeconds']) {
        $lastText = Get-TimeText $script:LastJitterAt
        Set-RowState -Row $rowActivity -Value 'UTENTE ATTIVO' -Detail "Ultimo jitter: $lastText  |  totali: $($script:JitterCount)" -Color $ColorGreen
    } else {
        $nextText = Get-TimeText $script:NextJitterAt
        Set-RowState -Row $rowActivity -Value 'AUTO-JITTER' -Detail "Prossimo: $nextText  |  totali: $($script:JitterCount)" -Color $ColorBlue
    }

    $btnStart.Enabled = -not $script:IsRunning
    $btnStop.Enabled = $script:IsRunning
    $btnStop.BackColor = if ($script:IsRunning) { $ColorRed } else { $ColorCardAlt }
    $btnStop.ForeColor = if ($script:IsRunning) { $ColorText } else { $ColorMuted }
    $miStart.Enabled = -not $script:IsRunning
    $miStop.Enabled = $script:IsRunning
    $miStatus.Text = if ($script:IsRunning) { 'Stato: protezione attiva' } else { 'Stato: in pausa' }
    $notificationText = if ($script:IsRunning) { 'KeepTeamsGreen - Protezione attiva' } else { 'KeepTeamsGreen - In pausa' }
    Set-NotifyText -Text $notificationText
    Update-MascotStatus
}

function Start-Engine {
    if ($script:IsRunning) { return }
    if (-not (Save-SettingsFromUI -ShowConfirmation $false)) {
        [System.Windows.Forms.MessageBox]::Show(
            "La protezione puo partire, ma le impostazioni non sono state salvate.`r`n$($script:LastConfigError)",
            'KeepTeamsGreen',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }

    $script:IsRunning = $true
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
    if (-not $script:IsRunning) { return }
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
            $Notify.ShowBalloonTip(
                2500,
                'KeepTeamsGreen',
                'Il tool continua a funzionare nell area di notifica.',
                [System.Windows.Forms.ToolTipIcon]::Info
            )
        } catch { }
    }
}

function Cleanup-Application {
    if ($script:CleanupComplete) { return }
    $script:CleanupComplete = $true
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
        $script:CurrentIdleSeconds = Get-IdleSeconds
        $threshold = [int]$Config['IdleThresholdSeconds']

        if ($script:CurrentIdleSeconds -lt $threshold) {
            $script:NextJitterAt = $null
            $script:EngineActivity = 'Utente attivo'
            return
        }

        if ($null -eq $script:NextJitterAt) {
            $waitSeconds = Get-Random -Minimum ([int]$Config['JitterIntervalSecondsMin']) -Maximum ([int]$Config['JitterIntervalSecondsMax'] + 1)
            $script:NextJitterAt = (Get-Date).AddSeconds($waitSeconds)
            $script:EngineActivity = 'Auto-jitter in attesa'
            return
        }

        if ((Get-Date) -ge $script:NextJitterAt) {
            Invoke-Jitter -Mode ([string]$Config['Mode']) -MaximumPixels ([int]$Config['MaxJitterPixels'])
            $script:LastJitterAt = Get-Date
            $script:JitterCount++
            $waitSeconds = Get-Random -Minimum ([int]$Config['JitterIntervalSecondsMin']) -Maximum ([int]$Config['JitterIntervalSecondsMax'] + 1)
            $script:NextJitterAt = (Get-Date).AddSeconds($waitSeconds)
            $script:EngineActivity = 'Auto-jitter eseguito'
            Set-Timeline ("Jitter #{0} eseguito" -f $script:JitterCount)
        }
    } catch {
        Write-AppLog ("Errore motore: {0}" -f $_.Exception.Message)
        Show-StatusBanner -Text 'Errore nel motore: controlla il log' -BackColor $ColorRed -DurationMilliseconds 8000
    }
})

$OperationsTimer.Add_Tick({
    try {
        if ($script:IsRunning) {
            $script:CurrentIdleSeconds = Get-IdleSeconds
        }
        Update-TeamsMonitor
        Update-Dashboard
    } catch {
        Write-AppLog ("Aggiornamento dashboard fallito: {0}" -f $_.Exception.Message)
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
    $Notify.ShowBalloonTip(
        2500,
        'KeepTeamsGreen',
        'Centrale operativa pronta. Avvia la protezione quando vuoi.',
        [System.Windows.Forms.ToolTipIcon]::Info
    )
} catch { }

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    Cleanup-Application
}
