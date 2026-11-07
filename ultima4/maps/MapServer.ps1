<#
  Ultima 4 interactive map - tiny local web server for the map viewer in .\web.

  Serves the page on http://localhost:<port>/, the game's own map and tile files from the
  install (the art is never copied into the repo), the places, moongates and hidden items read
  from AVATAR.EXE, and your party from the save. Notes are kept in a JSON file (default
  .\map-notes.json, previous version kept as .bak). Opens the browser on start, and exits on
  its own a few minutes after the last map tab closes.

  MapServer.ps1 [-GameDir <install folder>] [-Port 8644] [-NotesFile <path>] [-NoBrowser]
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [int]$Port = 8644,
    [string]$NotesFile,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$install = 'GOG Galaxy\Games\Ultima 4 - Quest of the Avatar'
$candidates = @($GameDir, $env:ULTIMA4_DIR, (Join-Path ${env:ProgramFiles(x86)} $install), (Join-Path $env:ProgramFiles $install))
if ($GameDir) { $candidates = @($GameDir) }
$Root = $candidates | Where-Object { $_ -and (Test-Path (Join-Path $_ 'WORLD.MAP')) } | Select-Object -First 1
if (-not $Root) {
    $msg = 'Ultima 4 install not found. Pass -GameDir (the folder containing WORLD.MAP) or set ULTIMA4_DIR.'
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Ultima 4 Map', 'OK', 'Error')
    throw $msg
}
$PlayDir = Join-Path $Root 'cloud_saves'                 # DOSBox overlay on C:\ - where the game actually writes

$WebRoot = Join-Path $PSScriptRoot 'web'
if (-not $NotesFile) { $NotesFile = Join-Path $PSScriptRoot 'map-notes.json' }
$NotesFile = [IO.Path]::GetFullPath($NotesFile)
$Url = "http://localhost:$Port/"
$IdleLimit = 180   # seconds awake with no request; page pings every 30s, background tabs may throttle to once a minute

$Types = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'
    '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
    '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'
}

# ---------------------------------------------------------------- game data

$Exe = [IO.File]::ReadAllBytes((Join-Path $Root 'AVATAR.EXE'))
$WorldMap = [IO.File]::ReadAllBytes((Join-Path $Root 'WORLD.MAP'))
$BadExe = 'AVATAR.EXE is not the version this map knows.'

function Get-WorldTile([int]$X, [int]$Y) {
    # WORLD.MAP: 8 x 8 chunks of 32 x 32 tiles, one byte per tile.
    $WorldMap[(($Y -shr 5) * 8 + ($X -shr 5)) * 1024 + ($Y -band 31) * 32 + ($X -band 31)]
}

