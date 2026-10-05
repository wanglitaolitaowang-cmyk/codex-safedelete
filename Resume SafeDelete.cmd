@echo off
setlocal EnableExtensions DisableDelayedExpansion
if exist "%USERPROFILE%\.codex-safedelete-app\safedelete.cmd" goto shared_install
where safedelete >nul 2>nul
if errorlevel 1 goto local_install
call safedelete on
set "safedelete_exit=%errorlevel%"
goto result
:local_install
if not exist "%LOCALAPPDATA%\CodexSafeDelete\safedelete.cmd" goto missing
call "%LOCALAPPDATA%\CodexSafeDelete\safedelete.cmd" on
set "safedelete_exit=%errorlevel%"
goto result
:shared_install
call "%USERPROFILE%\.codex-safedelete-app\safedelete.cmd" on
set "safedelete_exit=%errorlevel%"
:result
if not "%safedelete_exit%"=="0" goto failed
echo.
echo SafeDelete is enabled in the local configuration.
echo.
echo [OK] Local Hook registration and execution checks passed
echo [OK] Existing recovery history preserved
echo.
echo After installation or upgrade, fully quit and relaunch Codex.
echo An already-running chat may not have loaded the Hook.
goto finish
:missing
set "safedelete_exit=1"
echo SafeDelete is not installed. Double-click Install SafeDelete.cmd first.
:failed
echo.
echo Could not confirm that protection is enabled. Read the error above.
echo Run safedelete status to check the current state.
:finish
echo.
pause
endlocal & exit /b %safedelete_exit%
