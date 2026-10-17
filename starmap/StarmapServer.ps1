<#
  Starflight star map - tiny local web server for the map viewer in .\web.

  Serves the page on http://localhost:<port>/ and keeps your notes in a JSON file
  (default .\starmap-notes.json, previous version kept as .bak). Opens the browser
  on start, and exits on its own a few minutes after the last map tab closes.

  StarmapServer.ps1 [-Port 8642] [-NotesFile <path>] [-NoBrowser]
#>
[CmdletBinding()]
param(
    [int]$Port = 8642,
    [string]$NotesFile,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$WebRoot = Join-Path $PSScriptRoot 'web'
if (-not $NotesFile) { $NotesFile = Join-Path $PSScriptRoot 'starmap-notes.json' }
$NotesFile = [IO.Path]::GetFullPath($NotesFile)
$Url = "http://localhost:$Port/"
$IdleLimit = [TimeSpan]::FromMinutes(3)   # page pings every 30s; background tabs may throttle to once a minute

$Types = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'
    '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json; charset=utf-8'
    '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'
}

function Send([System.Net.HttpListenerContext]$Ctx, [int]$Status, [byte[]]$Body = @(), [string]$Type = 'text/plain; charset=utf-8') {
    $r = $Ctx.Response
    $r.StatusCode = $Status
    $r.Headers['Cache-Control'] = 'no-store'
    if ($Body.Length) { $r.ContentType = $Type; $r.ContentLength64 = $Body.Length; $r.OutputStream.Write($Body, 0, $Body.Length) }
    $r.Close()
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

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Url)
try { $listener.Start() }
catch {
    # Most likely already running from an earlier launch - just show it.
    if (-not $NoBrowser) { Start-Process $Url }
    exit 0
}
Write-Host "Star map at $Url  (notes: $NotesFile)"
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
