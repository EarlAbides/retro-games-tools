<#
  Ultima 1 save manager - backs up / restores the character files
  (PLAYER1.U1 .. PLAYER4.U1) that DOSBox writes into cloud_saves.

  No arguments  -> opens the GUI.
  Command line  -> Ultima1Saves.ps1 -Backup  [-Player 1] [-Note "before Mondain"]
                   Ultima1Saves.ps1 -List    [-Character Twatarina]
                   Ultima1Saves.ps1 -Restore -Character Twatarina [-Stamp 2026-10-25_21-05-33]
                   (no -Player = every character on disk; no -Stamp = newest backup)

  Each backup is one character, restored to the PLAYERn.U1 it came from.
  Layout:  cloud_saves\BACKUPS\<character>\<yyyy-MM-dd_HH-mm-ss>\PLAYERn.U1 (+ note.txt)

  Game folder: -GameDir, else $env:ULTIMA1_DIR, else the script's own folder
  if it sits in the install, else the default GOG Galaxy install path.
#>
[CmdletBinding()]
param(
    [switch]$Backup,
    [switch]$Restore,
    [switch]$List,
    [ValidateRange(1, 4)][int]$Player,
    [string]$Character,
    [string]$Stamp,
    [string]$Note,
    [string]$GameDir
)

$ErrorActionPreference = 'Stop'

function Resolve-GameDir {
    $candidates = @($GameDir, $env:ULTIMA1_DIR, $PSScriptRoot,
                    (Join-Path ${env:ProgramFiles(x86)} 'GOG Galaxy\Games\Ultima 1'),
                    (Join-Path $env:ProgramFiles 'GOG Galaxy\Games\Ultima 1'))
    if ($GameDir) { $candidates = @($GameDir) }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'ULTIMA.EXE'))) { return (Resolve-Path $c).Path }
    }
    $msg = 'Ultima 1 install not found. Pass -GameDir or set ULTIMA1_DIR to the folder containing ULTIMA.EXE.'
    if ($Backup -or $Restore -or $List) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Ultima 1 Save Manager', 'OK', 'Error')
    exit 1
}

$Root       = Resolve-GameDir
$PlayDir    = Join-Path $Root 'cloud_saves'               # DOSBox overlay on C:\ - where the game actually writes
$BackupRoot = Join-Path $Root 'cloud_saves\BACKUPS'
$StampFmt   = 'yyyy-MM-dd_HH-mm-ss'
$AutoSlot   = '_before-restore'                           # safety net written before every restore
$AutoKeep   = 10

# ---------------------------------------------------------------- character file

$Races   = @('Human', 'Elf', 'Dwarf', 'Bobbit')           # order as listed in GEN.EXE
$Classes = @('Fighter', 'Cleric', 'Wizard', 'Thief')
$Sexes   = @('Male', 'Female')

function Read-Character([string]$Path) {
    # PLAYERn.U1 is an 820-byte flat record of little-endian 16-bit words after a 16-byte name.
    # All fields here are confirmed against the in-game display.
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 0x2A) { return $null }
    $word = { param($o) [int][BitConverter]::ToUInt16($b, $o) }
    $pick = { param($arr, $i) if ($i -lt $arr.Count) { $arr[$i] } else { "?$i" } }
    $end = [Array]::IndexOf($b, [byte]0, 0, 16)
    if ($end -lt 0) { $end = 16 }
    [pscustomobject]@{
        Name   = [Text.Encoding]::ASCII.GetString($b, 0, $end).Trim()
        Race   = & $pick $Races   (& $word 0x10)
        Class  = & $pick $Classes (& $word 0x12)
        Sex    = & $pick $Sexes   (& $word 0x14)
        Hits   = & $word 0x16
        Str    = & $word 0x18
        Agi    = & $word 0x1A
        Sta    = & $word 0x1C
        Cha    = & $word 0x1E
        Wis    = & $word 0x20
        Int    = & $word 0x22
        Coin   = & $word 0x24
        Exp    = & $word 0x26
        Food   = & $word 0x28
    }
}

