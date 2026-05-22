<#
    .SYNOPSIS
    Automatisation du ricing de Windows Terminal (basé sur la vidéo de SleepyCatHey).

    .PARAMETER Uninstall
    Désinstalle Better PowerShell/CMD : restaure Windows Terminal (sauvegarde « avant première install », sinon réinitialisation par défaut), profil PowerShell, fichiers .better-powershell-cmd, config fastfetch déployée par le script, et le paquet fastfetch (winget).

    .PARAMETER Force
    Réapplique tous les fichiers du dépôt même si le suivi indique qu’ils sont déjà à jour.

    .PARAMETER Purge
    Avec -Uninstall : supprime aussi le dossier %USERPROFILE%\.better-powershell-cmd-backups (y compris l’ancre).

    .EXAMPLE
    .\Better-PowerShell-CMD.ps1

    .EXAMPLE
    .\Better-PowerShell-CMD.ps1 -Force

    .EXAMPLE
    .\Better-PowerShell-CMD.ps1 -Uninstall

    .EXAMPLE
    .\Better-PowerShell-CMD.ps1 -Uninstall -Purge
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

$BackupRoot = Join-Path $env:USERPROFILE '.better-powershell-cmd-backups'
$AnchorSettingsFileName = 'settings-before-first-better-powershell-cmd.json'
$FastfetchMarker = '# Auto-start Fastfetch (Better PowerShell/CMD)'
$BetterPsCmdProfileMarker = '# Better PowerShell/CMD — profil PowerShell'
$PowerShellProfileRelativeDir = 'WindowsPowerShell'
$BetterPsCmdUserDir = Join-Path $env:USERPROFILE '.better-powershell-cmd'
$BetterPsCmdManagedMarker = '.better-powershell-cmd-managed'
$BetterPsCmdCmdProfileGuid = '{0caa0dad-35be-5f56-a8ff-afceeeaa6101}'
$BetterPsCmdVersion = '1.0'
$script:BetterPsCmdUiWidth = 78
$script:BetterPsCmdUiPanelOpen = $false
$script:BetterPsCmdProgressActive = $false
$LegacyBetterPsCmdUserDir = Join-Path $env:USERPROFILE '.better-cmd'
$LegacyBackupRoot = Join-Path $env:USERPROFILE '.better-cmd-backups'
$LegacyAnchorSettingsFileName = 'settings-before-first-better-cmd.json'
$LegacyBetterPsCmdManagedMarker = '.better-cmd-managed'
$LegacyBetterPsCmdProfileMarker = '# Better CMD — profil PowerShell'

function Get-BetterPsCmdEffectiveBackupRoot {
    if (Test-Path -LiteralPath $BackupRoot) {
        return $BackupRoot
    }
    if (Test-Path -LiteralPath $LegacyBackupRoot) {
        return $LegacyBackupRoot
    }
    return $BackupRoot
}

