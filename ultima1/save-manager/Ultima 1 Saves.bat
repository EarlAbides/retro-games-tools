@echo off
rem Ultima 1 Save Manager - no arguments opens the GUI, otherwise passes through to the script.
rem   e.g.  "Ultima 1 Saves.bat" -Backup -Note "before Mondain"
if "%~1"=="" (
  start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Ultima1Saves.ps1"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Ultima1Saves.ps1" %*
)
