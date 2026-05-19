<#
    .SYNOPSIS
    Automatisation du ricing de Windows Terminal (basé sur la vidéo de SleepyCatHey).

    .PARAMETER Uninstall
    Restaure settings.json depuis la dernière sauvegarde et retire fastfetch du profil PowerShell.

    .EXAMPLE
    .\Better-CMD.ps1

    .EXAMPLE
    .\Better-CMD.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch]$Uninstall
)

# Affichage UTF-8 (accents français dans la console)
$utf8Console = [System.Text.UTF8Encoding]::new($false)
try {
    [Console]::OutputEncoding = $utf8Console
    [Console]::InputEncoding = $utf8Console
    $OutputEncoding = $utf8Console
    if ($Host.Name -eq 'ConsoleHost') {
        & "$env:SystemRoot\System32\chcp.com" 65001 | Out-Null
    }
} catch {
    # Console non interactive : on continue
}

$ProjectRoot = $PSScriptRoot
if (-not $ProjectRoot) {
    $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$BackupRoot = Join-Path $env:USERPROFILE '.better-cmd-backups'
$FastfetchMarker = '# Auto-start Fastfetch (Better CMD)'

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "[*] $Message" -ForegroundColor $Color
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Get-WindowsTerminalLocalState {
    $packages = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages') -Filter 'Microsoft.WindowsTerminal_*' -Directory -ErrorAction SilentlyContinue
    if (-not $packages) {
        return $null
    }
    return Join-Path $packages[0].FullName 'LocalState'
}

function Update-ShellPath {
    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if ((Test-Path $windowsApps) -and ($env:Path -notlike "*$windowsApps*")) {
        $env:Path = "$windowsApps;$env:Path"
    }
}

function Get-WingetPath {
    Update-ShellPath
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'),
        (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe')
    )

    foreach ($pattern in $candidates) {
        $resolved = Resolve-Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolved) {
            return $resolved.Path
        }
    }

    return $null
}

function Install-WingetAppInstaller {
    Write-Step "Téléchargement de App Installer (winget)..."

    $tempDir = Join-Path $env:TEMP "Better-CMD-winget"
    if (-not (Test-Path $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }

    $bundlePath = Join-Path $tempDir 'Microsoft.DesktopAppInstaller.msixbundle'

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'Better-CMD' }
        $asset = $release.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1

        if (-not $asset) {
            Write-Warn "Paquet winget introuvable sur GitHub. Essayez Better-CMD.bat ou installez App Installer depuis le Microsoft Store."
            return $false
        }

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $bundlePath -UseBasicParsing
    } catch {
        Write-Warn "Échec du téléchargement de winget : $($_.Exception.Message)"
        return $false
    }

    Write-Step "Installation de App Installer..."
    try {
        Add-AppxPackage -Path $bundlePath -ErrorAction Stop
    } catch {
        Write-Warn "Échec de l'installation App Installer : $($_.Exception.Message)"
        Write-Warn "Relancez Better-CMD.bat (droits administrateur) puis réessayez."
        return $false
    }

    Start-Sleep -Seconds 2
    Update-ShellPath

    if (Get-WingetPath) {
        Write-Ok "winget installé avec succès."
        return $true
    }

    Write-Warn "App Installer installé mais winget introuvable. Fermez cette fenêtre, rouvrez Better-CMD.bat et réessayez."
    return $false
}

function Ensure-Winget {
    if (Get-WingetPath) {
        Write-Ok "winget est disponible."
        return $true
    }

    Write-Warn "winget introuvable sur ce PC."
    return Install-WingetAppInstaller
}

function Invoke-Winget {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    $wingetPath = Get-WingetPath
    if (-not $wingetPath) {
        throw "winget n'est pas disponible."
    }

    & $wingetPath @ArgumentList
    return $LASTEXITCODE
}