# ---------------------------------------------------------------- core

function Get-Fingerprint([string]$Path) {
    # Plain .NET rather than Get-FileHash, which isn't always loadable (e.g. when PSModulePath points at pwsh 7).
    if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) }
    finally { $sha.Dispose() }
}

function Get-FolderName([string]$Name, [int]$N) {
    $clean = ($Name.ToCharArray() | ForEach-Object { if ([IO.Path]::GetInvalidFileNameChars() -contains $_) { '_' } else { $_ } }) -join ''
    $clean = $clean.Trim().Trim('.')
    if (-not $clean -or $clean -eq $AutoSlot) { "Player $N" } else { $clean }
}

function Get-CurrentPlayers {
    # Effective view of C:\PLAYERn.U1 inside DOSBox: overlay file wins, else the install's own copy.
    foreach ($n in 1..4) {
        $file = "PLAYER$n.U1"
        $path = @((Join-Path $PlayDir $file), (Join-Path $Root $file)) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $path) { continue }
        $info = Read-Character $path
        [pscustomobject]@{
            Player      = $n
            File        = $file
            Path        = $path
            Info        = $info
            Folder      = Get-FolderName $(if ($info) { $info.Name } else { '' }) $n
            Saved       = (Get-Item -LiteralPath $path).LastWriteTime
            Fingerprint = Get-Fingerprint $path
        }
    }
}

function Test-DosBoxRunning {
    # Only an Ultima DOSBox counts; a process whose path we can't read is assumed to be ours.
    [bool](Get-Process -Name 'DOSBox' -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Path -or $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) })
}

function New-Backup($Cur, [string]$NoteText, [string]$Folder = $Cur.Folder) {
    $dest = Join-Path (Join-Path $BackupRoot $Folder) (Get-Date -Format $StampFmt)
    while (Test-Path $dest) { Start-Sleep -Milliseconds 1100; $dest = Join-Path (Split-Path $dest) (Get-Date -Format $StampFmt) }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -LiteralPath $Cur.Path -Destination (Join-Path $dest $Cur.File)
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
            $f = Get-ChildItem -Path $d.FullName -File | Where-Object { $_.Name -match '^PLAYER([1-4])\.U1$' } | Select-Object -First 1
            if (-not $f) { continue }
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
                File        = $f.Name.ToUpper()
                Player      = [int]$f.Name.Substring(6, 1)
                Info        = Read-Character $f.FullName
                Fingerprint = Get-Fingerprint $f.FullName
            }
        }
    }
}

function Restore-Backup($B) {
    if (Test-DosBoxRunning) { throw 'DOSBox is running. Quit Ultima first - DOSBox caches files and would clobber the restore.' }

    # Safety net: snapshot whatever is in that PLAYERn.U1 now, unless it's already backed up somewhere.
    $cur = Get-CurrentPlayers | Where-Object { $_.Player -eq $B.Player }
    $auto = $null
    if ($cur -and -not (Get-Backups | Where-Object { $_.Fingerprint -eq $cur.Fingerprint })) {
        $auto = New-Backup $cur 'Automatic snapshot taken before a restore' $AutoSlot
        Get-Backups $AutoSlot | Sort-Object When -Descending | Select-Object -Skip $AutoKeep |
            ForEach-Object { Remove-Item -LiteralPath $_.Path -Recurse -Force }
    }

    New-Item -ItemType Directory -Path $PlayDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $B.Path $B.File) -Destination (Join-Path $PlayDir $B.File) -Force
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

function Format-Character($Info) {
    if (-not $Info) { return '(unreadable)' }
    '{0} {1} {2}' -f $Info.Sex, $Info.Race, $Info.Class
}

function Test-IsCurrent($B, $Players) {
    [bool]($Players | Where-Object { $_.Player -eq $B.Player -and $_.Fingerprint -eq $B.Fingerprint })
}

# ---------------------------------------------------------------- command line

