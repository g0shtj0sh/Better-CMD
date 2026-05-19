@echo off
setlocal
chcp 65001 >nul 2>&1

cd /d "%~dp0"

if not exist "%~dp0Better-CMD.ps1" (
    echo [ERREUR] Better-CMD.ps1 introuvable dans ce dossier.
    pause
    exit /b 1
)

echo.
echo ============================================
echo   Better CMD - Restauration
echo ============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "chcp 65001 | Out-Null; $e = [System.Text.UTF8Encoding]::new($false); [Console]::OutputEncoding = $e; [Console]::InputEncoding = $e; & '%~dp0Better-CMD.ps1' -Uninstall"
set EXITCODE=%ERRORLEVEL%

echo.
pause
endlocal
exit /b %EXITCODE%
