@echo off
rem Ultima 1 Map - starts the local map server (hidden) and opens the map in your browser.
rem Extra arguments pass through, e.g.  "Ultima 1 Map.bat" -NotesFile "D:\Ultima\map-notes.json"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0MapServer.ps1" %*
