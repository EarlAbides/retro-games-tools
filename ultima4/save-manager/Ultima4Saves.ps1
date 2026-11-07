<#
  Ultima 4 save manager - backs up / restores the saved game that DOSBox writes into cloud_saves.

  No arguments  -> opens the GUI.
  Command line  -> Ultima4Saves.ps1 -Backup  [-Note "before Hythloth"]
                   Ultima4Saves.ps1 -List    [-Game TestSubject]
                   Ultima4Saves.ps1 -Restore -Game TestSubject [-Stamp 2026-11-05_21-05-33]
                   (no -Stamp = newest backup)

  Ultima 4 has one saved game, spread over four files. They only make sense together, so a
  backup always holds all four and a restore always puts all four back.
  Layout:  cloud_saves\BACKUPS\<avatar name>\<yyyy-MM-dd_HH-mm-ss>\*.SAV (+ note.txt)

  Game folder: -GameDir, else $env:ULTIMA4_DIR, else the script's own folder
  if it sits in the install, else the default GOG Galaxy install path.
#>
[CmdletBinding()]
param(
    [switch]$Backup,
    [switch]$Restore,
    [switch]$List,
    [string]$Game,
    [string]$Stamp,
    [string]$Note,
    [string]$GameDir
)

$ErrorActionPreference = 'Stop'

function Resolve-GameDir {
    $install = 'GOG Galaxy\Games\Ultima 4 - Quest of the Avatar'
    $candidates = @($GameDir, $env:ULTIMA4_DIR, $PSScriptRoot,
                    (Join-Path ${env:ProgramFiles(x86)} $install),
                    (Join-Path $env:ProgramFiles $install))
    if ($GameDir) { $candidates = @($GameDir) }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'AVATAR.EXE'))) { return (Resolve-Path $c).Path }
    }
    $msg = 'Ultima 4 install not found. Pass -GameDir or set ULTIMA4_DIR to the folder containing AVATAR.EXE.'
    if ($Backup -or $Restore -or $List) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Ultima 4 Save Manager', 'OK', 'Error')
    exit 1
}

$Root       = Resolve-GameDir
$PlayDir    = Join-Path $Root 'cloud_saves'               # DOSBox overlay on C:\ - where the game actually writes
$BackupRoot = Join-Path $Root 'cloud_saves\BACKUPS'
$StampFmt   = 'yyyy-MM-dd_HH-mm-ss'
$AutoSlot   = '_before-restore'                           # safety net written before every restore
$AutoKeep   = 10
$SaveFiles  = @('PARTY.SAV', 'MONSTERS.SAV', 'OUTMONST.SAV', 'DNGMAP.SAV')

# ---------------------------------------------------------------- PARTY.SAV

# All in the order AVATAR.EXE lists them.
$Classes  = @('Mage', 'Bard', 'Fighter', 'Druid', 'Tinker', 'Paladin', 'Ranger', 'Shepherd')
$Weapons  = @('Hands', 'Staff', 'Dagger', 'Sling', 'Mace', 'Axe', 'Sword', 'Bow', 'Crossbow', 'Flaming Oil',
              'Halberd', 'Magic Axe', 'Magic Sword', 'Magic Bow', 'Magic Wand', 'Mystic Sword')
$Armours  = @('Skin', 'Cloth', 'Leather', 'Chain Mail', 'Plate Mail', 'Magic Chain', 'Magic Plate', 'Mystic Robe')
$Reagents = @('Sulfur Ash', 'Ginseng', 'Garlic', 'Spider Silk', 'Blood Moss', 'Black Pearl', 'Nightshade', 'Mandrake')
$Spells   = @('Awaken', 'Blink', 'Cure', 'Dispel', 'Energy', 'Fireball', 'Gate', 'Heal', 'Iceball', 'Jinx', 'Kill', 'Light',
              'Magic Missile', 'Negate', 'Open', 'Protection', 'Quickness', 'Resurrect', 'Sleep', 'Tremor', 'Undead',
              'View', 'Winds', 'X-it', 'Y-up', 'Z-down')
$Virtues  = @('Honesty', 'Compassion', 'Valor', 'Justice', 'Sacrifice', 'Honor', 'Spirituality', 'Humility')
$Stones   = @('Blue', 'Yellow', 'Red', 'Green', 'Orange', 'Purple', 'White', 'Black')   # bit 0 first
$Moons    = @('New', 'Waxing crescent', 'First quarter', 'Waxing gibbous', 'Full', 'Waning gibbous', 'Last quarter', 'Waning crescent')
# Location numbers: 0 is the surface, 1-16 towns, 17-24 dungeons.
$Locations = @('Surface', "Lord British's Castle", 'The Lycaeum', 'Empath Abbey', 'Serpents Hold', 'Moonglow', 'Britain', 'Jhelom', 'Yew',
               'Minoc', 'Trinsic', 'Skara Brae', 'Magincia', 'Paws', 'Buccaneers Den', 'Vesper', 'Cove',
               'Deceit', 'Despise', 'Destard', 'Wrong', 'Covetous', 'Shame', 'Hythloth', 'The Abyss')

