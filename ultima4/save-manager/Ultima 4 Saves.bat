@echo off
rem Ultima 4 Save Manager - no arguments opens the GUI, otherwise passes through to the script.
rem   e.g.  "Ultima 4 Saves.bat" -Backup -Note "before Hythloth"
if "%~1"=="" (
  start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Ultima4Saves.ps1"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Ultima4Saves.ps1" %*
)
