@echo off
REM Better PowerShell/CMD - fastfetch au demarrage du profil CMD (Windows Terminal)
chcp 65001 >nul
set "FFCFG=%USERPROFILE%\.config\fastfetch\config.jsonc"
where fastfetch >nul 2>&1
if errorlevel 1 (
    echo [Better PowerShell/CMD] fastfetch introuvable. Lance Better-PowerShell-CMD.bat ou installe fastfetch.
    goto :eof
)
if exist "%FFCFG%" (
    fastfetch -c "%FFCFG%"
) else (
    fastfetch
)