function Read-Party([string]$Path) {
    # A flat 502-byte record, little-endian. Layout in README.md.
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -ne 502) { return $null }
    $w = { param($o) [int][BitConverter]::ToUInt16($b, $o) }
    $names = { param($table, $offset) $i = 0; foreach ($n in $table) { $c = & $w ($offset + 2 * $i); if ($c) { [pscustomobject]@{ Item = $n; Count = $c } }; $i++ } }
    $bits = { param($table, $value) $i = 0; foreach ($n in $table) { if ($value -band (1 -shl $i)) { $n }; $i++ } }

    $count = & $w 0x1D8
    if ($count -gt 8) { return $null }
    $members = foreach ($i in 0..7) {
        if ($i -ge $count) { break }
        $o = 8 + $i * 39
        $end = [Array]::IndexOf($b, [byte]0, $o + 20, 16); if ($end -lt 0) { $end = $o + 36 }
        $cls = $b[$o + 37]; $wp = & $w ($o + 16); $ar = & $w ($o + 18)
        $maxHp = & $w ($o + 2)
        [pscustomobject]@{
            Name   = [Text.Encoding]::ASCII.GetString($b, $o + 20, $end - ($o + 20))
            Sex    = $(switch ($b[$o + 36]) { 0x0B { 'Male' } 0x0C { 'Female' } default { '?' } })
            Class  = $(if ($cls -lt 8) { $Classes[$cls] } else { "?$cls" })
            Status = $(switch ([char]$b[$o + 38]) { 'G' { 'Good' } 'P' { 'Poisoned' } 'S' { 'Asleep' } 'D' { 'Dead' } default { '?' } })
            Hp     = & $w $o
            MaxHp  = $maxHp
            Level  = [math]::Min(8, [math]::Max(1, [math]::Floor($maxHp / 100)))
            Xp     = & $w ($o + 4)
            Str    = & $w ($o + 6)
            Dex    = & $w ($o + 8)
            Int    = & $w ($o + 10)
            Mp     = & $w ($o + 12)
            Weapon = $(if ($wp -lt 16) { $Weapons[$wp] } else { "?$wp" })
            Armour = $(if ($ar -lt 8) { $Armours[$ar] } else { "?$ar" })
        }
    }

    $loc = & $w 0x1F4
    $items = & $w 0x1D2
    $x = $b[0x1D4]; $y = $b[0x1D5]
    $level = & $w 0x1F2
    $where = if ($loc -eq 0) { 'Surface' } elseif ($loc -lt $Locations.Count) { $Locations[$loc] } else { "Place $loc" }
    if ($loc -ge 17 -and $loc -le 24) { $where = "$where, level $($level + 1)" }

    $equipment = @()
    foreach ($e in @(@('Torches', 0x156), @('Gems', 0x158), @('Keys', 0x15A), @('Sextants', 0x15C))) {
        $n = & $w $e[1]; if ($n) { $equipment += [pscustomobject]@{ Item = $e[0]; Count = $n } }
    }
    $quest = @()
    if ($items -band 0x10)  { $quest += 'Bell' }
    if ($items -band 0x08)  { $quest += 'Book' }
    if ($items -band 0x04)  { $quest += 'Candle' }
    if ($items -band 0x20)  { $quest += 'Key part C' }
    if ($items -band 0x40)  { $quest += 'Key part L' }
    if ($items -band 0x80)  { $quest += 'Key part T' }
    if ($items -band 0x100) { $quest += 'Horn' }
    if ($items -band 0x200) { $quest += 'Wheel' }
    if ($items -band 0x01)  { $quest += 'Skull' }

    [pscustomobject]@{
        Name      = $(if ($members) { @($members)[0].Name } else { '' })
        Count     = $count
        Members   = @($members)
        Moves     = [BitConverter]::ToUInt32($b, 4)
        Food      = [math]::Floor([BitConverter]::ToInt32($b, 0x140) / 100)
        Gold      = & $w 0x144
        Karma     = @(0..7 | ForEach-Object { & $w (0x146 + 2 * $_) })
        Equipment = $equipment
        Armours   = @(& $names $Armours 0x15E)
        Weapons   = @(& $names $Weapons 0x16E)
        Reagents  = @(& $names $Reagents 0x18E)
        Mixtures  = @(& $names $Spells 0x19E)
        Quest     = $quest
        Stones    = @(& $bits $Stones $b[0x1D6])
        Runes     = @(& $bits $Virtues $b[0x1D7])
        X         = $x
        Y         = $y
        # The sextant reads each coordinate as two letters.
        Sextant   = "{0}'{1}`" {2}'{3}`"" -f [char](65 + ($y -shr 4)), [char](65 + ($y -band 15)), [char](65 + ($x -shr 4)), [char](65 + ($x -band 15))
        Location  = $loc
        Where     = $where
        Trammel   = $Moons[(& $w 0x1DE) -band 7]
        Felucca   = $Moons[(& $w 0x1E0) -band 7]
        Hull      = & $w 0x1E2
    }
}

