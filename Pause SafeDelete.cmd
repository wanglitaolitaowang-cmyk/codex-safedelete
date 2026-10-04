@echo off
setlocal EnableExtensions DisableDelayedExpansion
where safedelete >nul 2>nul
if errorlevel 1 goto local_install
call safedelete off
set "safedelete_exit=%errorlevel%"
goto result
:local_install
if not exist "%LOCALAPPDATA%\CodexSafeDelete\safedelete.cmd" goto missing
call "%LOCALAPPDATA%\CodexSafeDelete\safedelete.cmd" off
set "safedelete_exit=%errorlevel%"
:result
if not "%safedelete_exit%"=="0" goto failed
echo.
echo SafeDelete protection paused.
echo.
echo WARNING: Codex can now perform delete operations without SafeDelete protection.
echo.
echo Your previous recovery history has been preserved.
echo.
echo To enable protection again:
echo safedelete on
goto finish
:missing
set "safedelete_exit=1"
echo SafeDelete is not installed. Double-click Install SafeDelete.cmd first.
:failed
echo.
echo Could not confirm that protection is paused. Read the error above.
echo Run safedelete status to check the current state.
:finish
echo.
pause
endlocal & exit /b %safedelete_exit%
