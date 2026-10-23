#Requires -Version 5.1
# Run with powershell.exe -NoProfile -STA -File .\tests\Smoke-Windows.ps1
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Usa Windows PowerShell 5.1 con -STA.'
}
$project = Split-Path $PSScriptRoot -Parent
$originalAppData = $env:APPDATA
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ktg-windows-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testDirectory) | Out-Null
try {
    $env:APPDATA = $testDirectory
    $source = [IO.File]::ReadAllText((Join-Path $project 'script.gui.ps1'))
    # Exercise the real controls and handlers in an isolated config directory.
    $checks = @'
        $LocalForm.Show($Form)
        [System.Windows.Forms.Application]::DoEvents()
        if ($contactGrid.Columns.Count -ne 8) { throw 'Griglia incompleta' }
        if ($LocalForm.Controls[0].TabPages.Count -ne 5) { throw 'Schede impostazioni mancanti' }
        $nudMascotScale.Value = 150
        $nudMascotOpacity.Value = 50
        if ($MascotForm.Opacity -ne 0.5 -or $MascotForm.ClientSize.Width -ne 264) { throw 'Anteprima widget non applicata' }
        $contactGrid.Rows.Add([object[]]@($true, 'Test Person', 'Available', 'Everyday', '00:00', '00:00', '-', '-')) | Out-Null
        $chkLocalContacts.Checked = $true
        Save-LocalOptions
        if (@($Config['Colleagues']).Count -ne 1) { throw 'Salvataggio contatti non riuscito' }
        if ($Config['MascotScalePercent'] -ne 150 -or $Config['MascotOpacityPercent'] -ne 50) { throw 'Salvataggio widget non riuscito' }
        Update-MascotQuickMenu
        if ($QuickContactItems[0].Text -notlike 'Test Person*') { throw 'Menu rapido contatti non aggiornato' }
        $chkLocalContacts.Checked = $false
        if ($chkLocalContacts.Text -notlike '[[] []]*') { throw 'Toggle non aggiornato' }
        Update-Dashboard
        Update-LocalOperations
        Show-LocalNotification -Title 'Collaudo popup' -Message 'Notifica di test senza suono.' -Silent
        [System.Windows.Forms.Application]::DoEvents()
        if (-not $NotificationForm.Visible -or $notificationTitle.Text -ne 'Collaudo popup') { throw 'Popup locale non visibile' }
        $script:AllowExit = $true
        $LocalForm.Close()
        $Form.Close()
        Write-Output 'PASS: Windows Forms initialization, toggles, contacts, widget preview, quick menu, save, dashboard, silent popup, close. Audio not tested.'
'@
    $source = $source.Replace('[System.Windows.Forms.Application]::Run()', $checks)
    $source = $source.Replace('$BaseDir = $PSScriptRoot', ('$BaseDir = ' + "'" + $project.Replace("'", "''") + "'"))
    $result = @(& ([scriptblock]::Create($source)))
    if (-not ($result -match '^PASS: Windows Forms')) { throw 'Il collaudo non e arrivato alla verifica finale. Controllare il messaggio di avvio.' }
    $result
} finally {
    $env:APPDATA = $originalAppData
    [IO.Directory]::Delete($testDirectory, $true)
}