# ---------------------------------------------------------------- core

function Get-SaveFingerprint([string]$Folder, [string]$Fallback) {
    # PARTY.SAV changes on every save (it holds the move count), and MONSTERS.SAV is written with it.
    # OUTMONST.SAV is left out because the game rewrites it whenever you enter a town, without saving.
    # Plain .NET rather than Get-FileHash, which isn't always loadable (e.g. when PSModulePath points at pwsh 7).
    $all = New-Object System.IO.MemoryStream
    foreach ($f in 'PARTY.SAV', 'MONSTERS.SAV') {
        $p = Join-Path $Folder $f
        if ($Fallback -and -not (Test-Path -LiteralPath $p)) { $p = Join-Path $Fallback $f }
        if (Test-Path -LiteralPath $p) { $d = [IO.File]::ReadAllBytes($p); $all.Write($d, 0, $d.Length) }
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($all.ToArray())) }
    finally { $sha.Dispose() }
}

function Get-FolderName([string]$Name) {
    $clean = ($Name.ToCharArray() | ForEach-Object { if ([IO.Path]::GetInvalidFileNameChars() -contains $_) { '_' } else { $_ } }) -join ''
    $clean = $clean.Trim().Trim('.')
    if (-not $clean -or $clean -eq $AutoSlot) { 'Avatar' } else { $clean }
}

