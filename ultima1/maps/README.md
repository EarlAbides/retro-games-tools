# Ultima 1 Maps

## Interactive map

Double-click **`Ultima 1 Map.bat`**. It starts a small local web server (PowerShell,
nothing to install) and opens the map at <http://localhost:8643/>. The server quits on
its own a few minutes after you close the map tab.

- Drag to move, scroll to zoom (or `+` / `-` / `0` to fit). Zoomed out it's a clean
  terrain map. Zoom in and it switches to the game's own tiles.
- All 84 places are labeled with their names from the game: 32 towns, 8 castles,
  8 landmarks and signposts, and 36 dungeons. Find one with the search box (`/`).
- **Your characters** show where each save left them, with a yellow flag. The list
  says how far they are from the nearest place. It rereads the saves when you come
  back to the tab, or click **Refresh**.
- Click a place to see which land it's in, mark it **visited** (it gets a green box
  on the map), and keep notes. Towns and castles show their **layout**; click it to
  enlarge. The 32 towns share 8 layouts and the 8 castles share 2, and it lists
  which other places share the one you're looking at.
- Every label type, the land borders and a tile grid can be turned on and off.

Notes are saved as you type to `map-notes.json` next to the script (the previous
version is kept as `.bak`). That file is gitignored. Use **Export notes** for a backup.
`MapServer.ps1` also takes `-GameDir`, `-Port`, `-NotesFile` and `-NoBrowser`.

The page reads the map and tile files straight from your install through the
server, so none of the game's art is stored here.

## Exporting PNGs

`Export-Maps.ps1` renders the game's maps to PNG from its own files, drawn with
the game's EGA tiles:

| File | What |
|------|------|
| `out/world.png` | The overworld, all four lands: 168 x 156 tiles, 2688 x 2496 px |
| `out/castle-1.png`, `castle-2.png` | The two castle layouts that the 8 castles share |
| `out/town-1.png` .. `town-8.png` | The eight town layouts that the 32 towns share |

```
.\Export-Maps.ps1 [-GameDir <install folder>] [-OutDir <folder>] [-Scale 2]
```

`out/` is gitignored: the images are the game's artwork, so each copy is
rendered from the player's own install. It finds the game the same way as the
[save manager](../save-manager/) (`-GameDir`, `ULTIMA1_DIR`, then the GOG Galaxy paths).

People and monsters aren't stored in the map files; the game places them when
you enter. Dungeons aren't stored either.

## File formats

- **`MAP.BIN`**: the overworld, one 4-bit value per tile (high nibble first),
  row by row. 0 water, 1 grass, 2 forest, 3 mountains, 4 castle,
  5 signpost/landmark, 6 town, 7 dungeon entrance.
- **`TCD.BIN`**: ten 38 x 18 town/castle layouts, one byte per tile, stored
  column by column, castles first. Values 0-50 are `EGATOWN.BIN` tile numbers
  (24-49 are the letters A-Z used for shop signs). 51-63 mark shop zones and are
  drawn as floor.
- **`EGATILES.BIN`** (52 tiles, 16 px) and **`EGATOWN.BIN`** (51 tiles, 8 px):
  EGA tiles, each pixel row stored as 4 bit planes. Overworld tiles 5 and 8 are
  the second animation frames of the castle and town.
- **`OUT.EXE`** (GOG release) holds the places. To find the place you're standing
  on, the game looks your position up in two 84-byte tables, x at file offset
  `0xEF48` and y at `0xEF9C` (code `0xA3BA`). It takes the name from a table of
  string pointers at `0x106FE` (data segment starts at file offset `0xD680`). The
  same index runs through all three: 1-32 towns, 33-40 castles, 41-48 landmarks,
  49-84 dungeons. Town *n* uses town layout `(n-1) mod 8 + 1` and castle *n* uses
  castle layout `(n-1) mod 2 + 1` (code `0x4E63` / `0x4DBF`). The land is
  `2*(y > 77) + (x > 83)` (code `0xB956`): 0 Lord British (NW), 1 the Feudal
  Lords (NE), 2 the Dark Unknown (SW), 3 Danger and Despair (SE). The map server
  checks every position against `MAP.BIN` before using it.
