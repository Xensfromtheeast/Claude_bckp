@echo off
REM Run Mission Control straight from this folder - no build, no install.
cd /d "%~dp0"

where ruby >/dev/null 2>nul
if errorlevel 1 (
  echo.
  echo   Ruby was not found on your PATH.
  echo   Install it from https://rubyinstaller.org/ then reopen this window.
  echo.
  pause
  exit /b 1
)

if not exist "bin\mission_control" (
  echo.
  echo   Cannot find bin\mission_control next to this script.
  echo   Make sure you extracted the whole zip and this .bat sits beside
  echo   the bin, lib and test folders.
  echo.
  pause
  exit /b 1
)

REM Turn OFF console Quick Edit for windows opened from here on.
REM With Quick Edit on, clicking inside a console window selects text and
REM Windows SUSPENDS the program until you press Esc. That used to freeze
REM the dashboard mid-request. The server no longer blocks on its own log
REM output, but a paused console is still confusing, so we disable it.
reg add "HKCU\Console" /v QuickEdit /t REG_DWORD /d 0 /f >/dev/null 2>nul

echo.
echo   Starting Mission Control. Close this window to stop it.
echo   If output ever seems frozen, click here and press Esc.
echo.
ruby bin\mission_control server --open
echo.
echo   Server stopped.
pause
