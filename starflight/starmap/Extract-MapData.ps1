<#
  Extracts the hyperspace map (stars, flux nodes, nebulae) from Starflight's
  STARB.COM and writes web\map-data.json for the star map viewer.

  Reads the pristine STARFLT\START copy by default; the map never changes in play.

  STARB.COM holds the game's instance tree. Every node starts with an 11-byte header:
    +0 sibling (3 bytes)  +3 previous (3 bytes)  +6 first child (3 bytes)
    +9 class              +10 species
  The star systems, flux nodes, nebulae (and alien encounter spawns) are all
  siblings in one circular list. Classes and fields used here:
    0x17 STARSYSTEM  species = spectral class letter, +13 X*8, +15 Y*8
    0x2D FLUX-NODE   +13 X*8, +15 Y*8; partner node at +11 X*8, +17 Y*8
    0x2E NEBULA      species = size, +13 X*8, +15 Y*8
  A star system's +17 is its orbit mask (bit 0 = orbit 1). Its children hold one
  planet (class 0x20) per set bit, innermost first, either directly or as the first
  child of a BOX (0x0B); a BOX holding the STAR (0x18) is skipped. The planet's
  species indexes the PLANET table (22-byte records, located through STARA.COM's
  directory): +0 size class, +1 surface 1 gas, 2 liquid, 3 frozen, 4 molten, 5 rock.
  Structure documented by https://github.com/s-macke/starflight-reverse

  Usage:  .\Extract-MapData.ps1 [-GameDir <install folder>] [-Source <STARB.COM>]
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [string]$Source,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'web\map-data.json' }  # $PSScriptRoot is empty in param defaults on PS 5.1

if (-not $Source) {
    $candidates = @($GameDir, $env:STARFLIGHT_DIR,
                    (Join-Path ${env:ProgramFiles(x86)} 'GOG Galaxy\Games\Starflight'),
                    (Join-Path $env:ProgramFiles 'GOG Galaxy\Games\Starflight'))
    if ($GameDir) { $candidates = @($GameDir) }
    $Source = $candidates | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'STARFLT\START\STARB.COM' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Source) { throw 'STARB.COM not found. Pass -GameDir (the folder containing STARFLT) or -Source.' }
}

$d = [IO.File]::ReadAllBytes((Resolve-Path $Source).Path)
$classes = 'OBAFGKM'
$surfaces = @{ 1 = 'gas'; 2 = 'liquid'; 3 = 'frozen'; 4 = 'molten'; 5 = 'rock' }

# STARA.COM opens with a directory of 21-byte entries: name (12), file, start, end, ...
# Starts count 16-byte paragraphs across STARA then STARB.
$staraPath = Join-Path (Split-Path (Resolve-Path $Source).Path) 'STARA.COM'
if (-not (Test-Path $staraPath)) { throw "STARA.COM not found next to $Source (needed for the planet table)." }
$da = [IO.File]::ReadAllBytes($staraPath)
$planetTable = -1
for ($e = 0; $e -lt 4096; $e += 21) {
    if ([Text.Encoding]::ASCII.GetString($da, $e, 12).TrimEnd() -eq 'PLANET' -and $da[$e + 12] -eq 2) {
        $planetTable = [BitConverter]::ToUInt16($da, $e + 13) * 16 - $da.Length; break
    }
}
if ($planetTable -lt 0) { throw 'PLANET table not found in the STARA.COM directory.' }

