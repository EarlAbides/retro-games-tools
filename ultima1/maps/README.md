# Ultima 1 Maps

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
