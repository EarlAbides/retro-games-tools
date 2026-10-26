@echo off
rem Starflight Save Manager - no arguments opens the GUI, otherwise passes through to the script.
rem   e.g.  "Starflight Saves.bat" -Backup -Slot MERCURY -Note "before Arth"
if "%~1"=="" (
  start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0StarflightSaves.ps1"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StarflightSaves.ps1" %*
)
