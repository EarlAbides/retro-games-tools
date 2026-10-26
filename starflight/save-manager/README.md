# Starflight Save Manager

Starflight keeps one game state (`STARA.COM` / `STARB.COM`). This tool snapshots
those files into named slots so you can roll back.

Under the GOG release, DOSBox writes the game's files to
`cloud_saves\STARFLT\PLAY` (an overlay on the install's `STARFLT\PLAY`).
Backups go to `cloud_saves\STARFLT\BACKUPS\<slot>\<timestamp>\`.

## Usage

Double-click **`Starflight Saves.bat`** to open the GUI, or use the command line:

```
"Starflight Saves.bat" -Backup  -Slot MERCURY [-Note "before Arth"]
"Starflight Saves.bat" -List    [-Slot MERCURY]
"Starflight Saves.bat" -Restore -Slot MERCURY [-Stamp 2026-10-14_21-05-33]
```

Without `-Stamp`, `-Restore` uses the newest backup in the slot. Before every
restore, the current state is snapshotted to `_before-restore` unless it's
already backed up (the 10 most recent are kept). Restore is refused while
DOSBox is running.

## Finding the game

The tool looks for the Starflight install folder (the one containing `STARFLT`) in this order:

1. `-GameDir <path>`
2. the `STARFLIGHT_DIR` environment variable
3. the script's own folder (if you copy it into the install)
4. `Program Files (x86)\GOG Galaxy\Games\Starflight`, then `Program Files\GOG Galaxy\Games\Starflight`