function Install-FastfetchPackage {
    if (Get-Command fastfetch -ErrorAction SilentlyContinue) {
        Write-Ok "Fastfetch est déjà installé."
        return $true
    }

    if (-not (Get-WingetPath)) {
        Write-Warn "Fastfetch non installé (winget indisponible). Installez-le manuellement : https://github.com/fastfetch-cli/fastfetch"
        return $false
    }

    Write-Step "Installation de Fastfetch via winget..."
    $exitCode = Invoke-Winget -ArgumentList @(
        'install',
        '--id', 'Fastfetch-cli.Fastfetch',
        '--exact',
        '--accept-source-agreements',
        '--accept-package-agreements'
    )

    if ($exitCode -eq 0 -or (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
        Write-Ok "Fastfetch installé."
        return $true
    }

    Write-Warn "L'installation de Fastfetch via winget a échoué (code $exitCode)."
    return $false
}

function Get-FontRegistrySuffix {
    param([string]$Extension)
    switch ($Extension.ToLowerInvariant()) {
        '.otf' { return '(OpenType)' }
        default { return '(TrueType)' }
    }
}

function Notify-WindowsFontChange {
    param([string[]]$FontPaths = @())

    if (-not ('BetterCmdNativeFonts' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BetterCmdNativeFonts {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int AddFontResourceW(string lpFileName);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
'@ -ErrorAction SilentlyContinue
    }

    if ('BetterCmdNativeFonts' -as [type]) {
        foreach ($path in $FontPaths) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                [BetterCmdNativeFonts]::AddFontResourceW($path) | Out-Null
            }
        }
        # WM_FONTCHANGE — rafraîchit la liste des polices pour les applications ouvertes
        [BetterCmdNativeFonts]::SendMessage([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    }
}

function Install-UserFonts {
    param([string]$SourceFolder)

    if (-not (Test-Path -LiteralPath $SourceFolder)) {
        Write-Warn "Dossier fonts/ introuvable : '$SourceFolder'"
        return $false
    }

    $fontFiles = @(
        Get-ChildItem -Path $SourceFolder -Include '*.ttf', '*.otf' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName
    )

    if ($fontFiles.Count -eq 0) {
        Write-Warn "Aucun fichier .ttf/.otf dans '$SourceFolder'. Ajoutez vos polices dans fonts/."
        return $false
    }

    Write-Step "$($fontFiles.Count) fichier(s) de police trouvé(s) dans fonts/ (installation automatique)..."

    $fontFolder = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (-not (Test-Path $fontFolder)) {
        New-Item -Path $fontFolder -ItemType Directory -Force | Out-Null
    }

    $registryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    $installed = 0
    $skipped = 0
    $updated = 0
    $newlyLoaded = [System.Collections.Generic.List[string]]::new()
    $seenNames = @{}

    $index = 0
    foreach ($font in $fontFiles) {
        $index++
        if ($fontFiles.Count -gt 20 -and ($index % 25 -eq 0 -or $index -eq $fontFiles.Count)) {
            Write-Host "    ... $index / $($fontFiles.Count)" -ForegroundColor DarkGray
        }

        if ($seenNames.ContainsKey($font.Name)) {
            Write-Warn "Nom en double ignoré : $($font.Name) ($($font.FullName))"
            continue
        }
        $seenNames[$font.Name] = $true

        $targetFile = Join-Path $fontFolder $font.Name
        $suffix = Get-FontRegistrySuffix -Extension $font.Extension
        $displayName = "$($font.BaseName) $suffix"
        $regExists = Get-ItemProperty -Path $registryPath -Name $displayName -ErrorAction SilentlyContinue
        $fileExists = Test-Path -LiteralPath $targetFile

        if ($fileExists -and $regExists) {
            $skipped++
            continue
        }

        $changed = $false
        if (-not $fileExists) {
            Copy-Item -LiteralPath $font.FullName -Destination $fontFolder -Force
            $changed = $true
            $installed++
        } elseif (-not $regExists) {
            $updated++
        }

        if (-not $regExists) {
            New-ItemProperty -Path $registryPath -Name $displayName -Value $font.Name -PropertyType String -Force | Out-Null
            $changed = $true
        }

        if ($changed) {
            $newlyLoaded.Add($targetFile)
        }
    }

    if ($newlyLoaded.Count -gt 0) {
        Notify-WindowsFontChange -FontPaths $newlyLoaded.ToArray()
    }

    if ($installed -gt 0 -or $updated -gt 0) {
        Write-Ok "$installed copiée(s), $updated enregistrée(s) au registre, $skipped déjà à jour (total fonts/ : $($fontFiles.Count))."
    } else {
        Write-Ok "Les $($fontFiles.Count) polices de fonts/ sont déjà installées."
    }
    return $true
}

function Deploy-Fastfetch {
    param(
        [string]$SourceDir,
        [string]$DestDir
    )

    if (-not (Test-Path $SourceDir)) {
        Write-Warn "Dossier fastfetch/ introuvable dans le projet. Étape ignorée."
        return
    }

    if (-not (Test-Path $DestDir)) {
        New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $SourceDir '*') -Destination $DestDir -Recurse -Force

    $configPath = Join-Path $DestDir 'config.jsonc'
    if (Test-Path $configPath) {
        $asciiPath = (Join-Path $DestDir 'ascii.txt') -replace '\\', '/'
        $content = Get-Content -Path $configPath -Raw -Encoding UTF8
        $content = $content -replace '"source"\s*:\s*"[^"]*"', "`"source`": `"$asciiPath`""
        Write-Utf8NoBom -Path $configPath -Content $content
    }

    Write-Ok "Fastfetch déployé vers $DestDir"
}

function Deploy-WindowsTerminal {
    param(
        [string]$SourceDir,
        [string]$DestDir,
        [string]$BackupRootPath
    )

    if (-not (Test-Path $SourceDir)) {
        Write-Warn "Dossier LocalState/ introuvable dans le projet. Étape ignorée."
        return
    }

    if (-not $DestDir) {
        Write-Warn "Windows Terminal introuvable (package Microsoft.WindowsTerminal_*). Installez-le depuis le Microsoft Store."
        return
    }

    if (-not (Test-Path $DestDir)) {
        New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $BackupRootPath "WindowsTerminal-$timestamp"
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null

    foreach ($file in Get-ChildItem -Path $SourceDir -File) {
        $target = Join-Path $DestDir $file.Name
        if (Test-Path $target) {
            Copy-Item -Path $target -Destination (Join-Path $backupDir $file.Name) -Force
        }
        Copy-Item -Path $file.FullName -Destination $target -Force
        Write-Ok "Windows Terminal : $($file.Name) déployé (sauvegarde dans $backupDir)"
    }
}

function Get-LatestWindowsTerminalBackup {
    param([string]$BackupRootPath)

    if (-not (Test-Path $BackupRootPath)) {
        return $null
    }

    $latest = Get-ChildItem -Path $BackupRootPath -Directory -Filter 'WindowsTerminal-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if (-not $latest) {
        return $null
    }
    return $latest.FullName
}

function Restore-WindowsTerminal {
    param(
        [string]$DestDir,
        [string]$BackupRootPath
    )

    if (-not $DestDir) {
        Write-Warn "Windows Terminal introuvable. Restauration ignorée."
        return $false
    }

    $backupDir = Get-LatestWindowsTerminalBackup -BackupRootPath $BackupRootPath
    if (-not $backupDir) {
        Write-Warn "Aucune sauvegarde dans $BackupRootPath"
        return $false
    }

    $settingsBackup = Join-Path $backupDir 'settings.json'
    if (-not (Test-Path $settingsBackup)) {
        Write-Warn "settings.json absent dans $backupDir"
        return $false
    }

    Copy-Item -Path $settingsBackup -Destination (Join-Path $DestDir 'settings.json') -Force
    Write-Ok "settings.json restauré depuis $backupDir"
    return $true
}

function Remove-FastfetchFromProfile {
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (-not (Test-Path $profilePath)) {
        Write-Ok "Aucun profil PowerShell à modifier."
        return
    }

    $content = Get-Content -Path $profilePath -Raw -Encoding UTF8
    if ($content -notmatch [regex]::Escape($FastfetchMarker)) {
        Write-Ok "Fastfetch absent du profil PowerShell."
        return
    }

    $newContent = $content -replace "(?ms)\r?\n$([regex]::Escape($FastfetchMarker))\r?\nfastfetch\r?\n?", "`n"
    $newContent = $newContent.TrimEnd() + "`n"
    Write-Utf8NoBom -Path $profilePath -Content $newContent
    Write-Ok "Fastfetch retiré du profil PowerShell."
}

function Restart-WindowsTerminalApp {
    $closed = $false
    Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        $closed = $true
    }

    if ($closed) {
        Start-Sleep -Milliseconds 800
    }

    $wtCandidates = @(
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\Microsoft.WindowsTerminal_8wekyb3d8bbwe\wt.exe"
    )

    foreach ($wt in $wtCandidates) {
        if (Test-Path $wt) {
            Start-Process -FilePath $wt | Out-Null
            Write-Ok "Windows Terminal relancé."
            return $true
        }
    }

    $cmd = Get-Command wt -ErrorAction SilentlyContinue
    if ($cmd) {
        Start-Process -FilePath $cmd.Source | Out-Null
        Write-Ok "Windows Terminal relancé (wt)."
        return $true
    }

    Write-Warn "Windows Terminal non relancé (wt.exe introuvable). Ouvrez-le manuellement."
    return $false
}

function Invoke-BetterCmdInstall {
    Write-Host "`n=== Better CMD - Configuration automatique ===`n" -ForegroundColor Magenta

    Write-Step "Configuration de l'ExecutionPolicy..."
    try {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop
        Write-Ok "ExecutionPolicy configurée (CurrentUser)."
    } catch {
        Write-Warn "ExecutionPolicy non modifiée (stratégie système/groupe active). Le script continue."
    }

    Write-Step "Vérification de winget..."
    if (-not (Ensure-Winget)) {
        Write-Warn "winget indisponible : Fastfetch ne sera pas installé automatiquement."
    }
    Install-FastfetchPackage | Out-Null

    $fontsSource = Join-Path $ProjectRoot 'fonts'
    Write-Step "Installation des polices depuis fonts/..."
    Install-UserFonts -SourceFolder $fontsSource | Out-Null

    $fastfetchSource = Join-Path $ProjectRoot 'fastfetch'
    $fastfetchDest = Join-Path $env:USERPROFILE '.config\fastfetch'
    Write-Step "Déploiement de la configuration Fastfetch..."
    Deploy-Fastfetch -SourceDir $fastfetchSource -DestDir $fastfetchDest

    $localStateSource = Join-Path $ProjectRoot 'LocalState'
    $wtLocalState = Get-WindowsTerminalLocalState
    if (-not (Test-Path $BackupRoot)) {
        New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
    }

    Write-Step "Déploiement de Windows Terminal (LocalState)..."
    Deploy-WindowsTerminal -SourceDir $localStateSource -DestDir $wtLocalState -BackupRootPath $BackupRoot

    Write-Step "Configuration du profil PowerShell..."
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -Path $profileDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $profilePath)) {
        New-Item -Path $profilePath -ItemType File -Force | Out-Null
    }

    $profileContent = Get-Content -Path $profilePath -Raw -ErrorAction SilentlyContinue
    if ($profileContent -notmatch '\bfastfetch\b') {
        Add-Content -Path $profilePath -Value "`n$FastfetchMarker`nfastfetch" -Encoding UTF8
        Write-Ok "Fastfetch ajouté au profil PowerShell."
    } else {
        Write-Ok "Fastfetch déjà présent dans le profil PowerShell."
    }

    Write-Step "Relance de Windows Terminal..."
    Restart-WindowsTerminalApp | Out-Null

    Write-Host "`n[+] Installation terminée !" -ForegroundColor Green
    Write-Host "    Sauvegardes WT : $BackupRoot" -ForegroundColor Gray
    Write-Host "    Désinstallation : .\Better-CMD.ps1 -Uninstall`n" -ForegroundColor Gray
}

function Invoke-BetterCmdUninstall {
    Write-Host "`n=== Better CMD - Restauration / désinstallation ===`n" -ForegroundColor Magenta

    $wtLocalState = Get-WindowsTerminalLocalState

    Write-Step "Restauration de Windows Terminal..."
    $restored = Restore-WindowsTerminal -DestDir $wtLocalState -BackupRootPath $BackupRoot

    Write-Step "Nettoyage du profil PowerShell..."
    Remove-FastfetchFromProfile

    Write-Step "Relance de Windows Terminal..."
    Restart-WindowsTerminalApp | Out-Null

    Write-Host "`n[+] Restauration terminée." -ForegroundColor Green
    if (-not $restored) {
        Write-Warn "settings.json n'a pas été restauré (pas de sauvegarde)."
    }
    Write-Host "    Les polices et Fastfetch restent installés sur le système." -ForegroundColor Gray
    Write-Host "    Config fastfetch : $(Join-Path $env:USERPROFILE '.config\fastfetch')`n" -ForegroundColor Gray
}

if ($Uninstall) {
    Invoke-BetterCmdUninstall
} else {
    Invoke-BetterCmdInstall
}