function Get-CurrentGame {
    # Effective view of C:\ inside DOSBox: an overlay file wins, else the install's own copy. The install's
    # PARTY.SAV is a template with no party in it, so "no members" means no game has been saved yet.
    $files = foreach ($f in $SaveFiles) {
        @((Join-Path $PlayDir $f), (Join-Path $Root $f)) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    $party = @($files | Where-Object { (Split-Path $_ -Leaf) -eq 'PARTY.SAV' })
    if (-not $party) { return $null }
    $info = Read-Party $party[0]
    if (-not $info -or $info.Count -lt 1) { return $null }
    [pscustomobject]@{
        Files       = @($files)
        Info        = $info
        Folder      = Get-FolderName $info.Name
        Saved       = (Get-Item -LiteralPath $party[0]).LastWriteTime
        Fingerprint = Get-SaveFingerprint $PlayDir $Root
    }
}

function Test-DosBoxRunning {
    # Only an Ultima 4 DOSBox counts; a process whose path we can't read is assumed to be ours.
    [bool](Get-Process -Name 'DOSBox' -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Path -or $_.Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
}

function New-Backup($Cur, [string]$NoteText, [string]$Folder = $Cur.Folder) {
    $dest = Join-Path (Join-Path $BackupRoot $Folder) (Get-Date -Format $StampFmt)
    while (Test-Path $dest) { Start-Sleep -Milliseconds 1100; $dest = Join-Path (Split-Path $dest) (Get-Date -Format $StampFmt) }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($f in $Cur.Files) { Copy-Item -LiteralPath $f -Destination (Join-Path $dest (Split-Path $f -Leaf)) }
    if (-not [string]::IsNullOrWhiteSpace($NoteText)) {
        Set-Content -LiteralPath (Join-Path $dest 'note.txt') -Value $NoteText.Trim() -Encoding UTF8
    }
    $dest
}

function Get-Backups([string]$FolderFilter) {
    if (-not (Test-Path $BackupRoot)) { return @() }
    $folders = Get-ChildItem -Path $BackupRoot -Directory
    if ($FolderFilter) { $folders = $folders | Where-Object { $_.Name -ieq $FolderFilter } }
    foreach ($s in $folders) {
        foreach ($d in (Get-ChildItem -Path $s.FullName -Directory)) {
            $party = Join-Path $d.FullName 'PARTY.SAV'
            if (-not (Test-Path -LiteralPath $party)) { continue }
            $when = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($d.Name, $StampFmt, $null, 'None', [ref]$when)) { $when = $d.CreationTime }
            $notePath = Join-Path $d.FullName 'note.txt'
            $noteVal  = ''
            if (Test-Path $notePath) { $noteVal = (Get-Content -LiteralPath $notePath -Raw).Trim() }
            [pscustomobject]@{
                Folder      = $s.Name
                Stamp       = $d.Name
                When        = $when
                Note        = $noteVal
                Path        = $d.FullName
                Info        = Read-Party $party
                Fingerprint = Get-SaveFingerprint $d.FullName
            }
        }
    }
}

function Restore-Backup($B) {
    if (Test-DosBoxRunning) { throw 'DOSBox is running. Quit Ultima first - DOSBox caches files and would clobber the restore.' }

    # Safety net: snapshot the game on disk now, unless it's already backed up somewhere.
    $cur = Get-CurrentGame
    $auto = $null
    if ($cur -and -not (Get-Backups | Where-Object { $_.Fingerprint -eq $cur.Fingerprint })) {
        $auto = New-Backup $cur 'Automatic snapshot taken before a restore' $AutoSlot
        Get-Backups $AutoSlot | Sort-Object When -Descending | Select-Object -Skip $AutoKeep |
            ForEach-Object { Remove-Item -LiteralPath $_.Path -Recurse -Force }
    }

    New-Item -ItemType Directory -Path $PlayDir -Force | Out-Null
    foreach ($name in $SaveFiles) {
        $src = Join-Path $B.Path $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        # Stamp it as new: Copy-Item keeps the backup's old time, and GOG Galaxy's cloud sync could treat its copy as newer.
        $f = Copy-Item -LiteralPath $src -Destination (Join-Path $PlayDir $name) -Force -PassThru
        $f.LastWriteTime = Get-Date
    }
    $auto
}

function Format-Age([datetime]$When) {
    $span = (Get-Date) - $When
    if ($span.TotalMinutes -lt 1) { return 'just now' }
    if ($span.TotalHours   -lt 1) { return '{0} min ago' -f [int]$span.TotalMinutes }
    if ($span.TotalDays    -lt 1) { return '{0} hr ago' -f [int][math]::Floor($span.TotalHours) }
    if ($span.TotalDays    -lt 60) { return '{0} days ago' -f [int][math]::Floor($span.TotalDays) }
    '{0} months ago' -f [int][math]::Floor($span.TotalDays / 30)
}

# ---------------------------------------------------------------- command line

if ($Backup -or $Restore -or $List) {
    try {
        if ($Backup) {
            if (Test-DosBoxRunning) { Write-Warning 'DOSBox is running - save with Q first (outdoors or in a dungeon; the game refuses in towns).' }
            $cur = Get-CurrentGame
            if (-not $cur) { throw "No saved game found in $PlayDir." }
            Write-Host "Backed up $($cur.Folder) to $(New-Backup $cur $Note)"
        }
        elseif ($List) {
            $cur = Get-CurrentGame
            Get-Backups $Game | Sort-Object Folder, When |
                Select-Object @{n = 'Game'; e = { $_.Folder } }, Stamp,
                              @{n = 'Current'; e = { if ($cur -and $cur.Fingerprint -eq $_.Fingerprint) { '<==' } else { '' } } },
                              @{n = 'Moves'; e = { $_.Info.Moves } }, @{n = 'Where'; e = { $_.Info.Where } },
                              @{n = 'Party'; e = { $_.Info.Count } }, Note |
                Format-Table -AutoSize
        }
        elseif ($Restore) {
            if (-not $Game) { throw 'Give -Game (the backup folder name, usually the Avatar''s name).' }
            $all = @(Get-Backups $Game | Sort-Object When -Descending)
            if ($Stamp) { $all = @($all | Where-Object { $_.Stamp -eq $Stamp }) }
            if (-not $all) { throw "No backup found for game '$Game' $Stamp" }
            $auto = Restore-Backup $all[0]
            if ($auto) { Write-Host "Previous game saved to $auto" }
            Write-Host "Restored $($all[0].Folder) \ $($all[0].Stamp)"
        }
    }
    catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
    exit 0
}

# ---------------------------------------------------------------- GUI

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$font     = New-Object System.Drawing.Font('Segoe UI', 9.5)
$boldFont = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Ultima 4 Save Manager'
$form.Size = New-Object System.Drawing.Size(1060, 720)
$form.MinimumSize = New-Object System.Drawing.Size(760, 540)
$form.StartPosition = 'CenterScreen'
$form.Font = $font
$form.AutoScaleMode = 'Dpi'
$icon = Join-Path $Root 'goggame-1207658962.ico'
if (Test-Path $icon) { $form.Icon = New-Object System.Drawing.Icon($icon) }

# --- status strip at top
$lblCurrent = New-Object System.Windows.Forms.Label
$lblCurrent.Dock = 'Top'; $lblCurrent.Height = 34; $lblCurrent.Font = $boldFont
$lblCurrent.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 0)

# --- current game + backup row
$pnlGame = New-Object System.Windows.Forms.GroupBox
$pnlGame.Text = 'Saved game on disk'
$pnlGame.Dock = 'Top'; $pnlGame.AutoSize = $true
$pnlGame.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 6)

$tbl = New-Object System.Windows.Forms.TableLayoutPanel
$tbl.Dock = 'Fill'; $tbl.AutoSize = $true; $tbl.ColumnCount = 1; $tbl.RowCount = 3

$lblGame = New-Object System.Windows.Forms.Label
$lblGame.AutoSize = $true; $lblGame.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 6)