function Get-Places {
    <# From AVATAR.EXE (these are file offsets; the code that uses them sees the unpacked image):
       x positions at 0xFB02 and y positions at 0xFB22, in the order of the names at 0x11028:
       15 towns, 8 dungeons, 8 shrines. A place's id is the game's own location number (save
       offset 0x1F4), which counts from Lord British's Castle at 1. Every position is checked
       against WORLD.MAP before use. #>
    $sig = [Text.Encoding]::ASCII.GetBytes('The Lycaeum')
    foreach ($i in 0..($sig.Length - 1)) { if ($Exe[0x11028 + $i] -ne $sig[$i]) { throw $BadExe } }

    $folders = @('LYCAEUM', 'EMPATH', 'SERPENT', 'MOONGLOW', 'BRITAIN', 'JHELOM', 'YEW', 'MINOC', 'TRINSIC', 'SKARA', 'MAGINCIA', 'PAWS', 'DEN', 'VESPER', 'COVE',
                 'DECEIT', 'DESPISE', 'DESTARD', 'WRONG', 'COVETOUS', 'SHAME', 'HYTHLOTH', 'ABYSS')
    # tile -> kind. A dungeon tile of 0x46 is the Abyss; shrines are 0x1E but Spirituality isn't on the map at all.
    $kinds = @{ 0x0B = 'keep'; 0x0A = 'town'; 0x0C = 'village'; 0x1D = 'ruin'; 0x09 = 'dungeon'; 0x46 = 'dungeon'; 0x1E = 'shrine' }

    if ((Get-WorldTile 86 107) -ne 0x0E) { throw $BadExe }
    [ordered]@{ id = 1; kind = 'castle'; name = "Lord British's Castle"; x = 86; y = 107; secret = $false
                ult = @('LCB_1.ULT', 'LCB_2.ULT'); tlk = 'LCB.TLK'; dng = $null }

    $p = 0x11028
    foreach ($i in 0..30) {
        $end = [Array]::IndexOf($Exe, [byte]0, $p)
        if ($end - $p -gt 30) { throw $BadExe }
        $name = [Text.Encoding]::ASCII.GetString($Exe, $p, $end - $p).TrimEnd('!')
        $p = $end + 1
        $x = $Exe[0xFB02 + $i]; $y = $Exe[0xFB22 + $i]
        $id = $i + 2
        $tile = Get-WorldTile $x $y
        $isShrine = $i -ge 23
        if ($isShrine) { $name = "Shrine of $name" }
        $isSpirit = $i -eq 29
        $isAbyss = $i -eq 22
        if (-not $isSpirit -and (-not $kinds.ContainsKey([int]$tile) -or ($isShrine -and $tile -ne 0x1E))) { throw $BadExe }
        [ordered]@{
            id = $id
            kind = $(if ($isShrine) { 'shrine' } else { $kinds[[int]$tile] })
            name = $name
            # Spirituality has a placeholder position in the table; it's only reached by moongate.
            x = $(if ($isSpirit) { $null } else { $x })
            y = $(if ($isSpirit) { $null } else { $y })
            secret = ($isSpirit -or $isAbyss)
            ult = @(if ($i -lt 15) { "$($folders[$i]).ULT" })
            tlk = $(if ($i -lt 15) { "$($folders[$i]).TLK" } else { $null })
            dng = $(if ($i -ge 15 -and $i -lt 23) { "$($folders[$i]).DNG" } else { $null })
        }
    }
}

function Get-Gates {
    <# Eight x positions at file 0xFAD1 and eight y at 0xFAD9. The gate at index n opens while
       Trammel is in phase n (code 0x3A4F), and it takes you to the gate at Felucca's phase (code
       0x2AD1), or to the Shrine of Spirituality if both moons are full (code 0x2A9E). #>
    if ($Exe[0xFAD1] -ne 0xE0 -or $Exe[0xFAD9] -ne 0x85) { throw $BadExe }
    foreach ($i in 0..7) {
        $town = $Places | Where-Object { $_.id -eq $i + 5 }
        [ordered]@{ phase = $i; x = $Exe[0xFAD1 + $i]; y = $Exe[0xFAD9 + $i]; name = $town.name }
    }
}

function Get-HiddenItems {
    <# The Search command's table at file 0x11BCB (code 0x915B): five bytes each, location, x, y, then
       the address of what happens, and an address of 0 ends it. All eight runes share a handler,
       which looks the rune up by location in the table at file 0x11BAF: location then bit. #>
    $byCode = @{ 0x8DAA = 'mandrake'; 0x8DE0 = 'nightshade'; 0x8E16 = 'bell'; 0x8E46 = 'horn'; 0x8E77 = 'wheel'; 0x8EA8 = 'skull'
                 0x8EE8 = 'blackstone'; 0x8F21 = 'whitestone'; 0x8F51 = 'book'; 0x8F81 = 'candle'; 0x8FB1 = 'telescope'
                 0x9027 = 'mysticarmour'; 0x9076 = 'mysticweapon'; 0x90C5 = 'rune' }
    $runeBits = @{}
    foreach ($i in 0..7) { $runeBits[[int]$Exe[0x11BAF + 2 * $i]] = [int]$Exe[0x11BB0 + 2 * $i] }
    $at = 0x11BCB; $n = 0
    while ($true) {
        $code = [BitConverter]::ToUInt16($Exe, $at + 3)
        if ($code -eq 0) { break }
        $key = $byCode[[int]$code]
        if (-not $key -or $n -ge 30) { throw $BadExe }
        $loc = [int]$Exe[$at]
        [ordered]@{
            n = $n; key = $key; loc = $loc; x = $Exe[$at + 1]; y = $Exe[$at + 2]
            bit = $(if ($key -eq 'rune') { if (-not $runeBits.ContainsKey($loc)) { throw $BadExe }; $runeBits[$loc] } else { 0 })
        }
        $at += 5; $n++
    }
    if ($n -ne 23) { throw $BadExe }
}