function P3([int]$a) { [int]$d[$a] -bor ([int]$d[$a + 1] -shl 8) -bor ([int]$d[$a + 2] -shl 16) }  # [int] first: byte -shl overflows
function U16([int]$a) { [BitConverter]::ToUInt16($d, $a) }
function Get-PlanetType([int]$species) {
    # Records never straddle a 1024-byte block; the gap is padding.
    $o = $planetTable
    for ($i = 0; $i -lt $species; $i++) {
        $o += 22
        if ([Math]::Floor(($o + 21) / 1024) -ne [Math]::Floor($o / 1024)) { $o = ([Math]::Floor($o / 1024) + 1) * 1024 }
    }
    $surface = $surfaces[[int]$d[$o + 1]]
    if (-not $surface) { $surface = 'unknown' }
    [ordered]@{ size = [int]$d[$o]; surface = $surface }
}
function Get-Planets([int]$a) {
    $mask = $d[$a + 17]
    $node = P3 ($a + 6)
    $planets = @()
    for ($orbit = 1; $orbit -le 8; $orbit++) {
        if (-not ($mask -band (1 -shl ($orbit - 1)))) { continue }
        $p = $node
        if ($d[$node + 9] -eq 0x0B) {
            $p = P3 ($node + 6)
            if ($d[$p + 9] -eq 0x18) { $node = P3 $node; $p = P3 ($node + 6) }
        }
        if ($d[$p + 9] -ne 0x20) { throw ('Unexpected record 0x{0:x} in orbit {1} of the star system at 0x{2:x}.' -f $p, $orbit, $a) }
        $t = Get-PlanetType $d[$p + 10]
        $planets += [ordered]@{ orbit = $orbit; surface = $t.surface; size = $t.size }
        $node = P3 $node
    }
    , $planets
}
function Test-Linked([int]$a) {
    $s = P3 $a; $p = P3 ($a + 3)
    $s -lt $d.Length - 20 -and $p -lt $d.Length - 20 -and (P3 $p) -eq $a -and (P3 ($s + 3)) -eq $a
}

# Any star system whose sibling links agree in both directions anchors the list.
$start = -1
for ($a = 0; $a -lt $d.Length - 20; $a++) {
    if ($d[$a + 9] -eq 0x17 -and $classes.IndexOf([char]$d[$a + 10]) -ge 0 -and (Test-Linked $a)) { $start = $a; break }
}
if ($start -lt 0) { throw "No star system records found in $Source." }

$stars = [Collections.Generic.List[object]]::new()
$flux = [Collections.Generic.List[object]]::new()
$nebulae = [Collections.Generic.List[object]]::new()
$fluxSeen = @{}
$a = $start
do {
    $x = (U16 ($a + 13)) / 8; $y = (U16 ($a + 15)) / 8
    switch ($d[$a + 9]) {
        0x17 { $stars.Add([ordered]@{ x = $x; y = $y; cls = [string][char]$d[$a + 10]; planets = (Get-Planets $a) }) }
        0x2D {
            $px = (U16 ($a + 11)) / 8; $py = (U16 ($a + 17)) / 8
            $key = (@("$x,$y", "$px,$py") | Sort-Object) -join '|'
            if (-not $fluxSeen[$key]) { $fluxSeen[$key] = $true; $flux.Add([ordered]@{ a = @($x, $y); b = @($px, $py) }) }
        }
        0x2E { $nebulae.Add([ordered]@{ x = $x; y = $y; size = [int]$d[$a + 10] }) }
    }
    $a = P3 $a
} while ($a -ne $start -and $stars.Count -lt 10000)

$dupes = $stars | Group-Object { "$($_.x),$($_.y)" } | Where-Object Count -gt 1
if ($dupes) { Write-Warning "Stars sharing coordinates: $($dupes.Name -join '; ')" }

$out = [ordered]@{
    source  = 'Extracted from Starflight (1986) STARB.COM by Extract-MapData.ps1'
    width   = 250
    height  = 220
    stars   = $stars | Sort-Object { $_.x }, { $_.y }
    flux    = $flux
    nebulae = $nebulae
}
$json = $out | ConvertTo-Json -Depth 5 -Compress
[IO.File]::WriteAllText($OutFile, $json, [Text.UTF8Encoding]::new($false))
$planetCount = ($stars | ForEach-Object { $_.planets.Count } | Measure-Object -Sum).Sum
Write-Host ("Wrote {0}: {1} stars, {2} planets, {3} flux lines, {4} nebulae" -f $OutFile, $stars.Count, $planetCount, $flux.Count, $nebulae.Count)