$lvParty = New-Object System.Windows.Forms.ListView
$lvParty.View = 'Details'; $lvParty.FullRowSelect = $true; $lvParty.MultiSelect = $false
$lvParty.HideSelection = $false; $lvParty.Dock = 'Fill'
$lvParty.Height = ($font.Height + 8) * 10                # header + 8 members, at any DPI
foreach ($c in @(@('Name', 130), @('Class', 90), @('Status', 80), @('Lvl', 40), @('HP', 90), @('MP', 45), @('Exp', 60),
                 @('Str/Dex/Int', 100), @('Weapon', 130), @('Armour', 120))) {
    [void]$lvParty.Columns.Add($c[0], $c[1])
}

$row = New-Object System.Windows.Forms.TableLayoutPanel
$row.Dock = 'Fill'; $row.AutoSize = $true; $row.ColumnCount = 4; $row.RowCount = 1
foreach ($style in @('AutoSize', 'Percent', 'AutoSize', 'AutoSize')) {
    $cs = New-Object System.Windows.Forms.ColumnStyle($style)
    if ($style -eq 'Percent') { $cs.Width = 100 }
    [void]$row.ColumnStyles.Add($cs)
}
$lblNote = New-Object System.Windows.Forms.Label
$lblNote.Text = 'Note (optional):'; $lblNote.AutoSize = $true; $lblNote.Anchor = 'Left'
$txtNote = New-Object System.Windows.Forms.TextBox
$txtNote.Anchor = 'Left, Right'
function New-RowBtn([string]$Text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.AutoSize = $true
    $b.Padding = New-Object System.Windows.Forms.Padding(10, 2, 10, 2); $b
}
$btnSheet  = New-RowBtn 'Party Sheet'
$btnBackup = New-RowBtn 'Back Up Game'
$row.Controls.Add($lblNote, 0, 0)
$row.Controls.Add($txtNote, 1, 0)
$row.Controls.Add($btnSheet, 2, 0)
$row.Controls.Add($btnBackup, 3, 0)

$tbl.Controls.Add($lblGame, 0, 0)
$tbl.Controls.Add($lvParty, 0, 1)
$tbl.Controls.Add($row, 0, 2)
$pnlGame.Controls.Add($tbl)

# --- backups list
$lv = New-Object System.Windows.Forms.ListView
$lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $true
$lv.HideSelection = $false; $lv.ShowGroups = $true
foreach ($c in @(@('Saved', 180), @('Age', 100), @('Current?', 75), @('Moves', 70), @('Where', 160), @('Party', 50),
                 @('Gold', 60), @('Food', 60), @('Note', 240))) {
    [void]$lv.Columns.Add($c[0], $c[1])
}

# --- bottom buttons
$pnlButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlButtons.Dock = 'Bottom'; $pnlButtons.Height = 46
$pnlButtons.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 0)
function New-Btn([string]$Text, [int]$W = 140) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = $W; $b.Height = 30
    [void]$pnlButtons.Controls.Add($b); $b
}
$btnRestore = New-Btn 'Restore Selected' 150
$btnView    = New-Btn 'View Party'
$btnDelete  = New-Btn 'Delete Selected'
$btnOpen    = New-Btn 'Open Folder'
$btnRefresh = New-Btn 'Refresh' 100

$status = New-Object System.Windows.Forms.StatusStrip
$statusLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLbl.Spring = $true; $statusLbl.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($statusLbl)

# Fill must be added first so docked Top/Bottom controls claim their space around it.
$form.Controls.AddRange(@($lv, $pnlGame, $lblCurrent, $pnlButtons, $status))

function Set-Status([string]$Msg) { $statusLbl.Text = $Msg }

