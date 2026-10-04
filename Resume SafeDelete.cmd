@echo off
setlocal EnableExtensions DisableDelayedExpansion
where safedelete >nul 2>nul
if errorlevel 1 goto local_install
call safedelete on
set "safedelete_exit=%errorlevel%"
goto result
:local_install
if not exist "%LOCALAPPDATA%\CodexSafeDelete\safedelete.cmd" goto missing
call "%LOCALAPPDATA%\CodexSafeDelete\safedelete.cmd" on
set "safedelete_exit=%errorlevel%"
:result
if not "%safedelete_exit%"=="0" goto failed
echo.
echo SafeDelete protection enabled.
echo.
echo [OK] Codex delete protection active
echo [OK] Existing recovery history preserved
echo.
echo You can use Codex normally.
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
