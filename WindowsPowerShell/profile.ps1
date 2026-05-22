# Better PowerShell/CMD — profil PowerShell (Documents\WindowsPowerShell\profile.ps1)
# Minimal profile: UTF‑8 + Oh My Posh (if installed) + Fastfetch with explicit config path
try {
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    chcp 65001 > $null
} catch {}

Clear-Host

# Force Fastfetch to use YOUR config every time (bypass path confusion)
if (Get-Command fastfetch -ErrorAction SilentlyContinue) {
    # $env:USERPROFILE = chemin réel (ex. C:\Users\ttjos) — ne pas utiliser %USERPROFILE% ici (syntaxe cmd.exe)
    $fastfetchConfig = (Join-Path $env:USERPROFILE '.config\fastfetch\config.jsonc') -replace '\\', '/'
    fastfetch -c $fastfetchConfig
}