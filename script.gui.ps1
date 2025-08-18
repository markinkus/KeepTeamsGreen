#Requires -Version 5.1
# Bootstrap robusto per GUI WinForms (ASCII-safe)
$ErrorActionPreference = 'Stop'

# 1) Forza Windows PowerShell Desktop
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $self = "`"$PSCommandPath`""
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File $self" -WindowStyle Normal
    exit
}

# 2) Forza STA per WinForms
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $self = "`"$PSCommandPath`""
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File $self" -WindowStyle Normal
    exit
}

# 3) Logging
$LogDir  = Join-Path $env:APPDATA "KeepTeamsGreen"
$LogPath = Join-Path $LogDir "last_run.log"
if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
try { Stop-Transcript | Out-Null } catch {}
try { Start-Transcript -Path $LogPath -Append | Out-Null } catch {}

# 4) Unblock (best effort)
try { Unblock-File -Path $PSCommandPath -ErrorAction SilentlyContinue } catch {}

# 5) Trap globale
trap {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show($_.ToString(), "Errore script", 'OK', 'Error') | Out-Null
    } catch {}
    try { Stop-Transcript | Out-Null } catch {}
    break
}

# === GUI e logica ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# WinAPI
$signature = @"
using System;
using System.Runtime.InteropServices;

public static class Win32Idle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll")]
    static extern uint GetTickCount();

    public static uint GetIdleTimeMs() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) {
            return 0;
        }
        return GetTickCount() - lii.dwTime;
    }
}

public static class Win32Cursor {
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);
}
"@
Add-Type $signature

# Config storage
$ConfigDir  = Join-Path $env:APPDATA "KeepTeamsGreen"
$ConfigPath = Join-Path $ConfigDir "config.json"
if (!(Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }

$Config = [ordered]@{
    IdleThresholdSeconds        = 120
    JitterIntervalSecondsMin    = 20
    JitterIntervalSecondsMax    = 45
    MaxJitterPixels             = 5
    Mode                        = "visible"   # or "stealth"
    StartMinimizedToTray        = $false
}

function Load-Config {
    if (Test-Path $ConfigPath) {
        try {
            $json = Get-Content $ConfigPath -Raw -ErrorAction Stop
            $obj = $json | ConvertFrom-Json
            foreach ($k in $Config.Keys) {
                if ($obj.PSObject.Properties.Name -contains $k) {
                    $Config[$k] = $obj.$k
                }
            }
        } catch { }
    }
}
function Save-Config {
    try { $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8 } catch { }
}
Load-Config

# Helpers
function Get-IdleSeconds { [math]::Round([Win32Idle]::GetIdleTimeMs() / 1000.0, 0) }
function Get-CursorPoint {
    $pt = New-Object Win32Cursor+POINT
    [Win32Cursor]::GetCursorPos([ref]$pt) | Out-Null
    return (New-Object System.Drawing.Point -ArgumentList $pt.X, $pt.Y)
}
function Set-CursorPoint([System.Drawing.Point]$p) { [Win32Cursor]::SetCursorPos([int]$p.X, [int]$p.Y) | Out-Null }
function Get-VirtualBounds { [System.Windows.Forms.SystemInformation]::VirtualScreen }
function Clamp-ToBounds([System.Drawing.Point]$p, $rect) {
    $x = [Math]::Min([Math]::Max($p.X, $rect.X), $rect.X + $rect.Width - 1)
    $y = [Math]::Min([Math]::Max($p.Y, $rect.Y), $rect.Y + $rect.Height - 1)
    return (New-Object System.Drawing.Point -ArgumentList $x, $y)
}
function Get-RandomJitter([int]$maxAbs) {
    $dx = Get-Random -Minimum (-1 * $maxAbs) -Maximum ($maxAbs + 1)
    $dy = Get-Random -Minimum (-1 * $maxAbs) -Maximum ($maxAbs + 1)
    return ,@($dx, $dy)
}
function Do-VisibleJitterStep([int]$maxJitterPx) {
    $bounds = Get-VirtualBounds
    $cur = Get-CursorPoint
    $j = Get-RandomJitter -maxAbs $maxJitterPx
    $new = New-Object System.Drawing.Point ($cur.X + $j[0]), ($cur.Y + $j[1])
    $new = Clamp-ToBounds $new $bounds
    Set-CursorPoint $new
}
function Do-StealthJitterStep([int]$maxJitterPx) {
    $bounds = Get-VirtualBounds
    $start = Get-CursorPoint
    $j = Get-RandomJitter -maxAbs $maxJitterPx
    $temp = New-Object System.Drawing.Point ($start.X + $j[0]), ($start.Y + $j[1])
    $temp = Clamp-ToBounds $temp $bounds
    Set-CursorPoint $temp
    Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 26)
    Set-CursorPoint $start
}