function Get-Party {
    # The overlay's file wins, else the install's, whose PARTY.SAV is a template with no party in it.
    # Same record as the save manager reads (see ..\save-manager\README.md).
    $path = @((Join-Path $PlayDir 'PARTY.SAV'), (Join-Path $Root 'PARTY.SAV')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $path) { return [ordered]@{ members = @() } }
    $b = [IO.File]::ReadAllBytes($path)
    if ($b.Length -ne 502) { return [ordered]@{ members = @() } }
    $w = { param($o) [int][BitConverter]::ToUInt16($b, $o) }
    $classes = @('Mage', 'Bard', 'Fighter', 'Druid', 'Tinker', 'Paladin', 'Ranger', 'Shepherd')
    $count = [math]::Min(8, (& $w 0x1D8))
    $members = @(for ($i = 0; $i -lt $count; $i++) {
        $o = 8 + $i * 39
        $end = [Array]::IndexOf($b, [byte]0, $o + 20, 16); if ($end -lt 0) { $end = $o + 36 }
        [ordered]@{
            name = [Text.Encoding]::ASCII.GetString($b, $o + 20, $end - ($o + 20))
            class = $(if ($b[$o + 37] -lt 8) { $classes[$b[$o + 37]] } else { '?' })
            hp = & $w $o; maxHp = & $w ($o + 2); status = [string][char]$b[$o + 38]
        }
    })
    [ordered]@{
        members = $members
        moves = [BitConverter]::ToUInt32($b, 4)
        items = & $w 0x1D2; stones = [int]$b[0x1D6]; runes = [int]$b[0x1D7]
        mysticArmour = & $w (0x15E + 2 * 7); mysticWeapon = & $w (0x16E + 2 * 15)
        x = [int]$b[0x1D4]; y = [int]$b[0x1D5]
        trammel = (& $w 0x1DE) -band 7; felucca = (& $w 0x1E0) -band 7
        dx = [int]$b[0x1EE]; dy = [int]$b[0x1EF]; level = & $w 0x1F2; loc = & $w 0x1F4
        saved = (Get-Item -LiteralPath $path).LastWriteTime.ToString('s')
    }
}

# ---------------------------------------------------------------- http

function Send([System.Net.HttpListenerContext]$Ctx, [int]$Status, [byte[]]$Body = @(), [string]$Type = 'text/plain; charset=utf-8') {
    $r = $Ctx.Response
    $r.StatusCode = $Status
    $r.Headers['Cache-Control'] = 'no-store'
    if ($Body.Length) { $r.ContentType = $Type; $r.ContentLength64 = $Body.Length; $r.OutputStream.Write($Body, 0, $Body.Length) }
    $r.Close()
}

function Send-Json([System.Net.HttpListenerContext]$Ctx, $Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 5 -Compress
    Send $Ctx 200 ([Text.UTF8Encoding]::new($false).GetBytes($json)) $Types['.json']
}

function Save-Notes([string]$Json) {
    $dir = Split-Path $NotesFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$NotesFile.tmp"
    [IO.File]::WriteAllText($tmp, $Json, [Text.UTF8Encoding]::new($false))
    if (Test-Path $NotesFile) { [IO.File]::Replace($tmp, $NotesFile, "$NotesFile.bak") } else { Move-Item $tmp $NotesFile }
}

