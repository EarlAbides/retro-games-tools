# Ultima 1 Maps

## Interactive map

Double-click **`Ultima 1 Map.bat`**. It starts a small local web server (PowerShell,
nothing to install) and opens the map at <http://localhost:8643/>. The server quits on
its own a few minutes after you close the map tab.

- One land at a time, its name at the top. Switch with the tabs or keys `1`-`4`. A
  yellow dot on a tab means one of your characters is there. It opens on your
  character's land, and each land remembers where you left it.
- Drag to move, scroll to zoom (or `+` / `-` / `0` to fit). Zoomed out it's a clean
  terrain map. Zoom in and it switches to the game's own tiles.
- All 84 places are labeled with their names from the game: 32 towns, 8 castles,
  8 landmarks and signposts, and 36 dungeons. Find one with the search box (`/`);
  picking a place in another land switches to it.
- **Your characters** show where each save left them, with a yellow flag. The list
  says which land they're in and how far they are from the nearest place. It rereads the saves when you come
  back to the tab, or click **Refresh**.
- Click a place to see which land it's in, mark it **visited** (it gets a green box
  on the map), and keep notes. Towns and castles show their **layout**; click it to
  enlarge. The 32 towns share 8 layouts and the 8 castles share 2, and it lists
  which other places share the one you're looking at.
- **Dungeons** show a map of level 1. Click it or **All 10 levels** for every level
  (keys `1`-`9`, `0` for 10, arrows for next and previous). Each level shows its walls, doors,
  secret doors, force fields and ladders, where you arrive, and the shortest way to the
  ladder down. Each character gets their own dungeons. If you have more than one, pick
  whose to show in the dungeon window.
- Every label type and a tile grid can be turned on and off.

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
you enter. Dungeons aren't stored either. The game builds them as you go (see below), so
only the interactive map shows them.

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
- **Dungeons** aren't in any file. `OUT.EXE` builds each level when you arrive on it
  (code `0x4761`; addresses here are offsets into the code, after the 0x200-byte header),
  seeding its random numbers with `x*5 + y*3 + level*17 + s` (code `0x45C8`). x and y are
  the dungeon's map position, and `s` is the word at save offset `0x32`, which is set when
  the character is made and never changes. So a dungeon is the same on every visit, but
  each character has their own. The generator (`random(lo, hi)` at `0xB4C3`: add `0x9248`,
  rotate right 3, keep 10 bits, then subtract `hi - lo` until it fits) fills an 11 x 11 grid:
  - a wall all round;
  - columns x = 2, 4, 6, 8, rows 1-9: `random(1, 4) - 1`, so 0 open, 1 wall, 2 secret
    door, 3 door. Odd columns stay open corridors;
  - `2*level + 1` times: a force field (8) if `random(1, 255) > 160`, else a wall, on a spot
    picked by `random(1, 16)` from a table of 16 positions, x at data `0x3820` and y at
    `0x3840`. Even levels swap the x and y;
  - ladders: odd levels have up (7) at 7,3 and down (6) at 3,7, even levels the other way
    round. Level 1 has its up ladder (the way out) at 1,1, where you arrive facing +y.
    Level 10 has no ladder down.

  Then the game reseeds from the clock before placing monsters, chests and coffins, so those
  change. You can't walk into walls, secret doors or force fields, or from one door
  straight onto another (code `0x3F7F`). Inform and search (`I`) turns a secret door you
  face into a door. There's no compass in the dungeon. Turning right goes from -x to -y,
  so the map is drawn with x across and y down, which keeps left and right the same as in the game.
