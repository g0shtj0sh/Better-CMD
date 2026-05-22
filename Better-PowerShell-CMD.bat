@echo off
:: Lance Better-PowerShell-CMD.ps1 en administrateur
setlocal
chcp 65001 >nul 2>&1

cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%~dp0'"
    exit /b 0
)

if not exist "%~dp0Better-PowerShell-CMD.ps1" (
    echo [ERREUR] Better-PowerShell-CMD.ps1 introuvable dans ce dossier.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "chcp 65001 | Out-Null; $e = [System.Text.UTF8Encoding]::new($false); [Console]::OutputEncoding = $e; [Console]::InputEncoding = $e; & '%~dp0Better-PowerShell-CMD.ps1'"
set EXITCODE=%ERRORLEVEL%

echo.
pause
endlocal
exit /b %EXITCODE%
