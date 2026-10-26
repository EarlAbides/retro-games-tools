# Ultima 1 Save Manager

Ultima 1 keeps up to four characters, one per file (`PLAYER1.U1` .. `PLAYER4.U1`).
The game only writes a character's file when you save with **Q** (outdoors only).
This tool snapshots character files so you can roll a character back without
touching the others.

Under the GOG release, DOSBox writes the game's files to `cloud_saves\` (an
overlay on the install folder). Backups go to
`cloud_saves\BACKUPS\<character name>\<timestamp>\PLAYERn.U1`, and a restore
puts the file back into the `PLAYERn.U1` it came from.

GOG Galaxy syncs `cloud_saves` (backups included) with its cloud: before
launch it restores anything missing locally. To delete a character or backup for
good, delete it while the game is running, so Galaxy records the deletion when
you quit. Restored files are stamped with the current time so the sync treats
them as the newest copy.

## Usage

Double-click **`Ultima 1 Saves.bat`** to open the GUI. It lists the characters on
disk with their stats, and the backups grouped by character. Double-click a
character (or use **Character Sheet**) for a full sheet with attributes and
inventory; **View Character** shows the same for a backup. Or use the command line:

```
"Ultima 1 Saves.bat" -Backup  [-Player 1] [-Note "before Mondain"]
"Ultima 1 Saves.bat" -List    [-Character Twatarina]
"Ultima 1 Saves.bat" -Restore -Character Twatarina [-Stamp 2026-10-25_21-05-33]
```

Without `-Player`, `-Backup` backs up every character on disk. Without `-Stamp`,
`-Restore` uses the newest backup. Before every restore, the file being replaced
is snapshotted to `_before-restore` unless it's already backed up (the 10 most
recent are kept). Restore is refused while Ultima's DOSBox is running.

## Character file format

`PLAYERn.U1` is an 820-byte record. The name is ASCII in the first 16 bytes,
and the fields after it are little-endian 16-bit words:

| Offset | Field |
|--------|-------|
| 0x10 | Race (Human, Elf, Dwarf, Bobbit) |
| 0x12 | Class (Fighter, Cleric, Wizard, Thief) |
| 0x14 | Sex (Male, Female) |
| 0x16 | Hit points |
| 0x18-0x22 | Strength, Agility, Stamina, Charisma, Wisdom, Intelligence |
| 0x24 | Coin |
| 0x26 | Experience |
| 0x28 | Food |
| 0x2A, 0x2C, 0x2E | Readied weapon, spell, armour (index into each table) |
| 0x34, 0x36 | Map position X, Y (inferred) |
| 0x54 | Armour counts: Skin, Leather, Chain, Plate, Vacuum suit, Reflect suit |
| 0x60 | Weapon counts: Hands, Dagger .. Blaster, 16 in the game's order |
| 0x80 | Spell counts: Prayer, Open .. Kill, 11 |
| 0x96 | Transport counts: Foot, Horse .. Time Machine, 8 |

Everything except the map position is confirmed against the in-game display
(including Ztats for the inventory). In the inventory tables
the first item (Skin, Hands, Prayer, Foot) is stored as FFFF, meaning always
owned. Nearby monsters are stored from about 0xC4 and aren't decoded.

## Finding the game

The tool looks for the Ultima 1 install folder (the one containing `ULTIMA.EXE`) in this order:

1. `-GameDir <path>`
2. the `ULTIMA1_DIR` environment variable
3. the script's own folder (if you copy it into the install)
4. `Program Files (x86)\GOG Galaxy\Games\Ultima 1`, then `Program Files\GOG Galaxy\Games\Ultima 1`
