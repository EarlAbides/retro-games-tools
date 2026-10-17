@echo off
rem Starflight Starmap - starts the local map server (hidden) and opens the map in your browser.
rem Extra arguments pass through, e.g.  "Starflight Starmap.bat" -NotesFile "D:\Starflight\notes.json"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0StarmapServer.ps1" %*