function Invoke-Request([System.Net.HttpListenerContext]$Ctx) {
    $req = $Ctx.Request
    $path = [Uri]::UnescapeDataString($req.Url.AbsolutePath)
    $utf8 = [Text.UTF8Encoding]::new($false)

    if ($path -eq '/api/ping') { Send $Ctx 204; return }
    if ($path -eq '/api/world') { Send-Json $Ctx $WorldData; return }
    if ($path -eq '/api/party') { Send-Json $Ctx (Get-Party); return }
    if ($path -match '^/api/game/([A-Z0-9_]+\.[A-Z]+)$' -and $GameFiles -contains $Matches[1]) {
        Send $Ctx 200 ([IO.File]::ReadAllBytes((Join-Path $Root $Matches[1]))) 'application/octet-stream'; return
    }
    if ($path -eq '/api/notes') {
        if ($req.HttpMethod -eq 'GET') {
            $json = if (Test-Path $NotesFile) { [IO.File]::ReadAllText($NotesFile) } else { '{}' }
            Send $Ctx 200 $utf8.GetBytes($json) $Types['.json']
        }
        elseif ($req.HttpMethod -eq 'PUT') {
            $reader = [IO.StreamReader]::new($req.InputStream, $utf8)
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
            try { $null = $body | ConvertFrom-Json } catch { Send $Ctx 400 $utf8.GetBytes('Notes must be JSON'); return }
            Save-Notes $body
            Send $Ctx 200 $utf8.GetBytes((@{ savedTo = $NotesFile } | ConvertTo-Json -Compress)) $Types['.json']
        }
        else { Send $Ctx 405 }
        return
    }

    if ($req.HttpMethod -ne 'GET') { Send $Ctx 405; return }
    if ($path -eq '/') { $path = '/index.html' }
    $file = [IO.Path]::GetFullPath((Join-Path $WebRoot $path.TrimStart('/')))
    if (-not $file.StartsWith($WebRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $file -PathType Leaf)) {
        Send $Ctx 404 $utf8.GetBytes('Not found'); return
    }
    $type = $Types[[IO.Path]::GetExtension($file).ToLower()]
    if (-not $type) { $type = 'application/octet-stream' }
    Send $Ctx 200 ([IO.File]::ReadAllBytes($file)) $type
}

$Places = @(Get-Places)
$WorldData = [ordered]@{ places = $Places; gates = @(Get-Gates); items = @(Get-HiddenItems) }
$GameFiles = @('WORLD.MAP', 'SHAPES.EGA') + @($Places | ForEach-Object { $_.ult; $_.tlk; $_.dng } | Where-Object { $_ })

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Url)
try { $listener.Start() }
catch {
    # Most likely already running from an earlier launch. That one may be an older version of this
    # script (it stays up while a map tab is open), so stop it and take over rather than reuse it.
    $old = Get-CimInstance Win32_Process -Filter "ProcessId != $PID" |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($PSCommandPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
    $old | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Url)
    $started = $false
    foreach ($try in 1..10) {
        Start-Sleep -Milliseconds 300
        try { $listener.Start(); $started = $true; break } catch { }
    }
    if (-not $started) {
        # Something else holds the port - just show what's there.
        if (-not $NoBrowser) { Start-Process $Url }
        exit 0
    }
}
Write-Host "Ultima 4 map at $Url  (game: $Root, notes: $NotesFile)"
if (-not $NoBrowser) { Start-Process $Url }

$idle = 0
try {
    while ($listener.IsListening) {
        $pending = $listener.BeginGetContext($null, $null)
        while (-not $pending.AsyncWaitHandle.WaitOne(1000)) {
            # Counted in waits, not by the clock: when the PC wakes from sleep the clock has jumped
            # hours ahead, and an open page hasn't had a chance to ping yet.
            if (++$idle -ge $IdleLimit) { Write-Host 'No map open - exiting.'; return }
        }
        $ctx = $listener.EndGetContext($pending)
        $idle = 0
        try { Invoke-Request $ctx }
        catch {
            Write-Warning $_.Exception.Message
            try { Send $ctx 500 ([Text.Encoding]::UTF8.GetBytes($_.Exception.Message)) } catch { }
        }
    }
}
finally { $listener.Close() }
