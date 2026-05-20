<#
    .SYNOPSIS
    Automatisation du ricing de Windows Terminal (basé sur la vidéo de SleepyCatHey).

    .PARAMETER Uninstall
    Désinstalle Better CMD : restaure Windows Terminal (sauvegarde « avant première install », sinon réinitialisation par défaut), profil PowerShell, fichiers .better-cmd, config fastfetch déployée par le script, et le paquet fastfetch (winget).

    .PARAMETER Force
    Réapplique tous les fichiers du dépôt même si le suivi indique qu’ils sont déjà à jour.

    .PARAMETER Purge
    Avec -Uninstall : supprime aussi le dossier %USERPROFILE%\.better-cmd-backups (y compris l’ancre).

    .EXAMPLE
    .\Better-CMD.ps1

    .EXAMPLE
    .\Better-CMD.ps1 -Force

    .EXAMPLE
    .\Better-CMD.ps1 -Uninstall

    .EXAMPLE
    .\Better-CMD.ps1 -Uninstall -Purge
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$Purge
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
$AnchorSettingsFileName = 'settings-before-first-better-cmd.json'
$FastfetchMarker = '# Auto-start Fastfetch (Better CMD)'
$BetterCmdProfileMarker = '# Better CMD — profil PowerShell'
$PowerShellProfileRelativeDir = 'WindowsPowerShell'
$BetterCmdUserDir = Join-Path $env:USERPROFILE '.better-cmd'
$BetterCmdManagedMarker = '.better-cmd-managed'
$BetterCmdCmdProfileGuid = '{0caa0dad-35be-5f56-a8ff-afceeeaa6101}'

