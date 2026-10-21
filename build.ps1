#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SigningCertificateThumbprint,
    [string]$TimestampServer
)

$ErrorActionPreference = 'Stop'

$projectDir = $PSScriptRoot
$scriptPath = Join-Path $projectDir 'script.gui.ps1'
$logoPath = Join-Path $projectDir 'logo.png'
$iconPath = Join-Path $projectDir 'KeepTeamsGreen.ico'
$outputPath = Join-Path $projectDir 'KeepTeamsGreen.exe'
$nextOutputPath = Join-Path $projectDir 'KeepTeamsGreen.next.exe'
$backupPath = Join-Path $projectDir 'KeepTeamsGreen.previous.exe'
$launcherProject = Join-Path $projectDir 'launcher\KeepTeamsGreen.Launcher.csproj'
$localFiles = @('local/Rules.ps1', 'local/Operations.ps1', 'local/PresenceText.cs', 'local/PresenceReader.cs')

foreach ($requiredPath in @($scriptPath, $logoPath, $iconPath, $launcherProject)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "File richiesto non trovato: $requiredPath"
    }
}
foreach ($relativePath in $localFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectDir $relativePath) -PathType Leaf)) { throw "Risorsa richiesta mancante: $relativePath" }
}

$parseTokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$parseTokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    $details = ($parseErrors | ForEach-Object { "riga $($_.Extent.StartLineNumber): $($_.Message)" }) -join [Environment]::NewLine
    throw "Il sorgente contiene errori di sintassi:$([Environment]::NewLine)$details"
}
foreach ($relativePath in @('local/Rules.ps1', 'local/Operations.ps1')) {
    $moduleTokens = $null; $moduleErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectDir $relativePath), [ref]$moduleTokens, [ref]$moduleErrors) | Out-Null
    if ($moduleErrors.Count -gt 0) { throw "Errori di sintassi in $relativePath : $($moduleErrors[0].Message)" }
}
& (Join-Path $projectDir 'tests/Test-LocalRules.ps1')

$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -eq $dotnetCommand) {
    throw 'SDK .NET non trovato. Installa .NET SDK 8 o successivo per eseguire la build.'
}

$temporaryDir = Join-Path ([System.IO.Path]::GetTempPath()) ("KeepTeamsGreen-build-{0}" -f $PID)
$buildOutputDir = Join-Path $temporaryDir 'output'
New-Item -ItemType Directory -Path $temporaryDir -Force | Out-Null

try {
    if (Test-Path -LiteralPath $nextOutputPath) {
        Remove-Item -LiteralPath $nextOutputPath -Force
    }

    & $dotnetCommand.Path build `
        $launcherProject `
        --configuration Release `
        --output $buildOutputDir `
        --nologo `
        "-p:ApplicationIcon=$iconPath"
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build terminata con codice $LASTEXITCODE."
    }

    $builtExecutable = Join-Path $buildOutputDir 'KeepTeamsGreen.exe'
    if (-not (Test-Path -LiteralPath $builtExecutable -PathType Leaf) -or (Get-Item -LiteralPath $builtExecutable).Length -eq 0) {
        throw 'La build non ha prodotto un eseguibile valido.'
    }
    Copy-Item -LiteralPath $builtExecutable -Destination $nextOutputPath -Force

    if (-not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
        $signCommand = Get-Command Set-AuthenticodeSignature -ErrorAction SilentlyContinue
        if ($null -eq $signCommand) {
            throw 'La firma Authenticode e disponibile solo durante una build eseguita su Windows.'
        }

        $normalizedThumbprint = $SigningCertificateThumbprint -replace '\s', ''
        $certificate = $null
        foreach ($storePath in @(
            "Cert:\CurrentUser\My\$normalizedThumbprint",
            "Cert:\LocalMachine\My\$normalizedThumbprint"
        )) {
            if (Test-Path -LiteralPath $storePath) {
                $certificate = Get-Item -LiteralPath $storePath
                break
            }
        }

        if ($null -eq $certificate) {
            throw "Certificato di firma non trovato: $normalizedThumbprint"
        }
        if (-not $certificate.HasPrivateKey) {
            throw 'Il certificato selezionato non contiene una chiave privata utilizzabile per la firma.'
        }

        $signatureParameters = @{
            LiteralPath  = $nextOutputPath
            Certificate  = $certificate
            HashAlgorithm = 'SHA256'
            IncludeChain = 'All'
        }
        if (-not [string]::IsNullOrWhiteSpace($TimestampServer)) {
            $signatureParameters['TimestampServer'] = $TimestampServer
        }

        $signature = Set-AuthenticodeSignature @signatureParameters
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "Firma Authenticode non valida: $($signature.StatusMessage)"
        }
        Write-Host "Firma Authenticode valida: $($certificate.Subject)" -ForegroundColor Green
    } else {
        Write-Warning 'EXE non firmato: Windows mostrera Autore sconosciuto finche non viene fornito un certificato code-signing attendibile.'
    }

    if (Test-Path -LiteralPath $outputPath) {
        Copy-Item -LiteralPath $outputPath -Destination $backupPath -Force
    }
    Move-Item -LiteralPath $nextOutputPath -Destination $outputPath -Force
    Write-Host "Build completata: $outputPath" -ForegroundColor Green
    if (Test-Path -LiteralPath $backupPath) {
        Write-Host "Versione precedente conservata in: $backupPath" -ForegroundColor DarkGray
    }
} finally {
    if (Test-Path -LiteralPath $nextOutputPath) {
        Remove-Item -LiteralPath $nextOutputPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $temporaryDir) {
        Remove-Item -LiteralPath $temporaryDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