# Stato runtime
$IsRunning = $false
$NextJitterAt = $null

# UI
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "KeepTeamsGreen - Control Panel"
$Form.Size = New-Object System.Drawing.Size(470, 360)
$Form.StartPosition = "CenterScreen"
$Form.MaximizeBox = $false

$lblIdle    = New-Object System.Windows.Forms.Label
$lblIdle.Text = "Soglia inattivita (s):"
$lblIdle.Location = New-Object System.Drawing.Point(20, 20)
$lblIdle.AutoSize = $true

$nudIdle = New-Object System.Windows.Forms.NumericUpDown
$nudIdle.Minimum = 5
$nudIdle.Maximum = 3600
$nudIdle.Value   = [decimal]$Config.IdleThresholdSeconds
$nudIdle.Location = New-Object System.Drawing.Point(180, 18)
$nudIdle.Size = New-Object System.Drawing.Size(80, 24)

$lblInterval = New-Object System.Windows.Forms.Label
$lblInterval.Text = "Intervallo jitter (s): min / max"
$lblInterval.Location = New-Object System.Drawing.Point(20, 60)
$lblInterval.AutoSize = $true

$nudIntMin = New-Object System.Windows.Forms.NumericUpDown
$nudIntMin.Minimum = 5
$nudIntMin.Maximum = 600
$nudIntMin.Value   = [decimal]$Config.JitterIntervalSecondsMin
$nudIntMin.Location = New-Object System.Drawing.Point(220, 58)
$nudIntMin.Size = New-Object System.Drawing.Size(60, 24)

$nudIntMax = New-Object System.Windows.Forms.NumericUpDown
$nudIntMax.Minimum = 5
$nudIntMax.Maximum = 600
$nudIntMax.Value   = [decimal]$Config.JitterIntervalSecondsMax
$nudIntMax.Location = New-Object System.Drawing.Point(290, 58)
$nudIntMax.Size = New-Object System.Drawing.Size(60, 24)

$lblJitter = New-Object System.Windows.Forms.Label
$lblJitter.Text = "Ampiezza jitter (pixel, +/-):"
$lblJitter.Location = New-Object System.Drawing.Point(20, 100)
$lblJitter.AutoSize = $true

$nudJitter = New-Object System.Windows.Forms.NumericUpDown
$nudJitter.Minimum = 1
$nudJitter.Maximum = 50
$nudJitter.Value   = [decimal]$Config.MaxJitterPixels
$nudJitter.Location = New-Object System.Drawing.Point(220, 98)
$nudJitter.Size = New-Object System.Drawing.Size(60, 24)

$lblMode = New-Object System.Windows.Forms.Label
$lblMode.Text = "Modalita:"
$lblMode.Location = New-Object System.Drawing.Point(20, 140)
$lblMode.AutoSize = $true

$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.DropDownStyle = "DropDownList"
$cmbMode.Items.AddRange(@("visible","stealth"))
$cmbMode.SelectedItem = $Config.Mode
$cmbMode.Location = New-Object System.Drawing.Point(220, 138)
$cmbMode.Size = New-Object System.Drawing.Size(130, 24)

