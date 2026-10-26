<#
  Renders Ultima 1's maps to PNG from the game's own files, using its EGA tiles.

    out\world.png               the overworld, all four lands (168 x 156 tiles of 16 px)
    out\castle-1.png, -2.png    the two castle layouts (38 x 18 tiles of 8 px)
    out\town-1.png .. -8.png    the eight town layouts

  MAP.BIN   overworld, one 4-bit value per tile, high nibble first, row by row.
            0 water, 1 grass, 2 forest, 3 mountains, 4 castle, 5 signpost/landmark,
            6 town, 7 dungeon entrance.
  TCD.BIN   ten 38 x 18 town/castle layouts of one byte per tile, stored column by
            column; castles first. Values 0-50 are EGATOWN.BIN tile numbers (24-49 are
            the letters A-Z of shop signs); 51-63 mark shop zones and are drawn as floor.
  EGATILES.BIN / EGATOWN.BIN
            EGA tiles (16 px / 8 px), each pixel row stored as 4 bit planes.
  People and monsters aren't in the map files; the game places them on entry.

  Usage:  .\Export-Maps.ps1 [-GameDir <install folder>] [-OutDir <folder>] [-Scale 2]
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [string]$OutDir,
    [ValidateRange(1, 8)][int]$Scale = 1        # world tiles are drawn 16*Scale px, town tiles 8*Scale*2
)

$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }   # $PSScriptRoot is empty in param defaults on PS 5.1

$candidates = @($GameDir, $env:ULTIMA1_DIR,
                (Join-Path ${env:ProgramFiles(x86)} 'GOG Galaxy\Games\Ultima 1'),
                (Join-Path $env:ProgramFiles 'GOG Galaxy\Games\Ultima 1'))
if ($GameDir) { $candidates = @($GameDir) }
$Root = $candidates | Where-Object { $_ -and (Test-Path (Join-Path $_ 'MAP.BIN')) } | Select-Object -First 1
if (-not $Root) { throw 'Ultima 1 install not found. Pass -GameDir (the folder containing MAP.BIN) or set ULTIMA1_DIR.' }

Add-Type -AssemblyName System.Drawing
$Ega = @(0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
         0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF)

function Read-Tiles([string]$Name, [int]$Size) {
    $b = [IO.File]::ReadAllBytes((Join-Path $Root $Name))
    $rowBytes = $Size / 8; $tileBytes = $Size * $Size / 2
    for ($t = 0; $t -lt [math]::Floor($b.Length / $tileBytes); $t++) {
        $bmp = New-Object System.Drawing.Bitmap $Size, $Size
        for ($y = 0; $y -lt $Size; $y++) {
            for ($x = 0; $x -lt $Size; $x++) {
                $c = 0
                for ($p = 0; $p -lt 4; $p++) {
                    if ($b[$t * $tileBytes + ($y * 4 + $p) * $rowBytes + ($x -shr 3)] -band (0x80 -shr ($x % 8))) { $c = $c -bor (1 -shl $p) }
                }
                $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, ($Ega[$c] -shr 16) -band 255, ($Ega[$c] -shr 8) -band 255, $Ega[$c] -band 255))
            }
        }
        , $bmp
    }
}

function New-Canvas([int]$W, [int]$H) {
    $img = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($img)
    $g.InterpolationMode = 'NearestNeighbor'; $g.PixelOffsetMode = 'Half'
    $img, $g
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# ---------------------------------------------------------------- overworld

$tiles  = @(Read-Tiles 'EGATILES.BIN' 16)
$tileOf = @(0, 1, 2, 3, 4, 6, 7, 9)                 # map value -> tile (5 and 8 are animation frames)
$map    = [IO.File]::ReadAllBytes((Join-Path $Root 'MAP.BIN'))
$W = 168; $H = 156; $ts = 16 * $Scale
$img, $g = New-Canvas ($W * $ts) ($H * $ts)
for ($i = 0; $i -lt $W * $H; $i++) {
    $v = if ($i % 2 -eq 0) { $map[$i -shr 1] -shr 4 } else { $map[$i -shr 1] -band 15 }
    $g.DrawImage($tiles[$tileOf[$v]], ($i % $W) * $ts, [math]::Floor($i / $W) * $ts, $ts, $ts)
}
$img.Save((Join-Path $OutDir 'world.png')); $g.Dispose(); $img.Dispose()
Write-Host "world.png      $($W * $ts) x $($H * $ts)"

# ---------------------------------------------------------------- towns and castles

$tiles = @(Read-Tiles 'EGATOWN.BIN' 8)
$tcd   = [IO.File]::ReadAllBytes((Join-Path $Root 'TCD.BIN'))
$W = 38; $H = 18; $ts = 16 * $Scale
for ($m = 0; $m -lt [math]::Floor($tcd.Length / ($W * $H)); $m++) {
    $img, $g = New-Canvas ($W * $ts) ($H * $ts)
    for ($x = 0; $x -lt $W; $x++) {
        for ($y = 0; $y -lt $H; $y++) {
            $v = $tcd[$m * $W * $H + $x * $H + $y]
            if ($v -ge $tiles.Count) { $v = 1 }     # shop zone marker: plain floor
            $g.DrawImage($tiles[$v], $x * $ts, $y * $ts, $ts, $ts)
        }
    }
    $name = if ($m -lt 2) { "castle-$($m + 1).png" } else { "town-$($m - 1).png" }
    $img.Save((Join-Path $OutDir $name)); $g.Dispose(); $img.Dispose()
    Write-Host ('{0,-14} {1} x {2}' -f $name, ($W * $ts), ($H * $ts))
}
Write-Host "Saved to $OutDir"
