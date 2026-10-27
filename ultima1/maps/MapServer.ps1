<#
  Ultima 1 interactive map - tiny local web server for the map viewer in .\web.

  Serves the page on http://localhost:<port>/, the game's own map and tile files from the
  install (the art is never copied into the repo), the place names and positions read from
  OUT.EXE, and where your characters are from their saves. Notes are kept in a JSON file
  (default .\map-notes.json, previous version kept as .bak). Opens the browser on start,
  and exits on its own a few minutes after the last map tab closes.

  MapServer.ps1 [-GameDir <install folder>] [-Port 8643] [-NotesFile <path>] [-NoBrowser]
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [int]$Port = 8643,
    [string]$NotesFile,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$candidates = @($GameDir, $env:ULTIMA1_DIR,
                (Join-Path ${env:ProgramFiles(x86)} 'GOG Galaxy\Games\Ultima 1'),
                (Join-Path $env:ProgramFiles 'GOG Galaxy\Games\Ultima 1'))
if ($GameDir) { $candidates = @($GameDir) }
$Root = $candidates | Where-Object { $_ -and (Test-Path (Join-Path $_ 'MAP.BIN')) } | Select-Object -First 1
if (-not $Root) {
    $msg = 'Ultima 1 install not found. Pass -GameDir (the folder containing MAP.BIN) or set ULTIMA1_DIR.'
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Ultima 1 Map', 'OK', 'Error')
    throw $msg
}
$PlayDir = Join-Path $Root 'cloud_saves'                 # DOSBox overlay on C:\ - where the game actually writes

$WebRoot = Join-Path $PSScriptRoot 'web'
if (-not $NotesFile) { $NotesFile = Join-Path $PSScriptRoot 'map-notes.json' }
$NotesFile = [IO.Path]::GetFullPath($NotesFile)
$Url = "http://localhost:$Port/"
$IdleLimit = [TimeSpan]::FromMinutes(3)   # page pings every 30s; background tabs may throttle to once a minute
$GameFiles = @('MAP.BIN', 'EGATILES.BIN', 'EGATOWN.BIN', 'TCD.BIN')

$Types = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'
    '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
    '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'
}

# ---------------------------------------------------------------- game data

function Get-Places {
    <# The 84 places, from OUT.EXE (GOG release). The game finds the place you're standing on
       by looking your position up in two 84-byte tables, x then y (code 0xA3BA), and prints
       its name from a pointer table indexed the same way (data offset 0x307E). Places 1-32 are
       towns, 33-40 castles, 41-48 landmarks and signposts, 49-84 dungeons. Towns use town
       layout (n-1) mod 8 and castles castle layout (n-1) mod 2 (code 0x4E63 / 0x4DBF). The
       land is 2*(y > 77) + (x > 83) (code 0xB956). #>
    $exe = [IO.File]::ReadAllBytes((Join-Path $Root 'OUT.EXE'))
    $map = [IO.File]::ReadAllBytes((Join-Path $Root 'MAP.BIN'))
    $dataBase = 0xD680; $names = 0x106FE; $xs = 0xEF48; $ys = 0xEF9C   # file offsets
    $kinds = @(@{ Kind = 'town'; Tile = 6; N = 32 }, @{ Kind = 'castle'; Tile = 4; N = 8 },
               @{ Kind = 'landmark'; Tile = 5; N = 8 }, @{ Kind = 'dungeon'; Tile = 7; N = 36 })
    if ($exe.Length -lt $names + 168) { throw 'OUT.EXE is not the version this map knows.' }
    $id = 0
    foreach ($k in $kinds) {
        for ($i = 0; $i -lt $k.N; $i++) {
            $p = [BitConverter]::ToUInt16($exe, $names + 2 * $id) + $dataBase
            $end = [Array]::IndexOf($exe, [byte]0, $p)
            $x = $exe[$xs + $id]; $y = $exe[$ys + $id]
            $t = $y * 168 + $x
            $tile = if ($t % 2 -eq 0) { $map[$t -shr 1] -shr 4 } else { $map[$t -shr 1] -band 15 }
            if ($tile -ne $k.Tile -or $end -lt 0 -or $end - $p -gt 40) { throw 'OUT.EXE is not the version this map knows.' }
            $id++
            $layout = switch ($k.Kind) { 'town' { 'town-' + (($id - 1) % 8 + 1) } 'castle' { 'castle-' + (($id - 1) % 2 + 1) } default { $null } }
            [ordered]@{
                id = $id; kind = $k.Kind; x = $x; y = $y
                name = [Text.Encoding]::ASCII.GetString($exe, $p, $end - $p)
                land = 2 * [int]($y -gt 77) + [int]($x -gt 83)
                layout = $layout
            }
        }
    }
}

