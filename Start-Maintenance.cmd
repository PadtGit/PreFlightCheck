@echo off
setlocal
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
  echo PowerShell 7 x64 is required. Install it, then try again.
  pause
  exit /b 1
)
"%PWSH%" -NoLogo -NoProfile -STA -File "%~dp0Start-Maintenance.ps1"
if errorlevel 1 pause
