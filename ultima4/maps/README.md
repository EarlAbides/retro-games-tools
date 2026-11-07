# Ultima 4 Map

Double-click **`Ultima 4 Map.bat`**. It starts a small local web server (PowerShell, nothing to
install) and opens the map at <http://localhost:8644/>. The server quits on its own a few minutes
after you close the map tab.

- Drag to move, scroll to zoom (or `+` / `-` / `0` to fit). Zoomed out it's a clean terrain map.
  Zoom in and it switches to the game's own tiles. Find a place with the search box (`/`).
- **Your party** shows where the last save left you, with the moons at that moment. It rereads the
  save when you come back to the tab, or click **Refresh**.
- Click a place to mark it **visited** (it gets a green box on the map) and keep notes. Towns and
  castles show their layout; click it to enlarge. Lord British's Castle has two floors (keys `1`, `2`).
- The bar along the bottom gives each tile's position, its sextant reading and its terrain.

Notes are saved as you type to `map-notes.json` next to the script (the previous version is kept
as `.bak`). That file is gitignored. Use **Export notes** for a backup.
`MapServer.ps1` also takes `-GameDir`, `-Port`, `-NotesFile` and `-NoBrowser`.

The page reads the map and tile files straight from your install through the server, so none of
the game's art is stored here.

## Reveals

Everything below starts hidden. Turn on what you want under **Reveals**, and turn it off again
whenever you like. The page remembers your choices.

| Reveal | Shows |
|--------|-------|
| Moongates | Where each one is and when it opens, on the map and in a list. A filled circle was open at your last save, and a dot is where it led. |
| Secret places | Places the map doesn't otherwise name. |
| Hidden items | What to search for and where, on the map and in towns, with any conditions, and a tick when you have it. |
| Townsfolk | In a town's window, who each person is and everything they'll say. Click them on the map or in the list. |
| Dungeon maps | Each dungeon's 8 levels, with what's in every cell. Click a room to see inside it. |

Talk files aren't even fetched until Townsfolk is on. The rest is in the page's memory, so don't go
looking there if you want it to stay a surprise.

**The rest of this file is spoilers.**

## File formats

- **`WORLD.MAP`**: 8 x 8 chunks of 32 x 32 tiles, one byte per tile, 256 x 256 in all.
- **`SHAPES.EGA`**: 256 tiles of 16 x 16, four bits per pixel, high nibble first.
- **`.ULT`**: a town. The 32 x 32 map, then eight 32-byte tables for its people: tile, x, y, a second
  tile, x, y that the map doesn't use, how they move (0 stays, 1 wanders, 0x80 follows), and which
  talk record they use (1-16, 0 for none). Lord British's Castle has one file per floor.
- **`.TLK`**: 16 records of 288 bytes. Three bytes of flags, then twelve strings: name, pronoun,
  description, job, health, two answers, a question, its yes and no replies, and the two keywords
  for those answers.
- **`.DNG`**: 8 levels of 8 x 8 cells, then 16 rooms of 256 bytes (64 in the Abyss). In a cell, the
  high nibble is what it is: 0 corridor, 1 ladder up, 2 ladder down, 3 both, 4 chest, 5 hole above,
  6 hole below, 7 magic orb, 8 trap, 9 fountain, A field, B altar, C door, D room, E secret door, F
  wall. The low nibble says which: the room number, the trap (0 wind, 1 rocks, E pit), the fountain
  (0 plain, 1 healing, 2 acid, 3 curing, 4 poison) or the field (0 poison, 1 energy, 2 fire, 3 sleep).
  In the Abyss, a room's number goes up by 16 every two levels.
- **A room**: 4 floor triggers of 4 bytes (a tile, the trigger's position with x in the high nibble,
  and two positions that turn into that tile), then 16 monster tiles, their x, their y, and 8 party
  positions for each of the 4 directions you can enter from, then the 11 x 11 map at offset 128.
  Stepping on a trigger changes the tiles it names, for instance opening a wall.

## `AVATAR.EXE`

Packed with EXEPACK, behind a small wrapper at the program's entry. The real header is at file
`0x17920`. Addresses of code below are in the unpacked image, whose data segment starts at `0xF0D0`.
The tables below happen to be readable in the packed file too, so the server reads them there and
checks them against `WORLD.MAP`.

- **Places**: x at file `0xFB02` and y at `0xFB22`, in the order of the names at `0x11028`: 15 towns,
  8 dungeons, 8 shrines. A place's id is its location number from the save. Lord British's Castle is
  1 and isn't in the table. Spirituality's entry doesn't point at a shrine on the map.
- **Moongates**: x at file `0xFAD1` and y at `0xFAD9`. The gate at index *n* opens while Trammel is in
  phase *n* (code `0x3A4F`). It takes you to the gate at Felucca's phase (code `0x2AD1`), or to the
  Shrine of Spirituality when both moons are full (code `0x2A9E`). Trammel changes phase every 16 steps
  of the moon counter and Felucca three times as fast (code `0x3AA0`). Those are clock ticks rather than
  your moves, so the map only says what the save recorded.
- **Hidden items**: the Search command's table at file `0x11BCB` (code `0x915B`), 5 bytes each:
  location, x, y, and the address of what happens. Each handler sets its conditions. Mandrake,
  nightshade, the Skull and the Black Stone need both moons new, and the mystic gear needs all eight
  virtues at Avatarhood. The 8 runes share a handler that looks up the bit by location at file `0x11BAF`.
- **Stones in dungeons**: the bit is `1 << (location - 17)`, and the search gives nothing in Hythloth or
  the Abyss (code `0xB93F`).
- **Quit & Save**: code `0x6F4D`.
