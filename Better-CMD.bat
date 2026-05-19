@echo off
:: Lance Better-CMD.ps1 en administrateur
setlocal
chcp 65001 >nul 2>&1

cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%~dp0'"
    exit /b 0
)

if not exist "%~dp0Better-CMD.ps1" (
    echo [ERREUR] Better-CMD.ps1 introuvable dans ce dossier.
    pause
    exit /b 1
)

echo.
echo ============================================
echo   Better CMD - Configuration automatique
echo ============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "chcp 65001 | Out-Null; $e = [System.Text.UTF8Encoding]::new($false); [Console]::OutputEncoding = $e; [Console]::InputEncoding = $e; & '%~dp0Better-CMD.ps1'"
set EXITCODE=%ERRORLEVEL%

echo.
if %EXITCODE% neq 0 (
    echo [!] Le script s'est termine avec le code %EXITCODE%.
) else (
    echo [OK] Installation terminee. Windows Terminal a ete relance.
)
echo.
pause
endlocal
exit /b %EXITCODE%
