<#
  Starflight save manager - backs up / restores the game-state files that
  DOSBox writes into cloud_saves\STARFLT\PLAY.

  No arguments  -> opens the GUI.
  Command line  -> StarflightSaves.ps1 -Backup  -Slot MERCURY [-Note "before arth"]
                   StarflightSaves.ps1 -List    [-Slot MERCURY]
                   StarflightSaves.ps1 -Restore -Slot MERCURY [-Stamp 2026-10-14_21-05-33]
                   (no -Stamp = newest backup in that slot)

  Layout:  cloud_saves\STARFLT\BACKUPS\<slot>\<yyyy-MM-dd_HH-mm-ss>\*.COM (+ note.txt)

  Game folder: -GameDir, else $env:STARFLIGHT_DIR, else the script's own folder
  if it sits in the install, else the default GOG Galaxy install path.
#>
[CmdletBinding()]
param(
    [switch]$Backup,
    [switch]$Restore,
    [switch]$List,
    [string]$Slot,
    [string]$Stamp,
    [string]$Note,
    [string]$GameDir
)

$ErrorActionPreference = 'Stop'

function Resolve-GameDir {
    $candidates = @($GameDir, $env:STARFLIGHT_DIR, $PSScriptRoot,
                    (Join-Path ${env:ProgramFiles(x86)} 'GOG Galaxy\Games\Starflight'),
                    (Join-Path $env:ProgramFiles 'GOG Galaxy\Games\Starflight'))
    if ($GameDir) { $candidates = @($GameDir) }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'STARFLT'))) { return (Resolve-Path $c).Path }
    }
    $msg = 'Starflight install not found. Pass -GameDir or set STARFLIGHT_DIR to the folder containing STARFLT.'
    if ($Backup -or $Restore -or $List) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Starflight Save Manager', 'OK', 'Error')
    exit 1
}

$Root       = Resolve-GameDir
$BaseDir    = Join-Path $Root 'STARFLT\PLAY'               # original install files (read-only layer)
$PlayDir    = Join-Path $Root 'cloud_saves\STARFLT\PLAY'   # DOSBox overlay - where the game actually writes
$BackupRoot = Join-Path $Root 'cloud_saves\STARFLT\BACKUPS'
$StampFmt   = 'yyyy-MM-dd_HH-mm-ss'
$AutoSlot   = '_before-restore'                            # safety net written before every restore
$AutoKeep   = 10
$StateFiles = @('STARA.COM', 'STARB.COM')                  # the files that actually hold game state

# ---------------------------------------------------------------- core

function Get-CurrentFiles {
    # Effective view of C:\STARFLT\PLAY inside DOSBox: overlay file wins, else the base file.
    $map = @{}
    foreach ($dir in @($BaseDir, $PlayDir)) {
        if (Test-Path $dir) {
            Get-ChildItem -Path $dir -Filter '*.COM' -File | ForEach-Object { $map[$_.Name.ToUpper()] = $_ }
        }
    }
    $map.Values | Sort-Object Name
}

function Get-Fingerprint([string[]]$Paths) {
    # Plain .NET rather than Get-FileHash, which isn't always loadable (e.g. when PSModulePath points at pwsh 7).
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $parts = foreach ($p in $Paths) {
            if (Test-Path $p) { [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($p))) } else { 'missing' }
        }
    }
    finally { $sha.Dispose() }
    $parts -join ':'
}

function Get-CurrentFingerprint {
    $cur = @(Get-CurrentFiles)
    $paths = foreach ($n in $StateFiles) {
        $f = $cur | Where-Object { $_.Name -ieq $n } | Select-Object -First 1
        if ($f) { $f.FullName } else { Join-Path $PlayDir $n }
    }
    Get-Fingerprint $paths
}

function Test-DosBoxRunning {
    # Only a Starflight DOSBox counts; a process whose path we can't read is assumed to be ours.
    [bool](Get-Process -Name 'DOSBox' -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Path -or $_.Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
}

function Test-SlotName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Give the save slot a name.' }
    $bad = [IO.Path]::GetInvalidFileNameChars()
    if ($Name.IndexOfAny($bad) -ge 0 -or $Name -match '^\.+$') { throw "'$Name' isn't a valid folder name." }
    $Name.Trim()
}