function Update-View {
    $running = Test-DosBoxRunning
    if ($running) {
        $lblCurrent.Text = 'DOSBox is RUNNING  -  save with Q (outdoors or in a dungeon) before backing up; restore is disabled'
        $lblCurrent.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblCurrent.Text = 'Ultima is not running'
        $lblCurrent.ForeColor = [System.Drawing.SystemColors]::ControlText
    }
    $btnRestore.Enabled = -not $running

    $cur = Get-CurrentGame
    $lvParty.BeginUpdate()
    $lvParty.Items.Clear()
    if ($cur) {
        $i = $cur.Info
        $lblGame.Text = ('{0}   -   {1:N0} moves   -   {2}, {3}   -   {4:N0} gold, {5:N0} food   -   saved {6:ddd MMM d, h:mm tt} ({7})' -f
            $i.Name, $i.Moves, $i.Where, $i.Sextant, $i.Gold, $i.Food, $cur.Saved, (Format-Age $cur.Saved))
        foreach ($m in $i.Members) {
            $item = New-Object System.Windows.Forms.ListViewItem($m.Name)
            foreach ($v in @($m.Class, $m.Status, $m.Level, ('{0} / {1}' -f $m.Hp, $m.MaxHp), $m.Mp, $m.Xp,
                             ('{0} / {1} / {2}' -f $m.Str, $m.Dex, $m.Int), $m.Weapon, $m.Armour)) {
                [void]$item.SubItems.Add([string]$v)
            }
            [void]$lvParty.Items.Add($item)
        }
    } else {
        $lblGame.Text = 'No saved game yet. Start one in Ultima, then press Q to save.'
    }
    $lvParty.EndUpdate()
    $btnSheet.Enabled = [bool]$cur
    $btnBackup.Enabled = [bool]$cur

    $all = @(Get-Backups)
    $keep = @($lv.SelectedItems | ForEach-Object { $_.Tag.Path })
    $lv.BeginUpdate()
    $lv.Items.Clear(); $lv.Groups.Clear()
    # Games ordered by most recent activity; auto-snapshots last.
    $byFolder = $all | Group-Object Folder | Sort-Object @{e = { $_.Name -eq $AutoSlot } }, @{e = { ($_.Group | Measure-Object When -Maximum).Maximum }; Descending = $true }
    foreach ($g in $byFolder) {
        $header = if ($g.Name -eq $AutoSlot) { "Auto snapshots before restore ($($g.Count))" } else { "$($g.Name)  ($($g.Count))" }
        $grp = New-Object System.Windows.Forms.ListViewGroup($g.Name, $header)
        [void]$lv.Groups.Add($grp)
        foreach ($b in ($g.Group | Sort-Object When -Descending)) {
            $item = New-Object System.Windows.Forms.ListViewItem(('{0:yyyy-MM-dd  h:mm:ss tt}' -f $b.When), $grp)
            $isCur = $cur -and $cur.Fingerprint -eq $b.Fingerprint
            $note = $b.Note
            if ($g.Name -eq $AutoSlot -and $b.Info) { $note = "$($b.Info.Name): $note" }
            foreach ($v in @((Format-Age $b.When), $(if ($isCur) { '  <==' } else { '' }), $b.Info.Moves, $b.Info.Where,
                             $b.Info.Count, $b.Info.Gold, $b.Info.Food, $note)) {
                [void]$item.SubItems.Add([string]$v)
            }
            if ($isCur) { $item.Font = $boldFont; $item.ForeColor = [System.Drawing.Color]::DarkGreen }
            $item.Tag = $b
            [void]$lv.Items.Add($item)
            if ($keep -contains $b.Path) { $item.Selected = $true }
        }
    }
    $lv.EndUpdate()
    if (-not $cur) { Set-Status "No saved game yet. (Looking in $PlayDir)" }
    elseif (-not $all) { Set-Status "No backups yet. Click Back Up Game. (Stored in $BackupRoot)" }
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ultima 4 Save Manager', 'OK', 'Error') }
}