function Get-BetterCmdSHA256File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-BetterCmdFastfetchSourceFingerprint {
    param([string]$FastfetchSourceDir)
    if (-not (Test-Path -LiteralPath $FastfetchSourceDir)) {
        return $null
    }
    $sb = [System.Text.StringBuilder]::new()
    Get-ChildItem -Path $FastfetchSourceDir -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        [void]$sb.Append($_.Name)
        [void]$sb.Append((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
}

function Get-BetterCmdInstallStatePath {
    Join-Path $BetterCmdUserDir 'install-state.json'
}

function Read-BetterCmdInstallState {
    $p = Get-BetterCmdInstallStatePath
    if (-not (Test-Path -LiteralPath $p)) {
        return $null
    }
    try {
        Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $null
    }
}

function Write-BetterCmdInstallState {
    param(
        [string]$SettingsJsonHash,
        [string]$ProfilePs1Hash,
        [string]$CmdInitHash,
        [string]$FastfetchHash
    )
    if (-not (Test-Path -LiteralPath $BetterCmdUserDir)) {
        New-Item -Path $BetterCmdUserDir -ItemType Directory -Force | Out-Null
    }
    $obj = [ordered]@{
        SchemaVersion  = 1
        Updated        = (Get-Date).ToString('o')
        SettingsJson   = $SettingsJsonHash
        ProfilePs1     = $ProfilePs1Hash
        CmdInit        = $CmdInitHash
        Fastfetch      = $FastfetchHash
    }
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath (Get-BetterCmdInstallStatePath) -Encoding UTF8
}

function Get-BetterCmdWindowsPowerShellProfileTargetPath {
    <#
        Chemin du profil AllHosts pour Windows PowerShell 5.1 (Élévation « Windows PowerShell » dans Windows Terminal).
        Sous PowerShell 7+, $PROFILE.CurrentUserAllHosts pointe vers Documents\PowerShell\ — on force alors Documents\WindowsPowerShell\.
    #>
    $viaProfile = $null
    if ($null -ne $PROFILE) {
        try {
            $viaProfile = $PROFILE.CurrentUserAllHosts
        } catch {
            $viaProfile = $null
        }
    }
    if ($viaProfile -and ($viaProfile -match '\\WindowsPowerShell\\')) {
        return $viaProfile
    }
    $documents = [Environment]::GetFolderPath('MyDocuments')
    return Join-Path (Join-Path $documents $PowerShellProfileRelativeDir) 'profile.ps1'
}

function Deploy-BetterCmdPowerShellProfile {
    param(
        [string]$ProjectRootPath,
        [string]$BackupRootPath
    )

    $sourceProfile = Join-Path (Join-Path $ProjectRootPath $PowerShellProfileRelativeDir) 'profile.ps1'
    if (-not (Test-Path -LiteralPath $sourceProfile)) {
        Write-Warn "Fichier WindowsPowerShell\profile.ps1 introuvable dans le projet. Étape ignorée."
        return
    }

    $targetProfile = Get-BetterCmdWindowsPowerShellProfileTargetPath
    $targetDir = Split-Path -Parent $targetProfile

    $firstTimeBackup = Join-Path $BackupRootPath 'PowerShell-profile-before-better-cmd.ps1'
    if (-not (Test-Path -LiteralPath $firstTimeBackup) -and (Test-Path -LiteralPath $targetProfile)) {
        Copy-Item -LiteralPath $targetProfile -Destination $firstTimeBackup -Force
        Write-Ok "Ancien profil PowerShell sauvegardé ($firstTimeBackup)."
    }

    # Même logique que la doc Microsoft : dossier + fichier profile « AllHosts », puis copie du contenu.
    New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    New-Item -Path $targetProfile -ItemType File -Force | Out-Null
    Copy-Item -LiteralPath $sourceProfile -Destination $targetProfile -Force

    # Fichier téléchargé / marqué « provenant d’Internet » : RemoteSigned le bloque sans ça.
    Unblock-File -LiteralPath $targetProfile -ErrorAction SilentlyContinue

    Write-Ok "Profil PowerShell déployé : $targetProfile"

    try {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop
    } catch {
        # Déjà tenté au début ; ignorer si stratégie groupe / Machine plus stricte
    }

    if ((Get-ExecutionPolicy) -eq 'AllSigned') {
        Write-Warn "La stratégie d'exécution effective est AllSigned : les scripts non signés (dont le profil) ne peuvent pas s'exécuter."
        Write-Warn "Si possible : Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force"
        Write-Warn "En entreprise, si une stratégie de groupe impose AllSigned, seul un admin peut ajuster ou le profil doit être signé."
    }
}

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
    # Plusieurs paquets possibles (Terminal / Terminal Preview). On préfère la build stable.
    $packages = @(
        Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages') -Filter 'Microsoft.WindowsTerminal*' -Directory -ErrorAction SilentlyContinue |
            Sort-Object {
                if ($_.Name -like '*Preview*') { 1 } else { 0 }
            },
            Name
    )
    if ($packages.Count -eq 0) {
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
    if (-not ('BetterCmdNativeFonts' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BetterCmdNativeFonts {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
'@ -ErrorAction SilentlyContinue
    }

    if ('BetterCmdNativeFonts' -as [type]) {
        # WM_FONTCHANGE — une seule notification, en PostMessage (asynchrone).
        # SendMessage(HWND_BROADCAST, …) attend chaque fenêtre : très lent après ~100 polices.
        # Les fichiers sont déjà dans le dossier utilisateur + registre ; pas besoin d’AddFontResourceW × N.
        [void][BetterCmdNativeFonts]::PostMessage([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero)
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
        Write-Host "    ... rafraîchissement des polices (rapide)" -ForegroundColor DarkGray
        Notify-WindowsFontChange
    }

    if ($installed -gt 0 -or $updated -gt 0) {
        Write-Ok "$installed copiée(s), $updated enregistrée(s) au registre, $skipped déjà à jour (total fonts/ : $($fontFiles.Count))."
    } else {
        Write-Ok "Les $($fontFiles.Count) polices de fonts/ sont déjà installées."
    }
    return $true
}

function Deploy-BetterCmdCmdInit {
    $destDir = Join-Path $env:USERPROFILE '.better-cmd'
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
    }

    $dest = Join-Path $destDir 'cmd-init.cmd'
    Update-ShellPath
    $ff = Get-Command fastfetch -ErrorAction SilentlyContinue

    # cmd.exe voit souvent un PATH plus petit que PowerShell — chemin complet vers fastfetch quand on le trouve.
    $batch = @()
    $batch += '@echo off'
    $batch += 'setlocal'
    $batch += 'REM Genere par Better-CMD.ps1'
    $batch += 'chcp 65001 >nul'
    $batch += 'set "FFCFG=%USERPROFILE%\.config\fastfetch\config.jsonc"'
    if ($ff -and (Test-Path -LiteralPath $ff.Source)) {
        $exe = $ff.Source.Replace('"', '""')
        $batch += 'if exist "%FFCFG%" ('
        $batch += "  `"$exe`" -c `"%FFCFG%`""
        $batch += ') else ('
        $batch += "  `"$exe`""
        $batch += ')'
    } else {
        $batch += 'where fastfetch >nul 2>&1'
        $batch += 'if errorlevel 1 ('
        $batch += '  echo [Better CMD] fastfetch introuvable. Lance Better-CMD.bat ou installe-le avec winget.'
        $batch += '  goto :eof'
        $batch += ')'
        $batch += 'if exist "%FFCFG%" ('
        $batch += '  fastfetch -c "%FFCFG%"'
        $batch += ') else ('
        $batch += '  fastfetch'
        $batch += ')'
    }
    $batch += 'endlocal'
    Write-Utf8NoBom -Path $dest -Content (($batch -join "`r`n") + "`r`n")
    Write-Ok "Démarrage CMD (fastfetch) déployé : $dest"
}

function Update-WindowsTerminalCmdProfileAbsoluteInit {
    param([string]$DestDir)

    if (-not $DestDir) {
        return
    }
    $settingsPath = Join-Path $DestDir 'settings.json'
    $cmdInit = Join-Path $env:USERPROFILE '.better-cmd\cmd-init.cmd'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        return
    }
    if (-not (Test-Path -LiteralPath $cmdInit)) {
        Write-Warn 'cmd-init.cmd absent : profil CMD du Terminal non mis à jour.'
        return
    }

    $cmdExe = (Join-Path $env:SystemRoot 'System32\cmd.exe').TrimEnd('\')
    $newCommandLine = "$cmdExe /k `"$cmdInit`""
    $escaped = $newCommandLine.Replace('\', '\\').Replace('"', '\"')

    try {
        $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
        $pattern = '("commandline"\s*:\s*")((?:\\.|[^"\\])*)("\s*,\s*\r?\n\s*"guid"\s*:\s*"\{0caa0dad-35be-5f56-a8ff-afceeeaa6101\}")'
        if ($raw -notmatch $pattern) {
            Write-Warn 'Ligne commandline du profil CMD (GUID Better CMD) introuvable dans settings.json.'
            return
        }
        $newRaw = [regex]::Replace($raw, $pattern, { param($match) $match.Groups[1].Value + $escaped + $match.Groups[3].Value }, 1)
        Write-Utf8NoBom -Path $settingsPath -Content $newRaw
        Write-Ok 'Windows Terminal : ligne de commande CMD = chemin absolu vers cmd-init.'
    } catch {
        Write-Warn "Impossible de modifier settings.json pour le profil CMD : $($_.Exception.Message)"
    }
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

    Set-Content -LiteralPath (Join-Path $DestDir $BetterCmdManagedMarker) -Value 'managed-by-better-cmd' -Encoding UTF8

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

    $anchorPath = Join-Path $BackupRootPath $AnchorSettingsFileName
    $sourceSettingsForCompare = Join-Path $SourceDir 'settings.json'
    $settingsTarget = Join-Path $DestDir 'settings.json'
    $projectHash = Get-BetterCmdSHA256File $sourceSettingsForCompare
    $targetHashBefore = Get-BetterCmdSHA256File $settingsTarget

    if (-not (Test-Path -LiteralPath $anchorPath)) {
        if (Test-Path -LiteralPath $settingsTarget) {
            if ($targetHashBefore -and $projectHash -and ($targetHashBefore -ne $projectHash)) {
                Copy-Item -LiteralPath $settingsTarget -Destination $anchorPath -Force
                Write-Ok "État Windows Terminal avant Better CMD enregistré (désinstall) : $anchorPath"
            } else {
                Write-Host "    Ancre WT : ignorée (déjà identique au projet Better CMD ou fichier absent) — la désinstall réinitialisera le Terminal par défaut si besoin." -ForegroundColor DarkGray
            }
        }
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

function Restore-WindowsTerminalFromBetterCmd {
    param(
        [string]$DestDir,
        [string]$BackupRootPath
    )

    if (-not $DestDir) {
        Write-Warn 'Windows Terminal introuvable. Restauration ignorée.'
        return $false
    }

    $targetSettings = Join-Path $DestDir 'settings.json'
    $anchorPath = Join-Path $BackupRootPath $AnchorSettingsFileName

    if (Test-Path -LiteralPath $anchorPath) {
        Copy-Item -LiteralPath $anchorPath -Destination $targetSettings -Force
        Write-Ok "Windows Terminal : settings.json restauré depuis votre config d'avant la première exécution Better CMD."
        return $true
    }

    Write-Warn "Aucune sauvegarde initiale ($AnchorSettingsFileName). Les sauvegardes datées peuvent déjà être la version personnalisée — réinitialisation des paramètres du Terminal."
    if (Test-Path -LiteralPath $targetSettings) {
        Remove-Item -LiteralPath $targetSettings -Force
        Write-Ok 'settings.json supprimé : Windows Terminal recréera les réglages par défaut au prochain démarrage.'
        return $true
    }

    Write-Warn 'Aucun settings.json à supprimer.'
    return $false
}

function Remove-BetterCmdManagedFastfetchConfig {
    $ffRoot = Join-Path $env:USERPROFILE '.config\fastfetch'
    $marker = Join-Path $ffRoot $BetterCmdManagedMarker
    if (-not (Test-Path -LiteralPath $marker)) {
        Write-Warn "Dossier fastfetch sans marqueur Better CMD — rien n'a été supprimé (évite d'effacer une config personnelle)."
        return
    }
    if (Test-Path -LiteralPath $ffRoot) {
        Remove-Item -LiteralPath $ffRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Configuration utilisateur fastfetch supprimée ($ffRoot)."
    }
}

function Remove-BetterCmdUserInstallFolder {
    if (Test-Path -LiteralPath $BetterCmdUserDir) {
        Remove-Item -LiteralPath $BetterCmdUserDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Dossier utilisateur .better-cmd supprimé (cmd-init, suivi d'installation)."
    }
}

function Uninstall-FastfetchPackage {
    if (-not (Get-WingetPath)) {
        Write-Warn "winget indisponible : fastfetch n'a pas été désinstallé via le gestionnaire de paquets."
        return
    }
    if (-not (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
        Write-Ok "Fastfetch n'est pas dans le PATH — considéré comme déjà absent."
        return
    }
    Write-Step 'Désinstallation de Fastfetch (winget)...'
    $exitCode = Invoke-Winget -ArgumentList @(
        'uninstall',
        '--id', 'Fastfetch-cli.Fastfetch',
        '--exact',
        '--accept-source-agreements'
    )
    if ($exitCode -eq 0 -or -not (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
        Write-Ok 'Paquet Fastfetch désinstallé (winget).'
    } else {
        Write-Warn "La désinstallation winget a renvoyé le code $exitCode. Tu peux essayer : winget uninstall Fastfetch-cli.Fastfetch"
    }
}

function Remove-FastfetchFromProfile {
    param([string]$ProfilePath)

    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        return
    }

    $content = Get-Content -Path $ProfilePath -Raw -Encoding UTF8
    if ($content -notmatch [regex]::Escape($FastfetchMarker)) {
        return
    }

    $newContent = $content -replace "(?ms)\r?\n$([regex]::Escape($FastfetchMarker))\r?\nfastfetch\r?\n?", "`n"
    $newContent = $newContent.TrimEnd() + "`n"
    Write-Utf8NoBom -Path $ProfilePath -Content $newContent
    Write-Ok "Fastfetch retiré du profil : $ProfilePath"
}

function Restore-BetterCmdPowerShellProfile {
    param([string]$BackupRootPath)

    $docsProfile = Get-BetterCmdWindowsPowerShellProfileTargetPath
    $firstTimeBackup = Join-Path $BackupRootPath 'PowerShell-profile-before-better-cmd.ps1'

    if (Test-Path -LiteralPath $firstTimeBackup) {
        $targetDir = Split-Path -Parent $docsProfile
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item -LiteralPath $firstTimeBackup -Destination $docsProfile -Force
        Write-Ok "Profil PowerShell restauré depuis la sauvegarde Better CMD."
        return
    }

    if (Test-Path -LiteralPath $docsProfile) {
        $raw = Get-Content -Path $docsProfile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($raw -and $raw.Contains($BetterCmdProfileMarker)) {
            Remove-Item -LiteralPath $docsProfile -Force
            Write-Ok "Profil Better CMD supprimé ($docsProfile) — aucune sauvegarde préalable."
            return
        }
    }

    Remove-FastfetchFromProfile -ProfilePath $docsProfile
    $legacyAllHosts = $PROFILE.CurrentUserAllHosts
    if ($legacyAllHosts -and ($legacyAllHosts -ne $docsProfile)) {
        Remove-FastfetchFromProfile -ProfilePath $legacyAllHosts
    }
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

    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
    }

    $srcSettings = Join-Path $ProjectRoot 'LocalState\settings.json'
    $srcProfile = Join-Path (Join-Path $ProjectRoot $PowerShellProfileRelativeDir) 'profile.ps1'
    $srcFastfetch = Join-Path $ProjectRoot 'fastfetch'

    Update-ShellPath
    $hSettings = Get-BetterCmdSHA256File $srcSettings
    $hProfile = Get-BetterCmdSHA256File $srcProfile
    $ffForCmdInitState = Get-Command fastfetch -ErrorAction SilentlyContinue
    $hCmdInit = if ($ffForCmdInitState -and (Test-Path -LiteralPath $ffForCmdInitState.Source)) {
        (Get-FileHash -LiteralPath $ffForCmdInitState.Source -Algorithm SHA256).Hash
    } else {
        'fastfetch-absent'
    }
    $hFf = Get-BetterCmdFastfetchSourceFingerprint $srcFastfetch

    $fastfetchDest = Join-Path $env:USERPROFILE '.config\fastfetch'
    $wtLocalState = Get-WindowsTerminalLocalState
    $deployedWtSettings = if ($wtLocalState) { Join-Path $wtLocalState 'settings.json' } else { $null }
    $profileTargetForCheck = Get-BetterCmdWindowsPowerShellProfileTargetPath
    $cmdInitTargetForCheck = Join-Path $BetterCmdUserDir 'cmd-init.cmd'
    $ffMarkerForCheck = Join-Path $fastfetchDest $BetterCmdManagedMarker

    $state = if (-not $Force) { Read-BetterCmdInstallState } else { $null }

    $needsWT = [bool]($Force -or (-not $state) -or ($state.SettingsJson -ne $hSettings) -or -not (Test-Path -LiteralPath $deployedWtSettings))
    $needsProfile = [bool]($Force -or (-not $state) -or ($state.ProfilePs1 -ne $hProfile) -or (($null -ne $hProfile) -and ((Get-BetterCmdSHA256File $profileTargetForCheck) -ne $hProfile)))
    $needsCmdInit = [bool]($Force -or (-not $state) -or ($state.CmdInit -ne $hCmdInit) -or -not (Test-Path -LiteralPath $cmdInitTargetForCheck))
    $needsFF = [bool]($Force -or (-not $state) -or ($state.Fastfetch -ne $hFf) -or -not (Test-Path -LiteralPath $ffMarkerForCheck))

    if (-not ($needsWT -or $needsProfile -or $needsCmdInit -or $needsFF)) {
        Write-Ok "Contenu du dépôt déjà déployé (install-state.json). Utilise -Force pour tout ré-appliquer."
    } else {
        $parts = @()
        if ($needsFF) { $parts += 'Fastfetch' }
        if ($needsCmdInit) { $parts += 'CMD (cmd-init)' }
        if ($needsWT) { $parts += 'Windows Terminal' }
        if ($needsProfile) { $parts += 'Profil PowerShell' }
        Write-Host "    Mise à jour : $($parts -join ', ')" -ForegroundColor DarkGray
    }

    if ($needsFF) {
        Write-Step "Déploiement / mise à jour de la configuration Fastfetch..."
        Deploy-Fastfetch -SourceDir $srcFastfetch -DestDir $fastfetchDest
    } else {
        Write-Ok "Config Fastfetch : inchangée côté projet (pas de recopie)."
    }

    if ($needsCmdInit) {
        Write-Step "Déploiement / mise à jour du lanceur CMD (fastfetch)..."
        Deploy-BetterCmdCmdInit
    } else {
        Write-Ok "cmd-init.cmd : inchangé (pas de recopie)."
    }

    if ($needsWT) {
        Write-Step "Déploiement / mise à jour de Windows Terminal (LocalState)..."
        $localStateSource = Join-Path $ProjectRoot 'LocalState'
        Deploy-WindowsTerminal -SourceDir $localStateSource -DestDir $wtLocalState -BackupRootPath $BackupRoot
    } else {
        Write-Ok "settings.json du projet : inchangé — Terminal non modifié."
    }

    if ($needsProfile) {
        Write-Step 'Configuration du profil PowerShell (Windows PowerShell 5.1, CurrentUserAllHosts)...'
        Deploy-BetterCmdPowerShellProfile -ProjectRootPath $ProjectRoot -BackupRootPath $BackupRoot
    } else {
        Write-Ok "Profil PowerShell : inchangé (pas de recopie)."
    }

    if ($wtLocalState) {
        Write-Step 'Profil CMD Windows Terminal : chemin absolu vers cmd-init.cmd (requis pour fastfetch)...'
        Update-WindowsTerminalCmdProfileAbsoluteInit -DestDir $wtLocalState
    }

    Write-BetterCmdInstallState -SettingsJsonHash $hSettings -ProfilePs1Hash $hProfile -CmdInitHash $hCmdInit -FastfetchHash $hFf

    Write-Step "Relance de Windows Terminal..."
    Restart-WindowsTerminalApp | Out-Null

    Write-Host "`n[+] Installation terminée !" -ForegroundColor Green
    Write-Host "    Ancre de restauration WT : $(Join-Path $BackupRoot $AnchorSettingsFileName)" -ForegroundColor Gray
    Write-Host "    Suivi des versions : $(Get-BetterCmdInstallStatePath)" -ForegroundColor Gray
    Write-Host "    Réinstallation forcée : .\Better-CMD.ps1 -Force" -ForegroundColor Gray
    Write-Host "    Désinstallation : .\Better-CMD.ps1 -Uninstall   (tout supprimer y compris sauvegardes : ajouter -Purge)`n" -ForegroundColor Gray
}

function Invoke-BetterCmdUninstall {
    Write-Host "`n=== Better CMD - Désinstallation complète ===`n" -ForegroundColor Magenta

    $wtLocalState = Get-WindowsTerminalLocalState

    Write-Step "Windows Terminal (restauration ou réinit par défaut)..."
    $restored = Restore-WindowsTerminalFromBetterCmd -DestDir $wtLocalState -BackupRootPath $BackupRoot

    Write-Step "Profil PowerShell..."
    Restore-BetterCmdPowerShellProfile -BackupRootPath $BackupRoot

    Write-Step "Suppression du dossier fastfetch utilisateur géré par Better CMD..."
    Remove-BetterCmdManagedFastfetchConfig

    Write-Step "Désinstallation du paquet Fastfetch (winget)..."
    Uninstall-FastfetchPackage

    Write-Step "Suppression du dossier utilisateur .better-cmd (lanceur CMD, suivi)..."
    Remove-BetterCmdUserInstallFolder

    if ($Purge -and (Test-Path -LiteralPath $BackupRoot)) {
        Remove-Item -LiteralPath $BackupRoot -Recurse -Force
        Write-Ok "Dossier de sauvegardes supprimé : $BackupRoot"
    }

    Write-Step "Relance de Windows Terminal..."
    Restart-WindowsTerminalApp | Out-Null

    Write-Host "`n[+] Désinstallation Better CMD terminée." -ForegroundColor Green
    if (-not $restored) {
        Write-Warn "Windows Terminal n'a pas pu être restauré depuis l'ancre (détail dans les messages ci-dessus)."
    }
    Write-Host "    Les polices installées depuis fonts/ n'ont pas été désinstallées automatiquement." -ForegroundColor Gray
    if (-not $Purge) {
        Write-Host "    Sauvegardes conservées dans : $BackupRoot (supprimer avec : .\Better-CMD.ps1 -Uninstall -Purge)`n" -ForegroundColor Gray
    } else {
        Write-Host "    Sauvegardes : supprimées (-Purge).`n" -ForegroundColor Gray
    }
}

if ($Uninstall) {
    Invoke-BetterCmdUninstall
} else {
    Invoke-BetterCmdInstall
}
