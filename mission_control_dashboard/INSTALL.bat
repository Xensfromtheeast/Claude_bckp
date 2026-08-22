@echo off
REM Install the prebuilt gem, then start it.
cd /d "%~dp0"

where gem >/dev/null 2>nul
if errorlevel 1 (
  echo.
  echo   RubyGems was not found on your PATH.
  echo   Install Ruby from https://rubyinstaller.org/ then reopen this window.
  echo.
  pause
  exit /b 1
)

if not exist "mission_control_dashboard-2.3.0.gem" (
  echo.
  echo   Cannot find mission_control_dashboard-2.3.0.gem in this folder.
  echo   You are probably one directory up from it. Run dir to check.
  echo.
  pause
  exit /b 1
)

echo Installing the gem locally ^(--local skips the network^)...
call gem install --local --no-document mission_control_dashboard-2.3.0.gem
if errorlevel 1 (
  echo.
  echo   Install failed. You can still run it without installing: RUN.bat
  echo.
  pause
  exit /b 1
)

echo.
echo   Installed. Starting the dashboard...
echo   From now on you can just type: mission_control server
echo.
call mission_control server --open
pause
