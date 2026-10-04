@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "safedelete_exit=1"
set "safedelete_pushed="
if not "%OS%"=="Windows_NT" goto unsupported
set "safedelete_powershell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%safedelete_powershell%" goto unsupported
pushd "%~dp0"
if errorlevel 1 goto location_failed
set "safedelete_pushed=1"
"%safedelete_powershell%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set "safedelete_exit=%errorlevel%"
if not "%safedelete_exit%"=="0" goto failed
echo.
echo Codex SafeDelete installed successfully.
echo.
echo [OK] Codex protection enabled
echo [OK] Safe delete enabled
echo [OK] Undo command available
echo.
echo You only need to reopen Codex and your terminal once.
echo.
echo From now on, use Codex normally.
echo.
echo If something is accidentally deleted:
echo safedelete undo
goto finish
:unsupported
echo Windows PowerShell 5.1 is required. Run this file on Windows 10 or 11.
goto failed
:location_failed
echo Could not open the project folder. Extract the downloaded project first.
:failed
echo.
echo Codex SafeDelete installation failed. Exit code: %safedelete_exit%
echo Read the error above before trying again.
:finish
echo.
pause
if defined safedelete_pushed popd
endlocal & exit /b %safedelete_exit%
