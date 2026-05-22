@echo off
setlocal
chcp 65001 >nul 2>&1

cd /d "%~dp0"

if not exist "%~dp0Better-PowerShell-CMD.ps1" (
    echo [ERREUR] Better-PowerShell-CMD.ps1 introuvable dans ce dossier.
    pause
    exit /b 1
)

set "EXTRA="
if /i "%~1"=="/Purge" set "EXTRA=-Purge"
if /i "%~1"=="-Purge" set "EXTRA=-Purge"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "chcp 65001 | Out-Null; $e = [System.Text.UTF8Encoding]::new($false); [Console]::OutputEncoding = $e; [Console]::InputEncoding = $e; & '%~dp0Better-PowerShell-CMD.ps1' -Uninstall %EXTRA%"
set EXITCODE=%ERRORLEVEL%

echo.
pause
endlocal
exit /b %EXITCODE%