function Get-DungeonSpots {
    <# Dungeons aren't stored: OUT.EXE builds each level as you arrive (code 0x4761). Besides its
       random walls and doors it puts a few walls or force fields on spots from a 16-entry table,
       x at data offset 0x3820 and y at 0x3840 (swapped on even levels). The page needs that
       table to build the same levels. #>
    $exe = [IO.File]::ReadAllBytes((Join-Path $Root 'OUT.EXE'))
    $xs = 0xD680 + 0x3820; $ys = 0xD680 + 0x3840
    foreach ($i in 0..15) {
        $x = [BitConverter]::ToInt16($exe, $xs + 2 * $i); $y = [BitConverter]::ToInt16($exe, $ys + 2 * $i)
        if ($x -lt 1 -or $x -gt 9 -or $y -lt 1 -or $y -gt 9) { throw 'OUT.EXE is not the version this map knows.' }
        [ordered]@{ x = $x; y = $y }
    }
}

function Get-Characters {
    # Same record as the save manager reads (see ..\save-manager\README.md).
    $races = @('Human', 'Elf', 'Dwarf', 'Bobbit'); $classes = @('Fighter', 'Cleric', 'Wizard', 'Thief'); $sexes = @('Male', 'Female')
    foreach ($n in 1..4) {
        $file = "PLAYER$n.U1"
        $path = @((Join-Path $PlayDir $file), (Join-Path $Root $file)) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $path) { continue }
        $b = [IO.File]::ReadAllBytes($path)
        if ($b.Length -lt 0x38) { continue }
        $w = { param($o) [int][BitConverter]::ToUInt16($b, $o) }
        $pick = { param($arr, $i) if ($i -lt $arr.Count) { $arr[$i] } else { "?$i" } }
        $end = [Array]::IndexOf($b, [byte]0, 0, 16); if ($end -lt 0) { $end = 16 }
        [ordered]@{
            slot = $n
            name = [Text.Encoding]::ASCII.GetString($b, 0, $end).Trim()
            race = & $pick $races (& $w 0x10); class = & $pick $classes (& $w 0x12); sex = & $pick $sexes (& $w 0x14)
            hits = & $w 0x16; coin = & $w 0x24; exp = & $w 0x26; food = & $w 0x28
            level = [math]::Floor((& $w 0x26) / 1000) + 1
            x = & $w 0x34; y = & $w 0x36
            seed = & $w 0x32          # set when the character is made; seeds the dungeon levels
            saved = (Get-Item -LiteralPath $path).LastWriteTime.ToString('s')
        }
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
    $json = ConvertTo-Json -InputObject @($Value) -Depth 5 -Compress
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
    if ($path -eq '/api/places') { Send-Json $Ctx $Places; return }
    if ($path -eq '/api/dungeon-spots') { Send-Json $Ctx $DungeonSpots; return }
    if ($path -eq '/api/characters') { Send-Json $Ctx @(Get-Characters); return }
    if ($path -match '^/api/game/([A-Z]+\.BIN)$' -and $GameFiles -contains $Matches[1]) {
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
$DungeonSpots = @(Get-DungeonSpots)

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Url)
try { $listener.Start() }
catch {
    # Most likely already running from an earlier launch. That one may be an older version of this
    # script (it stays up while a map tab is open), so stop it and take over rather than reuse it.
    $old = Get-CimInstance Win32_Process -Filter "ProcessId != $PID" |
        Where-Object { $_.CommandLine -like '*MapServer.ps1*' }
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
Write-Host "Ultima 1 map at $Url  (game: $Root, notes: $NotesFile)"
if (-not $NoBrowser) { Start-Process $Url }

$lastSeen = [DateTime]::Now
try {
    while ($listener.IsListening) {
        $pending = $listener.BeginGetContext($null, $null)
        while (-not $pending.AsyncWaitHandle.WaitOne(1000)) {
            if ([DateTime]::Now - $lastSeen -gt $IdleLimit) { Write-Host 'No map open - exiting.'; return }
        }
        $ctx = $listener.EndGetContext($pending)
        $lastSeen = [DateTime]::Now
        try { Invoke-Request $ctx }
        catch {
            Write-Warning $_.Exception.Message
            try { Send $ctx 500 ([Text.Encoding]::UTF8.GetBytes($_.Exception.Message)) } catch { }
        }
    }
}
finally { $listener.Close() }