$chkMinTray = New-Object System.Windows.Forms.CheckBox
$chkMinTray.Text = "Avvia minimizzato su Tray"
$chkMinTray.Location = New-Object System.Drawing.Point(20, 175)
$chkMinTray.AutoSize = $true
$chkMinTray.Checked = [bool]$Config.StartMinimizedToTray

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Start"
$btnStart.Location = New-Object System.Drawing.Point(20, 215)
$btnStart.Size = New-Object System.Drawing.Size(100, 35)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Stop"
$btnStop.Location = New-Object System.Drawing.Point(130, 215)
$btnStop.Size = New-Object System.Drawing.Size(100, 35)
$btnStop.Enabled = $false

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "Salva impostazioni"
$btnSave.Location = New-Object System.Drawing.Point(240, 215)
$btnSave.Size = New-Object System.Drawing.Size(160, 35)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Stato: Inattivo"
$lblStatus.Location = New-Object System.Drawing.Point(20, 265)
$lblStatus.AutoSize = $true
$lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)

$lblNext = New-Object System.Windows.Forms.Label
$lblNext.Text = "Prossimo jitter: -"
$lblNext.Location = New-Object System.Drawing.Point(20, 290)
$lblNext.AutoSize = $true

$Form.Controls.AddRange(@(
    $lblIdle, $nudIdle, 
    $lblInterval, $nudIntMin, $nudIntMax,
    $lblJitter, $nudJitter,
    $lblMode, $cmbMode,
    $chkMinTray,
    $btnStart, $btnStop, $btnSave,
    $lblStatus, $lblNext
))

# Tray
$Notify = New-Object System.Windows.Forms.NotifyIcon
$Notify.Icon = [System.Drawing.SystemIcons]::Application
$Notify.Visible = $true
$Notify.Text = "KeepTeamsGreen"
$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $ctx.Items.Add("Apri pannello")
$miStart = $ctx.Items.Add("Start")
$miStop  = $ctx.Items.Add("Stop")
$ctx.Items.Add("-") | Out-Null
$miExit  = $ctx.Items.Add("Esci")
$Notify.ContextMenuStrip = $ctx
$Notify.add_DoubleClick({ $Form.Show(); $Form.WindowState = "Normal"; $Form.Activate() })

# Timers
$IdleTimer = New-Object System.Windows.Forms.Timer
$IdleTimer.Interval = 1000
$TickTimer = New-Object System.Windows.Forms.Timer
$TickTimer.Interval = 1000
$remainingWait = 0

