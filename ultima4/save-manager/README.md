# Ultima 4 Save Manager

Ultima 4 has one saved game, kept in four files. This tool snapshots all four together, so
you can roll back to an earlier point or keep a game aside and start another.

The game only saves when you press **Q**, outdoors or in a dungeon. In a town it says "Not
Here!". Backups are of your last save, not the game in progress.

Under the GOG release, DOSBox writes the game's files to `cloud_saves\` (an overlay on the
install folder). A file that isn't there yet comes from the install folder instead, so a backup
takes each file from wherever the game would read it. Backups go to
`cloud_saves\BACKUPS\<Avatar's name>\<timestamp>\`, and a restore puts all four files in
`cloud_saves\`.

GOG Galaxy syncs `cloud_saves` (backups included) with its cloud: before launch it restores
anything missing locally. To delete a backup for good, delete it while the game is running, so
Galaxy records the deletion when you quit. Restored files are stamped with the current time so
the sync treats them as the newest copy.

## Usage

Double-click **`Ultima 4 Saves.bat`** to open the GUI. It shows the game on disk with your party,
and the backups grouped by the Avatar's name. **Party Sheet** (or double-clicking the party) shows
virtues, stones, runes, quest items and everything you're carrying. **View Party** shows the same
for a backup. Or use the command line:

```
"Ultima 4 Saves.bat" -Backup  [-Note "before Hythloth"]
"Ultima 4 Saves.bat" -List    [-Game TestSubject]
"Ultima 4 Saves.bat" -Restore -Game TestSubject [-Stamp 2026-11-05_21-05-33]
```

Without `-Stamp`, `-Restore` uses the newest backup. Before every restore, the game being replaced
is snapshotted to `_before-restore` unless it's already backed up (the 10 most recent are kept).
Restore is refused while Ultima's DOSBox is running.

## The save files

| File | Size | Written | Holds |
|------|------|---------|-------|
| `PARTY.SAV` | 502 | Q | Party, belongings, position, moons |
| `MONSTERS.SAV` | 256 | Q | Monsters around you, on the surface or in a dungeon |
| `DNGMAP.SAV` | 512 | Q in a dungeon | The dungeon you're in, read back on load |
| `OUTMONST.SAV` | 256 | Entering a town or dungeon | Surface monsters, read back when you come out |

`AVATAR.EXE` shows the Q rule at code `0x6F4D`. Since `OUTMONST.SAV` changes without a save, the
"Current?" column in the GUI compares only `PARTY.SAV` and `MONSTERS.SAV`. `PARTY.SAV` holds the
move count, so it's different after every save.

The install's own `PARTY.SAV` is a template with no party in it (`PARTY.NEW` is identical), so
a save with no party members counts as no game. The title program's **Initiate New Game**
overwrites the saved game, so back up first if you want to keep it.

## `PARTY.SAV`

Little-endian. Words are 16 bits unless noted.

| Offset | Field |
|--------|-------|
| 0x00 | Unknown, 32 bits |
| 0x04 | Moves, 32 bits |
| 0x08 | 8 party records of 39 bytes (below) |
| 0x140 | Food in hundredths, 32 bits |
| 0x144 | Gold |
| 0x146 | Virtues, 8 words: Honesty, Compassion, Valor, Justice, Sacrifice, Honor, Spirituality, Humility. 0 means Avatarhood in that virtue |
| 0x156 | Torches, gems, keys, sextants |
| 0x15E | Armour counts, 8 |
| 0x16E | Weapon counts, 16 |
| 0x18E | Reagent counts, 8 |
| 0x19E | Mixed spell counts, 26, A to Z |
| 0x1D2 | Quest item bits: 0x01 Skull, 0x02 Skull destroyed, 0x04 Candle, 0x08 Book, 0x10 Bell, 0x20/0x40/0x80 key parts, 0x100 Horn, 0x200 Wheel |
| 0x1D4, 0x1D5 | Surface x, y (bytes) |
| 0x1D6 | Stone bits (byte), Blue at bit 0 to Black at bit 7 |
| 0x1D7 | Rune bits (byte), in virtue order |
| 0x1D8 | Number in the party |
| 0x1DA | Transport (the tile you're shown as; 0x1F is on foot) |
| 0x1DC | Balloon state or torch time |
| 0x1DE, 0x1E0 | Trammel and Felucca phase, 0-7 |
| 0x1E2 | Ship's hull |
| 0x1EE, 0x1EF | Dungeon x, y (bytes) |
| 0x1F0 | Facing in a dungeon |
| 0x1F2 | Dungeon level, from 0 |
| 0x1F4 | Location: 0 surface, 1-16 towns, 17-24 dungeons |

A party record:

| Offset | Field |
|--------|-------|
| 0 | HP, max HP, experience, strength, dexterity, intelligence, magic points (words) |
| 14 | Unknown word |
| 16, 18 | Readied weapon, worn armour |
| 20 | Name, 16 bytes |
| 36 | Sex: 0x0B male, 0x0C female |
| 37 | Class: Mage, Bard, Fighter, Druid, Tinker, Paladin, Ranger, Shepherd |
| 38 | Status letter: G, P, S, D |

The first record is the Avatar. Records past the party count hold the companions you haven't
recruited yet, so the tool doesn't show them. Level is max HP / 100.

The item, weapon, armour, reagent, spell and stone names are in `AVATAR.EXE`'s own order. The
offsets of the moons, items, stones, runes, moves, reagent time and location are confirmed by the
game's code. The sextant reading is each coordinate as two letters, y then x.

## Finding the game

The tool looks for the Ultima 4 install folder (the one containing `AVATAR.EXE`) in this order:

1. `-GameDir <path>`
2. the `ULTIMA4_DIR` environment variable
3. the script's own folder (if you copy it into the install)
4. `Program Files (x86)\GOG Galaxy\Games\Ultima 4 - Quest of the Avatar`, then the same under `Program Files`