function Show-PartySheet($Info, [string]$Source) {
    if (-not $Info) { throw "Couldn't read that saved game." }
    $sheet = New-Object System.Windows.Forms.Form
    $sheet.Text = "$($Info.Name) - Party Sheet"
    $sheet.Size = New-Object System.Drawing.Size(900, 780)
    $sheet.MinimumSize = New-Object System.Drawing.Size(720, 620)
    $sheet.StartPosition = 'CenterParent'; $sheet.Font = $font; $sheet.AutoScaleMode = 'Dpi'
    $sheet.MinimizeBox = $false; $sheet.ShowInTaskbar = $false; $sheet.Icon = $form.Icon

    $lay = New-Object System.Windows.Forms.TableLayoutPanel
    $lay.Dock = 'Fill'; $lay.ColumnCount = 1; $lay.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)

    function Add-Row($Control, [switch]$Fill) {
        # -Fill: this row takes the leftover height
        $lay.RowCount++
        [void]$lay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($(if ($Fill) { 'Percent' } else { 'AutoSize' }), 100)))
        $Control.Dock = 'Fill'
        $lay.Controls.Add($Control, 0, $lay.RowCount - 1)
    }
    function New-SheetLabel([string]$Text, $Font, $Color = [System.Drawing.SystemColors]::ControlText) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text; $l.AutoSize = $true; $l.Font = $Font; $l.ForeColor = $Color; $l
    }

    $accent = [System.Drawing.Color]::FromArgb(139, 30, 30)
    Add-Row (New-SheetLabel $Info.Name (New-Object System.Drawing.Font('Palatino Linotype', 20, [System.Drawing.FontStyle]::Bold)) $accent)
    $sub = '{0}    -    {1}    -    Trammel: {2}, Felucca: {3}' -f $Info.Where, $Info.Sextant, $Info.Trammel, $Info.Felucca
    Add-Row (New-SheetLabel $sub (New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Italic)) ([System.Drawing.SystemColors]::GrayText))

    # vitals tiles
    $tiles = New-Object System.Windows.Forms.TableLayoutPanel
    $tiles.ColumnCount = 5; $tiles.RowCount = 1; $tiles.AutoSize = $true
    $tiles.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 6)
    foreach ($v in @(@('Moves', ('{0:N0}' -f $Info.Moves)), @('Gold', ('{0:N0}' -f $Info.Gold)), @('Food', ('{0:N0}' -f $Info.Food)),
                     @('Party', $Info.Count), @('Ship hull', $Info.Hull))) {
        [void]$tiles.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 20)))
        $p = New-Object System.Windows.Forms.TableLayoutPanel
        $p.ColumnCount = 1; $p.RowCount = 2; $p.AutoSize = $true; $p.Dock = 'Fill'
        $p.BackColor = [System.Drawing.Color]::FromArgb(244, 236, 216); $p.Margin = New-Object System.Windows.Forms.Padding(3)
        $p.Padding = New-Object System.Windows.Forms.Padding(4, 6, 4, 6)
        foreach ($l in @((New-SheetLabel ([string]$v[1]) (New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold))),
                         (New-SheetLabel $v[0].ToUpper() (New-Object System.Drawing.Font('Segoe UI', 8.5)) ([System.Drawing.Color]::FromArgb(107, 90, 69))))) {
            $l.Anchor = 'None'; [void]$p.Controls.Add($l)
        }
        [void]$tiles.Controls.Add($p)
    }
    Add-Row $tiles

    # two columns: virtues and party on the left, belongings on the right
    $cols = New-Object System.Windows.Forms.TableLayoutPanel
    $cols.ColumnCount = 2; $cols.RowCount = 2
    foreach ($pct in 58, 42) { [void]$cols.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', $pct))) }
    [void]$cols.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
    [void]$cols.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))

    # virtues with bars
    $grpV = New-Object System.Windows.Forms.GroupBox
    $grpV.Text = 'Virtues'; $grpV.AutoSize = $true; $grpV.Dock = 'Fill'
    $stats = New-Object System.Windows.Forms.TableLayoutPanel
    $stats.Dock = 'Fill'; $stats.AutoSize = $true; $stats.ColumnCount = 3
    foreach ($style in @('AutoSize', 'Percent', 'AutoSize')) {
        $cs = New-Object System.Windows.Forms.ColumnStyle($style); if ($style -eq 'Percent') { $cs.Width = 100 }
        [void]$stats.ColumnStyles.Add($cs)
    }
    foreach ($i in 0..7) {
        $k = $Info.Karma[$i]
        $name = New-SheetLabel $Virtues[$i] $font; $name.Anchor = 'Left'
        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.Maximum = 99; $bar.Value = $(if ($k -eq 0) { 99 } else { [math]::Min(99, $k) }); $bar.Height = 14; $bar.Anchor = 'Left, Right'
        $val = New-SheetLabel $(if ($k -eq 0) { 'Avatar' } else { [string]$k }) $boldFont; $val.Anchor = 'Right'
        $stats.Controls.AddRange(@($name, $bar, $val))
    }
    $grpV.Controls.Add($stats)
    $cols.Controls.Add($grpV, 0, 0)

    # party
    $team = New-Object System.Windows.Forms.ListView
    $team.View = 'Details'; $team.FullRowSelect = $true; $team.HeaderStyle = 'Nonclickable'; $team.Dock = 'Fill'
    $team.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 0)
    foreach ($c in @(@('Party', 105), @('Class', 70), @('Lvl', 34), @('HP', 74), @('S/D/I', 66), @('Weapon', 85))) { [void]$team.Columns.Add($c[0], $c[1]) }
    foreach ($m in $Info.Members) {
        $item = New-Object System.Windows.Forms.ListViewItem($m.Name)
        foreach ($v in @($m.Class, $m.Level, ('{0}/{1}' -f $m.Hp, $m.MaxHp), ('{0}/{1}/{2}' -f $m.Str, $m.Dex, $m.Int), $m.Weapon)) {
            [void]$item.SubItems.Add([string]$v)
        }
        if ($m.Status -ne 'Good') { $item.ForeColor = $accent }
        [void]$team.Items.Add($item)
    }
    $cols.Controls.Add($team, 0, 1)

    # belongings
    $inv = New-Object System.Windows.Forms.ListView
    $inv.View = 'Details'; $inv.ShowGroups = $true; $inv.FullRowSelect = $true; $inv.HeaderStyle = 'Nonclickable'; $inv.Dock = 'Fill'
    [void]$inv.Columns.Add('Belongings', 220); [void]$inv.Columns.Add('Qty', 60)
    function Add-Group([string]$Title, $Rows) {
        if (-not @($Rows).Count) { return }
        $grp = New-Object System.Windows.Forms.ListViewGroup($Title, $Title)
        [void]$inv.Groups.Add($grp)
        foreach ($r in $Rows) {
            $isText = $r -is [string]
            $item = New-Object System.Windows.Forms.ListViewItem($(if ($isText) { $r } else { $r.Item }), $grp)
            [void]$item.SubItems.Add($(if ($isText) { '' } else { [string]$r.Count }))
            [void]$inv.Items.Add($item)
        }
    }
    Add-Group 'Quest items' $Info.Quest
    Add-Group 'Stones' @($Info.Stones | ForEach-Object { "$_ stone" })
    Add-Group 'Runes' @($Info.Runes | ForEach-Object { "Rune of $_" })
    Add-Group 'Equipment' $Info.Equipment
    Add-Group 'Weapons' $Info.Weapons
    Add-Group 'Armour' $Info.Armours
    Add-Group 'Reagents' $Info.Reagents
    Add-Group 'Mixed spells' $Info.Mixtures
    $cols.Controls.Add($inv, 1, 0)
    $cols.SetRowSpan($inv, 2)
    Add-Row $cols -Fill

    $foot = New-SheetLabel $Source (New-Object System.Drawing.Font('Segoe UI', 8.5)) ([System.Drawing.SystemColors]::GrayText)
    $foot.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    Add-Row $foot

    $sheet.Controls.Add($lay)
    $sheet.KeyPreview = $true
    $sheet.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $sheet.Close() } })
    [void]$sheet.ShowDialog($form)
    $sheet.Dispose()
}