# Logica
function Apply-ConfigFromUI {
    if ($nudIntMin.Value -gt $nudIntMax.Value) {
        [System.Windows.Forms.MessageBox]::Show("Intervallo jitter: Min non puo superare Max.","Config non valida",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return $false
    }
    $Config.IdleThresholdSeconds     = [int]$nudIdle.Value
    $Config.JitterIntervalSecondsMin = [int]$nudIntMin.Value
    $Config.JitterIntervalSecondsMax = [int]$nudIntMax.Value
    $Config.MaxJitterPixels          = [int]$nudJitter.Value
    $Config.Mode                     = [string]$cmbMode.SelectedItem
    $Config.StartMinimizedToTray     = [bool]$chkMinTray.Checked
    return $true
}
function Update-StatusText([string]$text,[string]$next="-") {
    $lblStatus.Text = "Stato: $text"
    $lblNext.Text   = "Prossimo jitter: $next"
    $Notify.Text    = "KeepTeamsGreen - $text"
}

function Start-Engine {
    if (-not (Apply-ConfigFromUI)) { return }
    Save-Config
    $script:IsRunning = $true
    $btnStart.Enabled = $false
    $btnStop.Enabled  = $true
    Update-StatusText "In ascolto (idle > $($Config.IdleThresholdSeconds)s per attivarsi)"
    $IdleTimer.Start()
}

function Stop-Engine {
    $script:IsRunning = $false
    $IdleTimer.Stop()
    $TickTimer.Stop()
    $script:NextJitterAt = $null
    $btnStart.Enabled = $true
    $btnStop.Enabled  = $false
    Update-StatusText "Inattivo"
}

$IdleTimer.Add_Tick({
    if (-not $script:IsRunning) { return }
    $idle = Get-IdleSeconds

    if ($idle -ge $Config.IdleThresholdSeconds) {
        if ($remainingWait -le 0) {
            $remainingWait = Get-Random -Minimum $Config.JitterIntervalSecondsMin -Maximum ($Config.JitterIntervalSecondsMax + 1)
            $script:NextJitterAt = (Get-Date).AddSeconds($remainingWait)
            $TickTimer.Start()
        }
        $nextTxt = if ($script:NextJitterAt) { $script:NextJitterAt.ToString("HH:mm:ss") } else { "-" }
        Update-StatusText "AFK: attivo auto-jitter", $nextTxt
    } else {
        if ($TickTimer.Enabled) { $TickTimer.Stop() }
        $remainingWait = 0
        $script:NextJitterAt = $null
        Update-StatusText "Utente attivo"
    }
})

$TickTimer.Add_Tick({
    if (-not $script:IsRunning) { $TickTimer.Stop(); return }
    $idle = Get-IdleSeconds
    if ($idle -lt $Config.IdleThresholdSeconds) {
        $TickTimer.Stop()
        $remainingWait = 0
        $script:NextJitterAt = $null
        Update-StatusText "Utente attivo"
        return
    }

    $remainingWait -= 1
    if ($remainingWait -le 0) {
        if ($Config.Mode -eq "stealth") {
            Do-StealthJitterStep -maxJitterPx $Config.MaxJitterPixels
        } else {
            Do-VisibleJitterStep -maxJitterPx $Config.MaxJitterPixels
        }
        $remainingWait = Get-Random -Minimum $Config.JitterIntervalSecondsMin -Maximum ($Config.JitterIntervalSecondsMax + 1)
        $script:NextJitterAt = (Get-Date).AddSeconds($remainingWait)
        $nextTxt = if ($script:NextJitterAt) { $script:NextJitterAt.ToString("HH:mm:ss") } else { "-" }
        Update-StatusText "AFK: attivo auto-jitter", $nextTxt
    } else {
        if ($script:NextJitterAt) {
            $lblNext.Text = "Prossimo jitter: $($script:NextJitterAt.ToString("HH:mm:ss"))"
        }
    }
})

# Eventi
$btnStart.Add_Click({ Start-Engine })
$btnStop.Add_Click({ Stop-Engine })
$btnSave.Add_Click({
    if (Apply-ConfigFromUI) { Save-Config; [System.Windows.Forms.MessageBox]::Show("Impostazioni salvate.","OK",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null }
})
$miShow.Add_Click({ $Form.Show(); $Form.WindowState = "Normal"; $Form.Activate() })
$miStart.Add_Click({ if ($btnStart.Enabled) { Start-Engine } })
$miStop.Add_Click({ if ($btnStop.Enabled)  { Stop-Engine  } })
$miExit.Add_Click({
    Stop-Engine
    $Notify.Visible = $false
    $Form.Close()
})

$Form.Add_FormClosing({ $Notify.Visible = $false })
$Form.add_FormClosing({
    if ($_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $_.Cancel = $true
        $Form.Hide()
        $Notify.ShowBalloonTip(1000, "KeepTeamsGreen", "In esecuzione in tray. Click per riaprire.", [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

# Avvio UI
if ($Config.StartMinimizedToTray) {
    $Form.WindowState = "Minimized"
    $Form.ShowInTaskbar = $false
    $Form.Hide()
} else {
    $Form.Show()
}
$Notify.ShowBalloonTip(1000, "KeepTeamsGreen", "Pannello avviato. Usa Start per attivare l'auto-jitter.", [System.Windows.Forms.ToolTipIcon]::None)
[System.Windows.Forms.Application]::Run($Form)