function New-Backup([string]$SlotName, [string]$NoteText) {
    $SlotName = Test-SlotName $SlotName
    $files = @(Get-CurrentFiles)
    if (-not $files) { throw "No game files found in $PlayDir or $BaseDir." }

    $dest = Join-Path (Join-Path $BackupRoot $SlotName) (Get-Date -Format $StampFmt)
    while (Test-Path $dest) { Start-Sleep -Milliseconds 1100; $dest = Join-Path (Split-Path $dest) (Get-Date -Format $StampFmt) }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $dest }
    if (-not [string]::IsNullOrWhiteSpace($NoteText)) {
        Set-Content -LiteralPath (Join-Path $dest 'note.txt') -Value $NoteText.Trim() -Encoding UTF8
    }
    $dest
}

function Get-Backups([string]$SlotFilter) {
    if (-not (Test-Path $BackupRoot)) { return @() }
    $slots = Get-ChildItem -Path $BackupRoot -Directory
    if ($SlotFilter) { $slots = $slots | Where-Object { $_.Name -ieq $SlotFilter } }
    foreach ($s in $slots) {
        foreach ($d in (Get-ChildItem -Path $s.FullName -Directory)) {
            $when = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($d.Name, $StampFmt, $null, 'None', [ref]$when)) { $when = $d.CreationTime }
            $notePath = Join-Path $d.FullName 'note.txt'
            $noteVal  = ''
            if (Test-Path $notePath) { $noteVal = (Get-Content -LiteralPath $notePath -Raw).Trim() }
            [pscustomobject]@{
                Slot        = $s.Name
                Stamp       = $d.Name
                When        = $when
                Note        = $noteVal
                Path        = $d.FullName
                Fingerprint = Get-Fingerprint ($StateFiles | ForEach-Object { Join-Path $d.FullName $_ })
            }
        }
    }
}