$btnBackup.Add_Click({
    Invoke-Safely {
        $cur = Get-CurrentGame
        if (-not $cur) { throw 'No saved game to back up.' }
        if (Test-DosBoxRunning) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "DOSBox is still running.`n`nThis backs up your last save, not the game in progress. Save with Q first (outdoors or in a dungeon; the game refuses in towns). Back up anyway?",
                'Ultima 4 Save Manager', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }
        [void](New-Backup $cur $txtNote.Text)
        $txtNote.Clear()
        Update-View
        Set-Status "Backed up $($cur.Folder)."
    }
})

$btnRestore.Add_Click({
    Invoke-Safely {
        if ($lv.SelectedItems.Count -ne 1) { throw 'Select exactly one backup to restore.' }
        $b = $lv.SelectedItems[0].Tag
        $msg = "Replace the saved game with:`n`n    $($b.Info.Name)  -  {0:ddd MMM d yyyy, h:mm tt}  -  $($b.Info.Moves) moves`n    $($b.Note)`n`nIf the game on disk isn't already backed up, it'll be snapshotted to '$AutoSlot' first." -f $b.When
        if ([System.Windows.Forms.MessageBox]::Show($msg, 'Restore backup?', 'OKCancel', 'Question') -ne 'OK') { return }
        $auto = Restore-Backup $b
        Update-View
        $extra = if ($auto) { ' (previous game auto-saved)' } else { '' }
        Set-Status ("Restored {0} from {1:g}{2}" -f $b.Info.Name, $b.When, $extra)
    }
})

$btnDelete.Add_Click({
    Invoke-Safely {
        $sel = @($lv.SelectedItems | ForEach-Object { $_.Tag })
        if (-not $sel) { throw 'Select one or more backups to delete.' }
        $names = ($sel | ForEach-Object { '  {0}  -  {1:g}' -f $_.Folder, $_.When }) -join "`n"
        if ([System.Windows.Forms.MessageBox]::Show("Permanently delete $($sel.Count) backup(s)?`n`n$names", 'Delete backups?', 'YesNo', 'Warning') -ne 'Yes') { return }
        foreach ($b in $sel) {
            Remove-Item -LiteralPath $b.Path -Recurse -Force
            $slotDir = Split-Path $b.Path
            if (-not (Get-ChildItem -LiteralPath $slotDir -Force)) { Remove-Item -LiteralPath $slotDir -Force }
        }
        Update-View
        Set-Status "Deleted $($sel.Count) backup(s)."
    }
})

$btnOpen.Add_Click({
    Invoke-Safely {
        $target = $BackupRoot
        if ($lv.SelectedItems.Count -eq 1) { $target = $lv.SelectedItems[0].Tag.Path }
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Start-Process explorer.exe $target
    }
})

$btnRefresh.Add_Click({ Invoke-Safely { Update-View; Set-Status 'Refreshed.' } })
$lv.Add_SelectedIndexChanged({ if ($lv.SelectedItems.Count -eq 1) { Set-Status $lv.SelectedItems[0].Tag.Path } })
$lv.Add_DoubleClick({ $btnView.PerformClick() })
$btnSheet.Add_Click({
    Invoke-Safely {
        $cur = Get-CurrentGame
        if (-not $cur) { throw 'No saved game yet.' }
        Show-PartySheet $cur.Info ('Saved {0:ddd MMM d, h:mm tt}' -f $cur.Saved)
    }
})
$btnView.Add_Click({
    Invoke-Safely {
        if ($lv.SelectedItems.Count -ne 1) { throw 'Select one backup to view.' }
        $b = $lv.SelectedItems[0].Tag
        Show-PartySheet $b.Info ('Backup from {0:ddd MMM d, h:mm tt}  {1}' -f $b.When, $b.Note)
    }
})
$lvParty.Add_DoubleClick({ $btnSheet.PerformClick() })
$txtNote.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $btnBackup.PerformClick(); $_.SuppressKeyPress = $true } })

# Re-check when the window regains focus (e.g. after quitting DOSBox).
$form.Add_Activated({ Invoke-Safely { Update-View } })

[void]$form.ShowDialog()
