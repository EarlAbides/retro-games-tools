# Starflight Starmap

An interactive version of the Starflight starmap poster that runs in your browser, with
your own notes on top.

- Zoom with the mouse wheel (or `+` / `-` / `0` to fit), and drag to move around.
- Stars use the poster's colors, which are the game's spectral classes (O blue, B light blue,
  A green, F white, G yellow, K orange, M red). You can hide classes from the legend.
- Click a star to name it, mark it **visited** (it gets a ring, and "Dim unvisited"
  fades the rest), and keep notes on it.
- A visited star shows its **system map**: the planets in their orbits, colored the way the
  game's in-system view colors them (violet gas giant, blue liquid, white frozen, brown
  rocky; molten and rock share the brown, as in the game), with a note line per planet.
  Unvisited systems stay hidden so the map doesn't spoil exploring.
- **Double-click** empty space, or use **+ Add marker**, to drop an encounter, note, or
  point-of-interest marker at those coordinates, with a title and notes.
- Hover a flux endpoint to see where it comes out; click it to jump to the other end.
- A purple arrow marks Arth (125,100), where you start, as on the fan-made maps.
- **Territories**: the circles from the poster. Mark one discovered to shade it and name it.
- Every layer (grid, nebulae, flux lines, territories, labels, markers...) can be turned
  on and off.
- The **Journal** lists everything you've noted. Click an entry to fly to it.

## Running it

Double-click **`Starflight Starmap.bat`**. It starts a small local web server (PowerShell,
nothing to install) and opens the map at <http://localhost:8642/>. The server quits on its
own a few minutes after you close the map tab.

Notes are saved as you type to `starmap-notes.json` next to the script (the previous
version is kept as `.bak`). That file is gitignored; use **Export notes** in the sidebar
for a backup. To keep notes elsewhere:

```
"Starflight Starmap.bat" -NotesFile "D:\Games\Starflight\starmap-notes.json"
```

`StarmapServer.ps1` also takes `-Port` and `-NoBrowser`.

## Where the map comes from

- `web/map-data.json` is extracted from the game itself by `Extract-MapData.ps1`: all 270
  stars with exact coordinates and spectral class, their 811 planets (orbit, surface type,
  size class), the 32 flux pairs, and the 70 nebula circles. It reads
  `STARFLT\START\STARB.COM` and `STARA.COM` from the GOG install (or `-GameDir` /
  `STARFLIGHT_DIR`); rerun it only if you want to regenerate the file. The record layout
  comes from [s-macke/starflight-reverse](https://github.com/s-macke/starflight-reverse).
- `web/poster-overlay.json` holds things that aren't in the game data: the territory
  circles and the two vertical lines from the original EA poster, traced from a scan by
  fitting circles to the line art.