function Restore-Backup([string]$Dir) {
    if (Test-DosBoxRunning) { throw 'DOSBox is running. Quit Starflight first - DOSBox caches files and would clobber the restore.' }
    foreach ($n in $StateFiles) {
        if (-not (Test-Path (Join-Path $Dir $n))) { throw "Backup at $Dir is missing $n - refusing to restore." }
    }

    # Safety net: snapshot the current state unless it's already backed up somewhere.
    $curFp = Get-CurrentFingerprint
    $auto = $null
    if (-not (Get-Backups | Where-Object { $_.Fingerprint -eq $curFp })) {
        $auto = New-Backup $AutoSlot 'Automatic snapshot taken before a restore'
        Get-Backups $AutoSlot | Sort-Object When -Descending | Select-Object -Skip $AutoKeep |
            ForEach-Object { Remove-Item -LiteralPath $_.Path -Recurse -Force }
    }

    New-Item -ItemType Directory -Path $PlayDir -Force | Out-Null
    # Stamp them as new: Copy-Item keeps the backup's old times, and GOG Galaxy's cloud sync could treat its copy as newer.
    $now = Get-Date
    Get-ChildItem -Path $Dir -Filter '*.COM' -File |
        ForEach-Object { (Copy-Item -LiteralPath $_.FullName -Destination $PlayDir -Force -PassThru).LastWriteTime = $now }
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

function Get-CurrentSavedTime {
    $cur = @(Get-CurrentFiles | Where-Object { $StateFiles -contains $_.Name.ToUpper() })
    if ($cur) { ($cur | Measure-Object LastWriteTime -Maximum).Maximum } else { $null }
}

# ---------------------------------------------------------------- command line

if ($Backup -or $Restore -or $List) {
    try {
        if ($Backup) {
            if (Test-DosBoxRunning) { Write-Warning 'DOSBox is running - make sure you did SAVE GAME in Starflight first.' }
            $d = New-Backup $Slot $Note
            Write-Host "Backed up to $d"
        }
        elseif ($List) {
            $fp = Get-CurrentFingerprint
            Get-Backups $Slot | Sort-Object Slot, When |
                Select-Object Slot, Stamp, @{n = 'Current'; e = { if ($_.Fingerprint -eq $fp) { '<==' } else { '' } } }, Note |
                Format-Table -AutoSize
        }
        elseif ($Restore) {
            $Slot = Test-SlotName $Slot
            $all = @(Get-Backups $Slot | Sort-Object When -Descending)
            if ($Stamp) { $all = @($all | Where-Object { $_.Stamp -eq $Stamp }) }
            if (-not $all) { throw "No backup found for slot '$Slot' $Stamp" }
            $auto = Restore-Backup $all[0].Path
            if ($auto) { Write-Host "Previous state saved to $auto" }
            Write-Host "Restored $($all[0].Slot) \ $($all[0].Stamp)"
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
$form.Text = 'Starflight Save Manager'
$form.Size = New-Object System.Drawing.Size(900, 600)
$form.MinimumSize = New-Object System.Drawing.Size(700, 420)
$form.StartPosition = 'CenterScreen'
$form.Font = $font
$form.AutoScaleMode = 'Dpi'
$icon = Join-Path $Root 'goggame-1207662393.ico'
if (Test-Path $icon) { $form.Icon = New-Object System.Drawing.Icon($icon) }

# --- status strip at top
$lblCurrent = New-Object System.Windows.Forms.Label
$lblCurrent.Dock = 'Top'; $lblCurrent.Height = 34; $lblCurrent.Font = $boldFont
$lblCurrent.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 0)

# --- backup panel: one auto-sizing row so nothing gets pushed off-screen at any DPI
$pnlBackup = New-Object System.Windows.Forms.GroupBox
$pnlBackup.Text = 'Back up current game'
$pnlBackup.Dock = 'Top'; $pnlBackup.AutoSize = $true
$pnlBackup.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 6)

$row = New-Object System.Windows.Forms.TableLayoutPanel
$row.Dock = 'Fill'; $row.AutoSize = $true; $row.ColumnCount = 5; $row.RowCount = 1
foreach ($style in @('AutoSize', 'Absolute', 'AutoSize', 'Percent', 'AutoSize')) {
    $cs = New-Object System.Windows.Forms.ColumnStyle($style)
    if ($style -eq 'Absolute') { $cs.Width = 190 } elseif ($style -eq 'Percent') { $cs.Width = 100 }
    [void]$row.ColumnStyles.Add($cs)
}
function New-Lbl([string]$Text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.AutoSize = $true; $l.Anchor = 'Left'; $l
}
$cboSlot = New-Object System.Windows.Forms.ComboBox
$cboSlot.Dock = 'Fill'; $cboSlot.Anchor = 'Left, Right'
$txtNote = New-Object System.Windows.Forms.TextBox
$txtNote.Anchor = 'Left, Right'
$btnBackup = New-Object System.Windows.Forms.Button
$btnBackup.Text = 'Back Up Now'; $btnBackup.AutoSize = $true
$btnBackup.Padding = New-Object System.Windows.Forms.Padding(10, 2, 10, 2)
$row.Controls.Add((New-Lbl 'Slot:'), 0, 0)
$row.Controls.Add($cboSlot, 1, 0)
$row.Controls.Add((New-Lbl '   Note (optional):'), 2, 0)
$row.Controls.Add($txtNote, 3, 0)
$row.Controls.Add($btnBackup, 4, 0)
$pnlBackup.Controls.Add($row)

# --- list
$lv = New-Object System.Windows.Forms.ListView
$lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $true
$lv.HideSelection = $false; $lv.ShowGroups = $true
[void]$lv.Columns.Add('Saved', 190)
[void]$lv.Columns.Add('Age', 110)
[void]$lv.Columns.Add('Current?', 80)
[void]$lv.Columns.Add('Note', 440)

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
$form.Controls.AddRange(@($lv, $pnlBackup, $lblCurrent, $pnlButtons, $status))

function Set-Status([string]$Msg) { $statusLbl.Text = $Msg }

function Update-View {
    $running = Test-DosBoxRunning
    $saved = Get-CurrentSavedTime
    $savedText = if ($saved) { '{0:ddd MMM d, h:mm tt} ({1})' -f $saved, (Format-Age $saved) } else { 'no game files found' }
    $lblCurrent.Text = "Current game last written: $savedText"
    if ($running) {
        $lblCurrent.Text += '    -    DOSBox is RUNNING'
        $lblCurrent.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblCurrent.ForeColor = [System.Drawing.SystemColors]::ControlText
    }
    $btnRestore.Enabled = -not $running

    $curFp = Get-CurrentFingerprint
    $all = @(Get-Backups)

    $typed = $cboSlot.Text
    $cboSlot.Items.Clear()
    $all | Select-Object -ExpandProperty Slot -Unique | Where-Object { $_ -ne $AutoSlot } | Sort-Object |
        ForEach-Object { [void]$cboSlot.Items.Add($_) }
    $cboSlot.Text = $typed

    $keep = @($lv.SelectedItems | ForEach-Object { $_.Tag.Path })
    $lv.BeginUpdate()
    $lv.Items.Clear(); $lv.Groups.Clear()
    # Slots ordered by most recent activity; auto-snapshots last.
    $bySlot = $all | Group-Object Slot | Sort-Object @{e = { $_.Name -eq $AutoSlot } }, @{e = { ($_.Group | Measure-Object When -Maximum).Maximum }; Descending = $true }
    foreach ($g in $bySlot) {
        $header = if ($g.Name -eq $AutoSlot) { "Auto snapshots before restore ($($g.Count))" } else { "$($g.Name)  ($($g.Count))" }
        $grp = New-Object System.Windows.Forms.ListViewGroup($g.Name, $header)
        [void]$lv.Groups.Add($grp)
        foreach ($b in ($g.Group | Sort-Object When -Descending)) {
            $item = New-Object System.Windows.Forms.ListViewItem(('{0:yyyy-MM-dd  h:mm:ss tt}' -f $b.When), $grp)
            [void]$item.SubItems.Add((Format-Age $b.When))
            $isCur = $b.Fingerprint -eq $curFp
            [void]$item.SubItems.Add($(if ($isCur) { '  <==' } else { '' }))
            [void]$item.SubItems.Add($b.Note)
            if ($isCur) { $item.Font = $boldFont; $item.ForeColor = [System.Drawing.Color]::DarkGreen }
            $item.Tag = $b
            [void]$lv.Items.Add($item)
            if ($keep -contains $b.Path) { $item.Selected = $true }
        }
    }
    $lv.EndUpdate()
    if (-not $all) { Set-Status "No backups yet. Type a slot name and click Back Up Now. (Stored in $BackupRoot)" }
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Starflight Save Manager', 'OK', 'Error') }
}

$btnBackup.Add_Click({
    Invoke-Safely {
        if (Test-DosBoxRunning) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "DOSBox is still running.`n`nStarflight's files are only a complete game state right after you do SAVE GAME. Back up anyway?",
                'Starflight Save Manager', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }
        $d = New-Backup $cboSlot.Text $txtNote.Text
        $txtNote.Clear()
        Update-View
        Set-Status "Backed up to $d"
    }
})

$btnRestore.Add_Click({
    Invoke-Safely {
        if ($lv.SelectedItems.Count -ne 1) { throw 'Select exactly one backup to restore.' }
        $b = $lv.SelectedItems[0].Tag
        $msg = "Replace the current game with:`n`n    $($b.Slot)  -  {0:ddd MMM d yyyy, h:mm tt}`n    $($b.Note)`n`nIf the current game isn't already backed up, it'll be snapshotted to '$AutoSlot' first." -f $b.When
        if ([System.Windows.Forms.MessageBox]::Show($msg, 'Restore backup?', 'OKCancel', 'Question') -ne 'OK') { return }
        $auto = Restore-Backup $b.Path
        Update-View
        $extra = if ($auto) { ' (previous state auto-saved)' } else { '' }
        Set-Status ("Restored {0} from {1:g}{2}" -f $b.Slot, $b.When, $extra)
    }
})

$btnDelete.Add_Click({
    Invoke-Safely {
        $sel = @($lv.SelectedItems | ForEach-Object { $_.Tag })
        if (-not $sel) { throw 'Select one or more backups to delete.' }
        $list = ($sel | ForEach-Object { '  {0}  -  {1:g}' -f $_.Slot, $_.When }) -join "`n"
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
$lv.Add_SelectedIndexChanged({
    if ($lv.SelectedItems.Count -eq 1) {
        $b = $lv.SelectedItems[0].Tag
        if ($b.Slot -ne $AutoSlot) { $cboSlot.Text = $b.Slot }
        Set-Status $b.Path
    }
})
$lv.Add_DoubleClick({ $btnRestore.PerformClick() })
$cboSlot.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $btnBackup.PerformClick(); $_.SuppressKeyPress = $true } })
$txtNote.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $btnBackup.PerformClick(); $_.SuppressKeyPress = $true } })

# Re-check when the window regains focus (e.g. after quitting DOSBox).
$form.Add_Activated({ Invoke-Safely { Update-View } })

[void]$form.ShowDialog()