function Get-BetterPsCmdAnchorSettingsPath {
    param([string]$BackupRootPath = (Get-BetterPsCmdEffectiveBackupRoot))

    $candidates = @(
        (Join-Path $BackupRootPath $AnchorSettingsFileName),
        (Join-Path $BackupRootPath $LegacyAnchorSettingsFileName),
        (Join-Path $LegacyBackupRoot $AnchorSettingsFileName),
        (Join-Path $LegacyBackupRoot $LegacyAnchorSettingsFileName)
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    return (Join-Path $BackupRoot $AnchorSettingsFileName)
}

function Initialize-BetterPsCmdLegacyMigration {
    $migrated = $false

    if ((Test-Path -LiteralPath $LegacyBetterPsCmdUserDir) -and -not (Test-Path -LiteralPath $BetterPsCmdUserDir)) {
        Move-Item -LiteralPath $LegacyBetterPsCmdUserDir -Destination $BetterPsCmdUserDir -Force
        Write-Ok 'Migration : .better-cmd → .better-powershell-cmd'
        $migrated = $true
    }

    if ((Test-Path -LiteralPath $LegacyBackupRoot) -and -not (Test-Path -LiteralPath $BackupRoot)) {
        Move-Item -LiteralPath $LegacyBackupRoot -Destination $BackupRoot -Force
        Write-Ok 'Migration : .better-cmd-backups → .better-powershell-cmd-backups'
        $migrated = $true
    }

    return $migrated
}

function Get-BetterPsCmdSHA256File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-BetterPsCmdFastfetchSourceFingerprint {
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

function Get-BetterPsCmdInstallStatePath {
    Join-Path $BetterPsCmdUserDir 'install-state.json'
}

function Read-BetterPsCmdInstallState {
    $p = Get-BetterPsCmdInstallStatePath
    if (-not (Test-Path -LiteralPath $p)) {
        return $null
    }
    try {
        Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $null
    }
}

function Write-BetterPsCmdInstallState {
    param(
        [string]$SettingsJsonHash,
        [string]$ProfilePs1Hash,
        [string]$CmdInitHash,
        [string]$FastfetchHash
    )
    if (-not (Test-Path -LiteralPath $BetterPsCmdUserDir)) {
        New-Item -Path $BetterPsCmdUserDir -ItemType Directory -Force | Out-Null
    }
    $obj = [ordered]@{
        SchemaVersion  = 1
        Updated        = (Get-Date).ToString('o')
        SettingsJson   = $SettingsJsonHash
        ProfilePs1     = $ProfilePs1Hash
        CmdInit        = $CmdInitHash
        Fastfetch      = $FastfetchHash
    }
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath (Get-BetterPsCmdInstallStatePath) -Encoding UTF8
}

function Get-BetterPsCmdWindowsPowerShellProfileTargetPath {
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

function Deploy-BetterPsCmdPowerShellProfile {
    param(
        [string]$ProjectRootPath,
        [string]$BackupRootPath
    )

    $sourceProfile = Join-Path (Join-Path $ProjectRootPath $PowerShellProfileRelativeDir) 'profile.ps1'
    if (-not (Test-Path -LiteralPath $sourceProfile)) {
        Write-Warn "Fichier WindowsPowerShell\profile.ps1 introuvable dans le projet. Étape ignorée."
        return
    }

    $targetProfile = Get-BetterPsCmdWindowsPowerShellProfileTargetPath
    $targetDir = Split-Path -Parent $targetProfile

    $firstTimeBackup = Join-Path $BackupRootPath 'PowerShell-profile-before-better-powershell-cmd.ps1'
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

function Get-BetterPsCmdUiInnerWidth {
    [Math]::Max(20, $script:BetterPsCmdUiWidth - 4)
}

function Write-BetterPsCmdUiLine {
    param(
        [string]$Content,
        [System.ConsoleColor]$Color = [System.ConsoleColor]::Gray
    )
    $inner = Get-BetterPsCmdUiInnerWidth
    if ($Content.Length -gt $inner) {
        $Content = $Content.Substring(0, $inner - 1) + '…'
    }
    Write-Host ('│ ' + $Content.PadRight($inner) + ' │') -ForegroundColor $Color
}

function Write-BetterPsCmdUiBorder {
    param(
        [string]$Left,
        [string]$Mid,
        [string]$Right
    )
    $line = $Left + ($Mid * ($script:BetterPsCmdUiWidth - 2)) + $Right
    Write-Host $line -ForegroundColor DarkCyan
}

function Start-BetterPsCmdUi {
    param(
        [string]$Mode,
        [string]$Status = 'En cours',
        [System.ConsoleColor]$StatusColor = [System.ConsoleColor]::Yellow
    )

    if ($Host.Name -eq 'ConsoleHost') {
        Clear-Host
    }

    Write-BetterPsCmdUiBorder '╭' '─' '╮'

    $inner = Get-BetterPsCmdUiInnerWidth
    $seg1 = " Better PowerShell/CMD v$BetterPsCmdVersion "
    $seg2 = " $Mode "
    $seg3 = " ● $Status "
    $fixed = $seg1.Length + $seg2.Length + $seg3.Length + 4
    $pad = [Math]::Max(0, $inner - $fixed)
    $leftPad = [Math]::Floor($pad / 2)
    $rightPad = $pad - $leftPad
    $headerBody = (' ' * $leftPad) + $seg1 + $seg2 + $seg3 + (' ' * $rightPad)
    Write-BetterPsCmdUiLine $headerBody 'Magenta'

    Write-BetterPsCmdUiBorder '╰' '─' '╯'
    Write-Host ''

    $title = ' Journal '
    $dash = '─' * [Math]::Max(2, $script:BetterPsCmdUiWidth - $title.Length - 5)
    Write-Host ('╭─' + $title + $dash + '╮') -ForegroundColor DarkCyan
    $script:BetterPsCmdUiPanelOpen = $true
    $script:BetterPsCmdProgressActive = $false
}

function Stop-BetterPsCmdUiPanel {
    if ($script:BetterPsCmdUiPanelOpen) {
        Write-BetterPsCmdUiBorder '╰' '─' '╯'
        $script:BetterPsCmdUiPanelOpen = $false
        Write-Host ''
    }
}

function Write-BetterPsCmdLog {
    param(
        [ValidateSet('INFO', 'OK', 'WARN', 'STEP', 'ERR')]
        [string]$Level,
        [string]$Message
    )

    $tags = @{
        INFO = '[INFO]'
        STEP = '[ » ]'
        OK   = '[ OK ]'
        WARN = '[WARN]'
        ERR  = '[ERR ]'
    }
    $colors = @{
        INFO = [System.ConsoleColor]::Cyan
        STEP = [System.ConsoleColor]::DarkCyan
        OK   = [System.ConsoleColor]::Green
        WARN = [System.ConsoleColor]::Yellow
        ERR  = [System.ConsoleColor]::Red
    }

    Write-BetterPsCmdUiLine "$($tags[$Level]) $Message" $colors[$Level]
}

function Write-BetterPsCmdProgress {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Label = 'Polices',
        [switch]$Finalize
    )

    if ($Total -le 0) {
        return
    }

    $inner = Get-BetterPsCmdUiInnerWidth
    $barWidth = [Math]::Max(12, $inner - ($Label.Length + 12))
    $ratio = [Math]::Min(1.0, $Current / [double]$Total)
    $filled = [int][Math]::Round($barWidth * $ratio)
    $bar = ('█' * $filled).PadRight($barWidth, '░')
    $content = "$Label  $bar  $Current/$Total"
    if ($content.Length -gt $inner) {
        $content = $content.Substring(0, $inner - 1) + '…'
    }

    $complete = $Finalize.IsPresent -or ($Current -ge $Total)
    $color = if ($complete) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::DarkGray }
    $panelLine = ('│ ' + $content.PadRight($inner) + ' │').PadRight($script:BetterPsCmdUiWidth)

    if ($script:BetterPsCmdProgressActive) {
        Write-Host ("`r$panelLine") -NoNewline -ForegroundColor $color
    } else {
        Write-Host $panelLine -NoNewline -ForegroundColor $color
        $script:BetterPsCmdProgressActive = $true
    }

    if ($complete) {
        Write-Host ''
        $script:BetterPsCmdProgressActive = $false
    }
}

function Write-BetterPsCmdSummary {
    param([string[]]$Lines)

    Stop-BetterPsCmdUiPanel

    $title = ' Résumé '
    $dash = '─' * [Math]::Max(2, $script:BetterPsCmdUiWidth - $title.Length - 5)
    Write-Host ('╭─' + $title + $dash + '╮') -ForegroundColor DarkCyan
    foreach ($line in $Lines) {
        Write-BetterPsCmdUiLine $line ([System.ConsoleColor]::Gray)
    }
    Write-BetterPsCmdUiBorder '╰' '─' '╯'
    Write-Host ''
}

function Write-BetterPsCmdFooter {
    param(
        [bool]$Success = $true,
        [int]$ExitHint = 0
    )

    $status = if ($Success) { 'Terminé' } else { "Code $ExitHint" }
    $color = if ($Success) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::Yellow }
    Write-Host ('─' * $script:BetterPsCmdUiWidth) -ForegroundColor DarkGray
    Write-Host "  ● $status  │  Entrée pour fermer" -ForegroundColor $color
}

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-BetterPsCmdLog -Level STEP -Message $Message
}