if ($Backup -or $Restore -or $List) {
    try {
        if ($Backup) {
            if (Test-DosBoxRunning) { Write-Warning 'DOSBox is running - make sure you saved with Q (outdoors) in Ultima first.' }
            $players = @(Get-CurrentPlayers)
            if ($Player) { $players = @($players | Where-Object { $_.Player -eq $Player }) }
            if (-not $players) { throw "No character files found in $PlayDir." }
            foreach ($p in $players) { Write-Host "Backed up $($p.File) ($($p.Folder)) to $(New-Backup $p $Note)" }
        }
        elseif ($List) {
            $players = @(Get-CurrentPlayers)
            Get-Backups $Character | Sort-Object Folder, When |
                Select-Object @{n = 'Character'; e = { $_.Folder } }, Stamp, File,
                              @{n = 'Current'; e = { if (Test-IsCurrent $_ $players) { '<==' } else { '' } } },
                              @{n = 'Hits'; e = { $_.Info.Hits } }, @{n = 'Exp'; e = { $_.Info.Exp } }, Note |
                Format-Table -AutoSize
        }
        elseif ($Restore) {
            if (-not $Character) { throw 'Give -Character (the backup folder name, usually the character name).' }
            $all = @(Get-Backups $Character | Sort-Object When -Descending)
            if ($Stamp) { $all = @($all | Where-Object { $_.Stamp -eq $Stamp }) }
            if (-not $all) { throw "No backup found for character '$Character' $Stamp" }
            $auto = Restore-Backup $all[0]
            if ($auto) { Write-Host "Previous $($all[0].File) saved to $auto" }
            Write-Host "Restored $($all[0].Folder) \ $($all[0].Stamp) to $($all[0].File)"
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
$form.Text = 'Ultima 1 Save Manager'
$form.Size = New-Object System.Drawing.Size(980, 680)
$form.MinimumSize = New-Object System.Drawing.Size(760, 500)
$form.StartPosition = 'CenterScreen'
$form.Font = $font
$form.AutoScaleMode = 'Dpi'
$icon = Join-Path $Root 'goggame-1207662593.ico'
if (Test-Path $icon) { $form.Icon = New-Object System.Drawing.Icon($icon) }

# --- status strip at top
$lblCurrent = New-Object System.Windows.Forms.Label
$lblCurrent.Dock = 'Top'; $lblCurrent.Height = 34; $lblCurrent.Font = $boldFont
$lblCurrent.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 0)

# --- characters on disk + backup row
$pnlChars = New-Object System.Windows.Forms.GroupBox
$pnlChars.Text = 'Characters on disk'
$pnlChars.Dock = 'Top'; $pnlChars.AutoSize = $true
$pnlChars.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 6)

$tbl = New-Object System.Windows.Forms.TableLayoutPanel
$tbl.Dock = 'Fill'; $tbl.AutoSize = $true; $tbl.ColumnCount = 1; $tbl.RowCount = 2

$lvChars = New-Object System.Windows.Forms.ListView
$lvChars.View = 'Details'; $lvChars.FullRowSelect = $true; $lvChars.MultiSelect = $true
$lvChars.HideSelection = $false; $lvChars.Dock = 'Fill'
$lvChars.Height = ($font.Height + 8) * 6                  # header + 4 characters, at any DPI
foreach ($c in @(@('#', 40), @('Name', 150), @('Character', 170), @('Hits', 60), @('Food', 60), @('Exp', 60), @('Coin', 60),
                 @('Str/Agi/Sta/Cha/Wis/Int', 190), @('Last saved', 250))) {
    [void]$lvChars.Columns.Add($c[0], $c[1])
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
$btnBackup    = New-RowBtn 'Back Up Selected'
$btnBackupAll = New-RowBtn 'Back Up All'
$row.Controls.Add($lblNote, 0, 0)
$row.Controls.Add($txtNote, 1, 0)
$row.Controls.Add($btnBackup, 2, 0)
$row.Controls.Add($btnBackupAll, 3, 0)

$tbl.Controls.Add($lvChars, 0, 0)
$tbl.Controls.Add($row, 0, 1)
$pnlChars.Controls.Add($tbl)

# --- backups list
$lv = New-Object System.Windows.Forms.ListView
$lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $true
$lv.HideSelection = $false; $lv.ShowGroups = $true
foreach ($c in @(@('Saved', 180), @('Age', 100), @('Current?', 75), @('File', 95), @('Hits', 60), @('Food', 60),
                 @('Exp', 60), @('Coin', 60), @('Note', 300))) {
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
$btnDelete  = New-Btn 'Delete Selected'
$btnOpen    = New-Btn 'Open Folder'
$btnRefresh = New-Btn 'Refresh' 100

$status = New-Object System.Windows.Forms.StatusStrip
$statusLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLbl.Spring = $true; $statusLbl.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($statusLbl)

# Fill must be added first so docked Top/Bottom controls claim their space around it.
$form.Controls.AddRange(@($lv, $pnlChars, $lblCurrent, $pnlButtons, $status))

function Set-Status([string]$Msg) { $statusLbl.Text = $Msg }

function Update-View {
    $running = Test-DosBoxRunning
    if ($running) {
        $lblCurrent.Text = 'DOSBox is RUNNING  -  save with Q (outdoors) before backing up; restore is disabled'
        $lblCurrent.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblCurrent.Text = 'Ultima is not running'
        $lblCurrent.ForeColor = [System.Drawing.SystemColors]::ControlText
    }
    $btnRestore.Enabled = -not $running

    $players = @(Get-CurrentPlayers)
    $keepChars = @($lvChars.SelectedItems | ForEach-Object { $_.Tag.Player })
    $lvChars.BeginUpdate()
    $lvChars.Items.Clear()
    foreach ($p in $players) {
        $i = $p.Info
        $item = New-Object System.Windows.Forms.ListViewItem([string]$p.Player)
        if ($i) {
            foreach ($v in @($i.Name, (Format-Character $i), $i.Hits, $i.Food, $i.Exp, $i.Coin,
                             ('{0} / {1} / {2} / {3} / {4} / {5}' -f $i.Str, $i.Agi, $i.Sta, $i.Cha, $i.Wis, $i.Int))) {
                [void]$item.SubItems.Add([string]$v)
            }
        } else {
            [void]$item.SubItems.Add('(unreadable)'); 1..6 | ForEach-Object { [void]$item.SubItems.Add('') }
        }
        [void]$item.SubItems.Add(('{0:ddd MMM d, h:mm tt} ({1})' -f $p.Saved, (Format-Age $p.Saved)))
        $item.Tag = $p
        [void]$lvChars.Items.Add($item)
        if ($keepChars -contains $p.Player) { $item.Selected = $true }
    }
    if ($lvChars.SelectedItems.Count -eq 0 -and $lvChars.Items.Count -eq 1) { $lvChars.Items[0].Selected = $true }
    $lvChars.EndUpdate()
    $btnBackup.Enabled = [bool]$players
    $btnBackupAll.Enabled = [bool]$players

    $all = @(Get-Backups)
    $keep = @($lv.SelectedItems | ForEach-Object { $_.Tag.Path })
    $lv.BeginUpdate()
    $lv.Items.Clear(); $lv.Groups.Clear()
    # Characters ordered by most recent activity; auto-snapshots last.
    $byFolder = $all | Group-Object Folder | Sort-Object @{e = { $_.Name -eq $AutoSlot } }, @{e = { ($_.Group | Measure-Object When -Maximum).Maximum }; Descending = $true }
    foreach ($g in $byFolder) {
        $header = if ($g.Name -eq $AutoSlot) { "Auto snapshots before restore ($($g.Count))" } else { "$($g.Name)  -  $(Format-Character $g.Group[0].Info)  ($($g.Count))" }
        $grp = New-Object System.Windows.Forms.ListViewGroup($g.Name, $header)
        [void]$lv.Groups.Add($grp)
        foreach ($b in ($g.Group | Sort-Object When -Descending)) {
            $item = New-Object System.Windows.Forms.ListViewItem(('{0:yyyy-MM-dd  h:mm:ss tt}' -f $b.When), $grp)
            $isCur = Test-IsCurrent $b $players
            $note = $b.Note
            if ($g.Name -eq $AutoSlot -and $b.Info) { $note = "$($b.Info.Name): $note" }
            foreach ($v in @((Format-Age $b.When), $(if ($isCur) { '  <==' } else { '' }), $b.File,
                             $b.Info.Hits, $b.Info.Food, $b.Info.Exp, $b.Info.Coin, $note)) {
                [void]$item.SubItems.Add([string]$v)
            }
            if ($isCur) { $item.Font = $boldFont; $item.ForeColor = [System.Drawing.Color]::DarkGreen }
            $item.Tag = $b
            [void]$lv.Items.Add($item)
            if ($keep -contains $b.Path) { $item.Selected = $true }
        }
    }
    $lv.EndUpdate()
    if (-not $players) { Set-Status "No characters yet. Create one in Ultima first. (Looking in $PlayDir)" }
    elseif (-not $all) { Set-Status "No backups yet. Select a character and click Back Up Selected. (Stored in $BackupRoot)" }
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ultima 1 Save Manager', 'OK', 'Error') }
}

function Invoke-Backup($Players) {
    if (-not $Players) { throw 'Select a character to back up.' }
    if (Test-DosBoxRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "DOSBox is still running.`n`nUltima only writes the character file when you save with Q (outdoors). Back up anyway?",
            'Ultima 1 Save Manager', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    $done = foreach ($p in $Players) { [void](New-Backup $p $txtNote.Text); $p.Folder }
    $txtNote.Clear()
    Update-View
    Set-Status "Backed up $($done -join ', ')."
}

$btnBackup.Add_Click({ Invoke-Safely { Invoke-Backup @($lvChars.SelectedItems | ForEach-Object { $_.Tag }) } })
$btnBackupAll.Add_Click({ Invoke-Safely { Invoke-Backup @(Get-CurrentPlayers) } })

$btnRestore.Add_Click({
    Invoke-Safely {
        if ($lv.SelectedItems.Count -ne 1) { throw 'Select exactly one backup to restore.' }
        $b = $lv.SelectedItems[0].Tag
        $msg = "Replace $($b.File) with:`n`n    $($b.Info.Name)  -  {0:ddd MMM d yyyy, h:mm tt}`n    $($b.Note)`n`nIf the character now in $($b.File) isn't already backed up, it'll be snapshotted to '$AutoSlot' first." -f $b.When
        if ([System.Windows.Forms.MessageBox]::Show($msg, 'Restore backup?', 'OKCancel', 'Question') -ne 'OK') { return }
        $auto = Restore-Backup $b
        Update-View
        $extra = if ($auto) { ' (previous file auto-saved)' } else { '' }
        Set-Status ("Restored {0} from {1:g} to {2}{3}" -f $b.Info.Name, $b.When, $b.File, $extra)
    }
})

$btnDelete.Add_Click({
    Invoke-Safely {
        $sel = @($lv.SelectedItems | ForEach-Object { $_.Tag })
        if (-not $sel) { throw 'Select one or more backups to delete.' }
        $list = ($sel | ForEach-Object { '  {0}  -  {1:g}' -f $_.Folder, $_.When }) -join "`n"
        if ([System.Windows.Forms.MessageBox]::Show("Permanently delete $($sel.Count) backup(s)?`n`n$list", 'Delete backups?', 'YesNo', 'Warning') -ne 'Yes') { return }
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
$lv.Add_DoubleClick({ $btnRestore.PerformClick() })
$lvChars.Add_DoubleClick({ $btnBackup.PerformClick() })
$txtNote.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $btnBackup.PerformClick(); $_.SuppressKeyPress = $true } })

# Re-check when the window regains focus (e.g. after quitting DOSBox).
$form.Add_Activated({ Invoke-Safely { Update-View } })

[void]$form.ShowDialog()