function Write-Ok {
    param([string]$Message)
    Write-BetterPsCmdLog -Level OK -Message $Message
}

function Write-Warn {
    param([string]$Message)
    Write-BetterPsCmdLog -Level WARN -Message $Message
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

    $tempDir = Join-Path $env:TEMP "Better-PowerShell-CMD-winget"
    if (-not (Test-Path $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }

    $bundlePath = Join-Path $tempDir 'Microsoft.DesktopAppInstaller.msixbundle'

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'Better-PowerShell-CMD' }
        $asset = $release.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1

        if (-not $asset) {
            Write-Warn "Paquet winget introuvable sur GitHub. Essayez Better-PowerShell-CMD.bat ou installez App Installer depuis le Microsoft Store."
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
        Write-Warn "Relancez Better-PowerShell-CMD.bat (droits administrateur) puis réessayez."
        return $false
    }

    Start-Sleep -Seconds 2
    Update-ShellPath

    if (Get-WingetPath) {
        Write-Ok "winget installé avec succès."
        return $true
    }

    Write-Warn "App Installer installé mais winget introuvable. Fermez cette fenêtre, rouvrez Better-PowerShell-CMD.bat et réessayez."
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

function Ensure-BetterPsCmdNativeFontsType {
    if ('BetterPsCmdNativeFonts' -as [type]) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BetterPsCmdNativeFonts {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    public static extern int AddFontResource(string lpFileName);
}
'@ -ErrorAction Stop
}

function Notify-WindowsFontChange {
    Ensure-BetterPsCmdNativeFontsType
    # WM_FONTCHANGE — une seule notification, en PostMessage (asynchrone).
    [void][BetterPsCmdNativeFonts]::PostMessage([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Get-OpenTypeFontNameRecord {
    param(
        [string]$FontPath,
        [UInt16]$NameId
    )

    $bytes = [System.IO.File]::ReadAllBytes($FontPath)
    if ($bytes.Length -lt 12) {
        return $null
    }

    $numTables = [BitConverter]::ToUInt16($bytes, 4)
    $nameOffset = 0
    $nameLength = 0
    for ($i = 0; $i -lt $numTables; $i++) {
        $rec = 12 + ($i * 16)
        if (($rec + 16) -gt $bytes.Length) {
            break
        }
        $tag = [System.Text.Encoding]::ASCII.GetString($bytes, $rec, 4)
        if ($tag -eq 'name') {
            $nameOffset = [BitConverter]::ToUInt32($bytes, $rec + 8)
            $nameLength = [BitConverter]::ToUInt32($bytes, $rec + 12)
            break
        }
    }

    if ($nameOffset -eq 0 -or ($nameOffset + $nameLength) -gt $bytes.Length) {
        return $null
    }

    $count = [BitConverter]::ToUInt16($bytes, $nameOffset + 2)
    $stringOffset = [BitConverter]::ToUInt16($bytes, $nameOffset + 4)
    $storage = $nameOffset + $stringOffset

    for ($i = 0; $i -lt $count; $i++) {
        $rec = $nameOffset + 6 + ($i * 12)
        if (($rec + 12) -gt $bytes.Length) {
            break
        }
        $id = [BitConverter]::ToUInt16($bytes, $rec + 6)
        if ($id -ne $NameId) {
            continue
        }
        $platform = [BitConverter]::ToUInt16($bytes, $rec)
        $encoding = [BitConverter]::ToUInt16($bytes, $rec + 2)
        $lang = [BitConverter]::ToUInt16($bytes, $rec + 4)
        $length = [BitConverter]::ToUInt16($bytes, $rec + 8)
        $offset = [BitConverter]::ToUInt16($bytes, $rec + 10)
        $start = $storage + $offset
        if (($start + $length) -gt $bytes.Length) {
            continue
        }

        if ($platform -eq 3 -and $encoding -eq 1) {
            return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, $start, $length).Trim([char]0)
        }
        if ($platform -eq 1 -and $encoding -eq 0) {
            return [System.Text.Encoding]::ASCII.GetString($bytes, $start, $length).Trim([char]0)
        }
        if ($platform -eq 0) {
            return [System.Text.Encoding]::Unicode.GetString($bytes, $start, $length).Trim([char]0)
        }
    }

    return $null
}

function Get-FontRegistryDisplayName {
    param(
        [string]$FontPath,
        [string]$Suffix
    )

    $fullName = Get-OpenTypeFontNameRecord -FontPath $FontPath -NameId 4
    if ($fullName) {
        return "$fullName $Suffix"
    }

    $family = Get-OpenTypeFontNameRecord -FontPath $FontPath -NameId 1
    $subfamily = Get-OpenTypeFontNameRecord -FontPath $FontPath -NameId 2
    if ($family -and $subfamily) {
        return "$family $subfamily $Suffix"
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $pfc = New-Object System.Drawing.Text.PrivateFontCollection
        $pfc.AddFontFile($FontPath)
        return "$($pfc.Families[0].Name) $Suffix"
    } catch {
        return "$([System.IO.Path]::GetFileNameWithoutExtension($FontPath)) $Suffix"
    }
}

function Get-BetterPsCmdFontFiles {
    param([string]$SourceFolder)

    Get-ChildItem -Path (Join-Path $SourceFolder '*') -Include '*.ttf', '*.otf' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object FullName
}

function Ensure-ProjectFonts {
    param(
        [string]$FontsDir,
        [switch]$ForceDownload
    )

    if (-not (Test-Path -LiteralPath $FontsDir)) {
        New-Item -Path $FontsDir -ItemType Directory -Force | Out-Null
    }

    $requiredFile = Join-Path $FontsDir 'JetBrainsMonoNerdFontMono-Regular.ttf'
    $existing = @(Get-BetterPsCmdFontFiles -SourceFolder $FontsDir)
    if ($existing.Count -gt 0 -and (Test-Path -LiteralPath $requiredFile) -and -not $ForceDownload) {
        Write-Ok "Dossier fonts/ : $($existing.Count) fichier(s) déjà présent(s)."
        return $true
    }

    $version = 'v3.4.0'
    $archiveUrl = "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/JetBrainsMono.tar.xz"
    $tempRoot = Join-Path $env:TEMP 'Better-PowerShell-CMD-fonts'
    $archivePath = Join-Path $tempRoot 'JetBrainsMono.tar.xz'
    $extractDir = Join-Path $tempRoot 'extracted'

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

    Write-Step "Téléchargement JetBrains Mono Nerd Font ($version)..."
    try {
        Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing
    } catch {
        Write-Warn "Échec du téléchargement des polices : $($_.Exception.Message)"
        Write-Warn "URL : $archiveUrl"
        Write-Warn "Placez manuellement les .ttf dans fonts/ ou relancez avec une connexion Internet."
        return $false
    }

    if (-not (Test-Path -LiteralPath $archivePath) -or ((Get-Item -LiteralPath $archivePath).Length -lt 1000)) {
        Write-Warn 'Archive de polices invalide ou vide après téléchargement.'
        return $false
    }

    New-Item -Path $extractDir -ItemType Directory -Force | Out-Null
    Write-Step "Extraction de l'archive des polices..."
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if (-not $tar) {
        Write-Warn 'tar.exe introuvable (requis pour extraire .tar.xz sur Windows).'
        return $false
    }

    & $tar.Source -xf $archivePath -C $extractDir
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Extraction tar échouée (code $LASTEXITCODE)."
        return $false
    }

    $extractedFonts = @(
        Get-ChildItem -Path $extractDir -Filter '*NerdFontMono*.ttf' -Recurse -File -ErrorAction SilentlyContinue
    )
    if ($extractedFonts.Count -eq 0) {
        Write-Warn "Aucun fichier *NerdFontMono*.ttf dans l'archive. Verifiez la version Nerd Fonts."
        return $false
    }

    Write-Step "Copie de $($extractedFonts.Count) fichier(s) vers fonts/..."
    foreach ($font in $extractedFonts) {
        $dest = Join-Path $FontsDir $font.Name
        Copy-Item -LiteralPath $font.FullName -Destination $dest -Force
        Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Polices téléchargées dans fonts/ ($($extractedFonts.Count) variantes Mono Nerd Font)."
    return $true
}

function Install-UserFonts {
    param(
        [string]$SourceFolder,
        [switch]$RepairRegistry
    )

    if (-not (Test-Path -LiteralPath $SourceFolder)) {
        Write-Warn "Dossier fonts/ introuvable : '$SourceFolder'"
        return $false
    }

    $fontFiles = @(Get-BetterPsCmdFontFiles -SourceFolder $SourceFolder)

    if ($fontFiles.Count -eq 0) {
        Write-Warn "Aucun fichier .ttf/.otf dans '$SourceFolder'."
        return $false
    }

    Write-Step "$($fontFiles.Count) fichier(s) de police trouvé(s) dans fonts/ (installation utilisateur)..."

    Ensure-BetterPsCmdNativeFontsType

    $fontFolder = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (-not (Test-Path $fontFolder)) {
        New-Item -Path $fontFolder -ItemType Directory -Force | Out-Null
    }

    $registryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    $installed = 0
    $skipped = 0
    $repaired = 0
    $newlyLoaded = [System.Collections.Generic.List[string]]::new()
    $seenFileNames = @{}

    $index = 0
    $progressStep = if ($fontFiles.Count -gt 25) { 25 } else { $fontFiles.Count }
    foreach ($font in $fontFiles) {
        $index++
        if ($progressStep -gt 0 -and ($index % $progressStep -eq 0 -or $index -eq $fontFiles.Count)) {
            $isLast = ($index -eq $fontFiles.Count)
            Write-BetterPsCmdProgress -Current $index -Total $fontFiles.Count -Label 'Polices' -Finalize:$isLast
        }

        if ($seenFileNames.ContainsKey($font.Name)) {
            Write-Warn "Nom de fichier en double ignoré : $($font.Name)"
            continue
        }
        $seenFileNames[$font.Name] = $true

        Unblock-File -LiteralPath $font.FullName -ErrorAction SilentlyContinue

        $targetFile = Join-Path $fontFolder $font.Name
        $suffix = Get-FontRegistrySuffix -Extension $font.Extension
        $displayName = Get-FontRegistryDisplayName -FontPath $font.FullName -Suffix $suffix
        $legacyName = "$($font.BaseName) $suffix"

        $regExists = $null -ne (Get-ItemProperty -Path $registryPath -Name $displayName -ErrorAction SilentlyContinue)
        $fileExists = Test-Path -LiteralPath $targetFile

        if ($RepairRegistry -and $legacyName -ne $displayName) {
            if (Get-ItemProperty -Path $registryPath -Name $legacyName -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -Path $registryPath -Name $legacyName -ErrorAction SilentlyContinue
                if ($fileExists -or $regExists) {
                    $repaired++
                }
            }
        }

        if ($fileExists -and $regExists) {
            $skipped++
            continue
        }

        $changed = $false
        if (-not $fileExists) {
            Copy-Item -LiteralPath $font.FullName -Destination $targetFile -Force
            Unblock-File -LiteralPath $targetFile -ErrorAction SilentlyContinue
            $changed = $true
            $installed++
        }

        if (-not $regExists) {
            New-ItemProperty -Path $registryPath -Name $displayName -Value $font.Name -PropertyType String -Force | Out-Null
            if ($fileExists) {
                $repaired++
            }
            $changed = $true
        }

        if ($changed) {
            $null = [BetterPsCmdNativeFonts]::AddFontResource($targetFile)
            $newlyLoaded.Add($targetFile)
        }
    }

    if ($newlyLoaded.Count -gt 0) {
        Write-BetterPsCmdLog -Level INFO -Message 'Rafraîchissement du cache polices…'
        Notify-WindowsFontChange
    }

    if ($installed -gt 0 -or $repaired -gt 0) {
        Write-Ok "$installed copiée(s), $repaired registre corrigé(s), $skipped déjà OK (total fonts/ : $($fontFiles.Count))."
    } else {
        Write-Ok "Les $($fontFiles.Count) polices de fonts/ sont déjà installées pour cet utilisateur."
    }
    return $true
}

function Deploy-BetterPsCmdCmdInit {
    $destDir = $BetterPsCmdUserDir
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
    $batch += 'REM Genere par Better-PowerShell-CMD.ps1'
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
        $batch += '  echo [Better PowerShell/CMD] fastfetch introuvable. Lance Better-PowerShell-CMD.bat ou installe-le avec winget.'
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
    $cmdInit = Join-Path $BetterPsCmdUserDir 'cmd-init.cmd'
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
            Write-Warn 'Ligne commandline du profil CMD (GUID Better PowerShell/CMD) introuvable dans settings.json.'
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

    Set-Content -LiteralPath (Join-Path $DestDir $BetterPsCmdManagedMarker) -Value 'managed-by-better-powershell-cmd' -Encoding UTF8

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
    $projectHash = Get-BetterPsCmdSHA256File $sourceSettingsForCompare
    $targetHashBefore = Get-BetterPsCmdSHA256File $settingsTarget

    if (-not (Test-Path -LiteralPath $anchorPath)) {
        if (Test-Path -LiteralPath $settingsTarget) {
            if ($targetHashBefore -and $projectHash -and ($targetHashBefore -ne $projectHash)) {
                Copy-Item -LiteralPath $settingsTarget -Destination $anchorPath -Force
                Write-Ok "État Windows Terminal avant Better PowerShell/CMD enregistré (désinstall) : $anchorPath"
            } else {
                Write-Host "    Ancre WT : ignorée (déjà identique au projet Better PowerShell/CMD ou fichier absent) — la désinstall réinitialisera le Terminal par défaut si besoin." -ForegroundColor DarkGray
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

function Restore-WindowsTerminalFromBetterPsCmd {
    param(
        [string]$DestDir,
        [string]$BackupRootPath
    )

    if (-not $DestDir) {
        Write-Warn 'Windows Terminal introuvable. Restauration ignorée.'
        return $false
    }

    $targetSettings = Join-Path $DestDir 'settings.json'
    $anchorPath = Get-BetterPsCmdAnchorSettingsPath -BackupRootPath $BackupRootPath

    if (Test-Path -LiteralPath $anchorPath) {
        Copy-Item -LiteralPath $anchorPath -Destination $targetSettings -Force
        Write-Ok "Windows Terminal : settings.json restauré depuis votre config d'avant la première exécution Better PowerShell/CMD."
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

function Remove-BetterPsCmdManagedFastfetchConfig {
    $ffRoot = Join-Path $env:USERPROFILE '.config\fastfetch'
    $marker = Join-Path $ffRoot $BetterPsCmdManagedMarker
    $legacyMarker = Join-Path $ffRoot $LegacyBetterPsCmdManagedMarker
    if (-not (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $legacyMarker)) {
        Write-Warn "Dossier fastfetch sans marqueur Better PowerShell/CMD — rien n'a été supprimé (évite d'effacer une config personnelle)."
        return
    }
    if (Test-Path -LiteralPath $ffRoot) {
        Remove-Item -LiteralPath $ffRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Configuration utilisateur fastfetch supprimée ($ffRoot)."
    }
}

function Remove-BetterPsCmdUserInstallFolder {
    foreach ($dir in @($BetterPsCmdUserDir, $LegacyBetterPsCmdUserDir)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok "Dossier utilisateur supprimé : $dir"
        }
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

function Restore-BetterPsCmdPowerShellProfile {
    param([string]$BackupRootPath)

    $docsProfile = Get-BetterPsCmdWindowsPowerShellProfileTargetPath
    $firstTimeBackup = Join-Path $BackupRootPath 'PowerShell-profile-before-better-powershell-cmd.ps1'
    $legacyProfileBackup = Join-Path $BackupRootPath 'PowerShell-profile-before-better-cmd.ps1'
    if (-not (Test-Path -LiteralPath $firstTimeBackup) -and (Test-Path -LiteralPath $legacyProfileBackup)) {
        $firstTimeBackup = $legacyProfileBackup
    }
    if (-not (Test-Path -LiteralPath $firstTimeBackup) -and (Test-Path -LiteralPath (Join-Path $LegacyBackupRoot 'PowerShell-profile-before-better-cmd.ps1'))) {
        $firstTimeBackup = Join-Path $LegacyBackupRoot 'PowerShell-profile-before-better-cmd.ps1'
    }

    if (Test-Path -LiteralPath $firstTimeBackup) {
        $targetDir = Split-Path -Parent $docsProfile
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item -LiteralPath $firstTimeBackup -Destination $docsProfile -Force
        Write-Ok "Profil PowerShell restauré depuis la sauvegarde Better PowerShell/CMD."
        return
    }

    if (Test-Path -LiteralPath $docsProfile) {
        $raw = Get-Content -Path $docsProfile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($raw -and ($raw.Contains($BetterPsCmdProfileMarker) -or $raw.Contains($LegacyBetterPsCmdProfileMarker))) {
            Remove-Item -LiteralPath $docsProfile -Force
            Write-Ok "Profil Better PowerShell/CMD supprimé ($docsProfile) — aucune sauvegarde préalable."
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

function Invoke-BetterPsCmdInstall {
    Start-BetterPsCmdUi -Mode 'Installation' -Status 'En cours' -StatusColor ([System.ConsoleColor]::Yellow)

    Initialize-BetterPsCmdLegacyMigration | Out-Null

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
    Write-Step 'Polices JetBrains Mono Nerd Font...'
    if (-not (Ensure-ProjectFonts -FontsDir $fontsSource)) {
        Write-Warn 'Polices non téléchargées : installation utilisateur ignorée tant que fonts/ est vide.'
    } else {
        Install-UserFonts -SourceFolder $fontsSource -RepairRegistry | Out-Null
    }

    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
    }

    $srcSettings = Join-Path $ProjectRoot 'LocalState\settings.json'
    $srcProfile = Join-Path (Join-Path $ProjectRoot $PowerShellProfileRelativeDir) 'profile.ps1'
    $srcFastfetch = Join-Path $ProjectRoot 'fastfetch'

    Update-ShellPath
    $hSettings = Get-BetterPsCmdSHA256File $srcSettings
    $hProfile = Get-BetterPsCmdSHA256File $srcProfile
    $ffForCmdInitState = Get-Command fastfetch -ErrorAction SilentlyContinue
    $hCmdInit = if ($ffForCmdInitState -and (Test-Path -LiteralPath $ffForCmdInitState.Source)) {
        (Get-FileHash -LiteralPath $ffForCmdInitState.Source -Algorithm SHA256).Hash
    } else {
        'fastfetch-absent'
    }
    $hFf = Get-BetterPsCmdFastfetchSourceFingerprint $srcFastfetch

    $fastfetchDest = Join-Path $env:USERPROFILE '.config\fastfetch'
    $wtLocalState = Get-WindowsTerminalLocalState
    $deployedWtSettings = if ($wtLocalState) { Join-Path $wtLocalState 'settings.json' } else { $null }
    $profileTargetForCheck = Get-BetterPsCmdWindowsPowerShellProfileTargetPath
    $cmdInitTargetForCheck = Join-Path $BetterPsCmdUserDir 'cmd-init.cmd'
    $ffMarkerForCheck = Join-Path $fastfetchDest $BetterPsCmdManagedMarker

    $state = if (-not $Force) { Read-BetterPsCmdInstallState } else { $null }

    $needsWT = [bool]($Force -or (-not $state) -or ($state.SettingsJson -ne $hSettings) -or -not (Test-Path -LiteralPath $deployedWtSettings))
    $needsProfile = [bool]($Force -or (-not $state) -or ($state.ProfilePs1 -ne $hProfile) -or (($null -ne $hProfile) -and ((Get-BetterPsCmdSHA256File $profileTargetForCheck) -ne $hProfile)))
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
        Write-BetterPsCmdLog -Level INFO -Message "Mise à jour : $($parts -join ', ')"
    }

    if ($needsFF) {
        Write-Step "Déploiement / mise à jour de la configuration Fastfetch..."
        Deploy-Fastfetch -SourceDir $srcFastfetch -DestDir $fastfetchDest
    } else {
        Write-Ok "Config Fastfetch : inchangée côté projet (pas de recopie)."
    }

    if ($needsCmdInit) {
        Write-Step "Déploiement / mise à jour du lanceur CMD (fastfetch)..."
        Deploy-BetterPsCmdCmdInit
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
        Deploy-BetterPsCmdPowerShellProfile -ProjectRootPath $ProjectRoot -BackupRootPath $BackupRoot
    } else {
        Write-Ok "Profil PowerShell : inchangé (pas de recopie)."
    }

    if ($wtLocalState) {
        Write-Step 'Profil CMD Windows Terminal : chemin absolu vers cmd-init.cmd (requis pour fastfetch)...'
        Update-WindowsTerminalCmdProfileAbsoluteInit -DestDir $wtLocalState
    }

    Write-BetterPsCmdInstallState -SettingsJsonHash $hSettings -ProfilePs1Hash $hProfile -CmdInitHash $hCmdInit -FastfetchHash $hFf

    Write-Step 'Relance de Windows Terminal…'
    Restart-WindowsTerminalApp | Out-Null

    Write-Ok 'Installation terminée.'
    Write-BetterPsCmdSummary @(
        "Ancre WT : $(Join-Path $BackupRoot $AnchorSettingsFileName)"
        "Suivi : $(Get-BetterPsCmdInstallStatePath)"
        'Forcer : .\Better-PowerShell-CMD.ps1 -Force'
        'Désinstaller : .\Better-PowerShell-CMD.ps1 -Uninstall (-Purge)'
    )
    Write-BetterPsCmdFooter -Success $true
}

function Invoke-BetterPsCmdUninstall {
    Start-BetterPsCmdUi -Mode 'Désinstallation' -Status 'En cours' -StatusColor ([System.ConsoleColor]::Yellow)

    $wtLocalState = Get-WindowsTerminalLocalState

    Write-Step "Windows Terminal (restauration ou réinit par défaut)..."
    Initialize-BetterPsCmdLegacyMigration | Out-Null
    $effectiveBackup = Get-BetterPsCmdEffectiveBackupRoot

    $restored = Restore-WindowsTerminalFromBetterPsCmd -DestDir $wtLocalState -BackupRootPath $effectiveBackup

    Write-Step "Profil PowerShell..."
    Restore-BetterPsCmdPowerShellProfile -BackupRootPath $effectiveBackup

    Write-Step "Suppression du dossier fastfetch utilisateur géré par Better PowerShell/CMD..."
    Remove-BetterPsCmdManagedFastfetchConfig

    Write-Step "Désinstallation du paquet Fastfetch (winget)..."
    Uninstall-FastfetchPackage

    Write-Step "Suppression du dossier utilisateur .better-powershell-cmd (lanceur CMD, suivi)..."
    Remove-BetterPsCmdUserInstallFolder

    if ($Purge) {
        foreach ($dir in @($BackupRoot, $LegacyBackupRoot)) {
            if (Test-Path -LiteralPath $dir) {
                Remove-Item -LiteralPath $dir -Recurse -Force
                Write-Ok "Dossier de sauvegardes supprimé : $dir"
            }
        }
    }

    Write-Step "Relance de Windows Terminal..."
    Restart-WindowsTerminalApp | Out-Null

    Write-Ok 'Désinstallation terminée.'
    if (-not $restored) {
        Write-Warn "Windows Terminal : restauration depuis l'ancre impossible."
    }

    $summary = @(
        'Les polices dans fonts/ ne sont pas désinstallées automatiquement.'
    )
    if (-not $Purge) {
        $summary += "Sauvegardes : $BackupRoot (ajouter -Purge pour tout supprimer)"
    } else {
        $summary += 'Sauvegardes : supprimées (-Purge).'
    }
    Write-BetterPsCmdSummary -Lines $summary
    Write-BetterPsCmdFooter -Success $true
}

if ($Uninstall) {
    Invoke-BetterPsCmdUninstall
} else {
    Invoke-BetterPsCmdInstall
}
