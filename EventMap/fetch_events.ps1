#+------------------------------------------------------------------+
#|  fetch_events.ps1  —  EventMap external feed                     |
#|                                                                  |
#|  Pulls the economic calendar from outside providers and writes a  |
#|  normalized feed into the MT5 terminal data folder:               |
#|                                                                  |
#|      <terminal>\MQL5\Files\EventMap\events.csv                    |
#|                                                                  |
#|  The EventMap indicator reads that file. WebRequest is not        |
#|  available inside indicators, so an external process has to do    |
#|  the fetching.                                                    |
#|                                                                  |
#|  PROVIDERS                                                        |
#|    ff         Forex Factory weekly JSON (works, no key)           |
#|    tv         TradingView economic calendar JSON (works, no key)   |
#|    investing  Investing.com calendar endpoint (usually blocked    |
#|               by Cloudflare; adapter reports and skips)           |
#|                                                                  |
#|  OUTPUT FORMAT  (pipe separated, epoch is UTC seconds)            |
#|    # eventmap 1                                                   |
#|    # generated=2026-10-21T13:20:00Z provider=ff,tv rows=263       |
#|    epoch|cur|impact|title|actual|forecast|previous|source         |
#|    1792590600|USD|high|Core CPI m/m|0.3%|0.2%|0.1%|ff             |
#|                                                                  |
#|  USAGE                                                            |
#|    powershell -ExecutionPolicy Bypass -File fetch_events.ps1      |
#|    powershell ... -Provider ff -DaysForward 14 -AllTerminals      |
#+------------------------------------------------------------------+
#requires -Version 5.1
[CmdletBinding()]
param(
  # ff, tv, investing — comma separated also accepted (powershell -File passes one string)
  [string[]] $Provider   = @('ff','tv'),

  [int]      $DaysBack    = 2,
  [int]      $DaysForward = 8,

  # Empty = auto-detect the terminal data folder(s)
  [string]   $OutDir      = '',
  [switch]   $AllTerminals,

  [string]   $Countries   = 'US,EU,GB,JP,CA,AU,NZ,CH,CN,DE,FR,IT,ES',

  # Proxy: http://host:port , socks5://host:port , socks5h://host:port (DNS via proxy)
  # Falls back to the EVENTMAP_PROXY / EVENTMAP_PROXY_USER environment variables.
  [string]   $Proxy       = '',
  [string]   $ProxyUser   = '',
  [switch]   $ProxyTest,

  [switch]   $Quiet,
  [switch]   $PassThru
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$UA    = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
$Now   = [DateTime]::UtcNow
$From  = $Now.AddDays(-$DaysBack)
$To    = $Now.AddDays($DaysForward)
$Rows  = New-Object System.Collections.ArrayList
$Seen  = @{}
$Notes = New-Object System.Collections.ArrayList

# Normalize provider list: supports -Provider ff,tv and -Provider @('ff','tv')
$Providers = @()
foreach ($p in $Provider) { $Providers += ($p -split ',') }
$Providers = @($Providers | ForEach-Object { ('' + $_).Trim().ToLower() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
foreach ($p in $Providers) {
  if ($p -notin @('ff','tv','investing')) {
    throw "Unknown provider '$p'. Use ff, tv, investing."
  }
}

#==================================================================
#  PROXY + HTTP LAYER
#  curl.exe is used for everything: PowerShell 5.1 cannot do SOCKS,
#  and one code path for direct/proxy keeps behaviour identical.
#==================================================================
if ($Proxy -eq '' -and $env:EVENTMAP_PROXY)      { $Proxy     = $env:EVENTMAP_PROXY }
if ($ProxyUser -eq '' -and $env:EVENTMAP_PROXY_USER) { $ProxyUser = $env:EVENTMAP_PROXY_USER }

$Curl = $null
$cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($cmd) { $Curl = $cmd.Source }

if ($Proxy -ne '' -and -not $Curl) {
  Write-Warning 'curl.exe not found: SOCKS proxies unavailable, falling back to .NET (HTTP proxies only).'
}

function Get-SafeProxy([string]$p) {
  if ($p -eq '') { return 'direct (no proxy)' }
  return ($p -replace '//[^/@]+@', '//***@')
}

function Invoke-Http {
  param(
    [Parameter(Mandatory=$true)][string] $Url,
    [string]    $Method    = 'GET',
    [hashtable] $Headers   = @{},
    [string]    $Body      = '',
    [int]       $TimeoutSec = 30,
    [int]       $Retry      = 1
  )

  $attempt = 0
  while ($true) {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
      if ($Curl) {
        $a = @('--silent','--show-error','--location','--compressed',
               '--max-time', "$TimeoutSec",
               '-w','%{http_code}','-o',$tmp)
        if ($Method -ne 'GET')  { $a += @('-X',$Method) }
        if ($Proxy -ne '')      { $a += @('--proxy',$Proxy) }
        if ($ProxyUser -ne '')  { $a += @('--proxy-user',$ProxyUser) }
        foreach ($k in $Headers.Keys) { $a += @('-H', ("{0}: {1}" -f $k, $Headers[$k])) }
        if ($Body -ne '')       { $a += @('--data-raw',$Body) }
        $a += $Url

        $raw = (& $Curl @a 2>&1 | Out-String).Trim()

        $status = 0
        $m = [regex]::Match($raw, '(\d{3})\s*$')
        if ($m.Success) { $status = [int]$m.Groups[1].Value }

        $text = ''
        if (Test-Path $tmp) { $text = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8) }

        $err    = ($raw -replace '\d{3}\s*$','').Trim()
        $result = [pscustomobject]@{ Status = $status; Body = $text; Error = $err }
      }
      else {
        # --- .NET fallback: HTTP/HTTPS proxies only, no SOCKS -----
        $p = @{ Uri = $Url; UseBasicParsing = $true; TimeoutSec = $TimeoutSec
                Headers = $Headers; Method = $Method }
        if ($Proxy -ne '') {
          $wp = New-Object System.Net.WebProxy($Proxy)
          if ($ProxyUser -ne '') {
            $bits = $ProxyUser -split ':',2
            $wp.Credentials = New-Object System.Net.NetworkCredential($bits[0], $(if ($bits.Count -gt 1) { $bits[1] } else { '' }))
          }
          $p['Proxy'] = $wp
        }
        if ($Body -ne '') { $p['Body'] = $Body }
        $r = Invoke-WebRequest @p
        $result = [pscustomobject]@{ Status = [int]$r.StatusCode; Body = $r.Content; Error = '' }
      }
    }
    catch {
      $result = [pscustomobject]@{ Status = 0; Body = ''; Error = $_.Exception.Message }
    }
    finally {
      if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }

    # 429 = rate limited, 5xx = provider hiccup, 0 = network/proxy error
    $retryable = ($result.Status -eq 0 -or $result.Status -eq 429 -or $result.Status -ge 500)
    if ($retryable -and $attempt -lt $Retry) {
      $attempt++
      if ($result.Status -eq 429) { Start-Sleep -Seconds 10 } else { Start-Sleep -Seconds 3 }
      continue
    }
    return $result
  }
}

# Body/headers for the Investing.com calendar endpoint (shared with -ProxyTest)
function Get-InvestingRequest {
  $b = @(
    'country%5B%5D=',
    'importance%5B%5D=1',
    'importance%5B%5D=2',
    'importance%5B%5D=3',
    "dateFrom=$($From.ToString('yyyy-MM-dd'))",
    "dateTo=$($To.ToString('yyyy-MM-dd'))",
    'timeZone=55',
    'timeFilter=timeRemain',
    'currentTab=custom',
    'limit_from=0'
  ) -join '&'
  $h = @{
    'User-Agent'       = $UA
    'X-Requested-With' = 'XMLHttpRequest'
    'Referer'          = 'https://www.investing.com/economic-calendar/'
    'Accept'           = 'application/json, text/javascript, */*; q=0.01'
    'Content-Type'     = 'application/x-www-form-urlencoded'
    'Origin'           = 'https://www.investing.com'
  }
  return [pscustomobject]@{ Url = 'https://www.investing.com/economic-calendar/Service/getCalendarFilteredData'; Body = $b; Headers = $h }
}

function Test-Egress {
  Write-Host ''
  Write-Host ("Proxy: {0}" -f (Get-SafeProxy $Proxy)) -ForegroundColor Cyan

  $ip = Invoke-Http -Url 'https://api.ipify.org?format=json' -TimeoutSec 20
  if ($ip.Status -eq 200) {
    $v = $ip.Body
    try { $v = ($ip.Body | ConvertFrom-Json).ip } catch { }
    Write-Host ("  egress IP        {0}" -f $v) -ForegroundColor Green
  }
  else {
    Write-Host ("  egress IP        FAILED  {0}" -f ($ip.Error -replace '\s+',' ')) -ForegroundColor Red
  }

  $inv = Get-InvestingRequest
  $checks = @(
    @{ n = 'Forex Factory'; u = 'https://nfs.faireconomy.media/ff_calendar_thisweek.json'; m = 'GET'; b = ''; h = @{ 'User-Agent' = $UA } },
    @{ n = 'TradingView';   u = ('https://economic-calendar.tradingview.com/events?from={0}&to={1}&countries=US' -f $From.ToString('yyyy-MM-ddTHH:mm:ss.000Z'), $To.ToString('yyyy-MM-ddTHH:mm:ss.000Z')); m = 'GET'; b = ''; h = @{ 'Origin' = 'https://www.tradingview.com'; 'Referer' = 'https://www.tradingview.com/'; 'User-Agent' = $UA } },
    @{ n = 'Investing.com'; u = $inv.Url; m = 'POST'; b = $inv.Body; h = $inv.Headers }
  )

  foreach ($c in $checks) {
    $r = Invoke-Http -Url $c.u -Method $c.m -Headers $c.h -Body $c.b -TimeoutSec 25
    $ok = ($r.Status -eq 200)
    $note = if ($ok) { 'ok' } else { ($r.Error -replace '\s+',' ') }
    if ($note.Length -gt 60) { $note = $note.Substring(0,60) }
    if ($ok) { Write-Host ("  {0,-15}  HTTP {1}  ok" -f $c.n, $r.Status) -ForegroundColor Green }
    else     { Write-Host ("  {0,-15}  HTTP {1}  {2}" -f $c.n, $r.Status, $note) -ForegroundColor Red }
  }
  Write-Host ''
}

function Write-Note([string]$m) {
  [void]$Notes.Add($m)
  if (-not $Quiet) { Write-Host "  $m" -ForegroundColor DarkGray }
}

function ConvertTo-Impact([string]$s) {
  switch (('' + $s).Trim().ToLower()) {
    'high'     { return 'high' }
    '3'        { return 'high' }
    'medium'   { return 'medium' }
    'moderate' { return 'medium' }
    '2'        { return 'medium' }
    'low'      { return 'low' }
    '1'        { return 'low' }
    default    { return 'low' }
  }
}

function Clean([string]$s) {
  if ($null -eq $s) { return '' }
  $s = ('' + $s) -replace '[^\x20-\x7E]', ''      # ASCII only: MQL5 FILE_ANSI safe
  $s = $s -replace '\|', '/'                       # pipe is the delimiter
  $s = $s -replace '\s+', ' '
  return $s.Trim()
}

function Add-Row([long]$epoch, [string]$cur, [string]$impact,
                 [string]$title, [string]$actual, [string]$forecast,
                 [string]$previous, [string]$source) {
  $title = Clean $title
  if ($title -eq '') { return }
  $cur = (Clean $cur).ToUpper()
  if ($cur.Length -gt 3) { $cur = $cur.Substring(0,3) }

  $key = "$source|$epoch|$title"
  if ($Seen.ContainsKey($key)) { return }
  $Seen[$key] = 1

  [void]$Rows.Add([pscustomobject]@{
    epoch    = $epoch
    currency = $cur
    impact   = (ConvertTo-Impact $impact)
    title    = $title
    actual   = Clean $actual
    forecast = Clean $forecast
    previous = Clean $previous
    source   = $source
  })
}

function To-Epoch([datetimeoffset]$d) {
  return $d.ToUnixTimeSeconds()
}

#==================================================================
#  FOREX FACTORY
#==================================================================
function Get-FFEvents {
  $n = 0
  foreach ($week in @('lastweek','thisweek','nextweek')) {
    $url = "https://nfs.faireconomy.media/ff_calendar_$week.json"
    $r = Invoke-Http -Url $url -Headers @{ 'User-Agent' = $UA }
    if ($r.Status -ne 200) {
      if ($r.Status -eq 404) { Write-Note "ff: $week feed not published" }
      else { Write-Note "ff: $week returned HTTP $($r.Status) - $($r.Error)" }
      continue
    }
    try { $j = $r.Body | ConvertFrom-Json }
    catch { Write-Note "ff: $week JSON parse failed"; continue }
    foreach ($e in $j) {
      $d = [datetimeoffset]::Parse(('' + $e.date), [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
      if ($d -lt $From -or $d -gt $To) { continue }

      $cur = '' + $e.country
      if ($cur -eq 'All') { $cur = 'GLB' }        # not a currency: filtered out on FX charts

      Add-Row (To-Epoch $d) $cur $e.impact $e.title $e.actual $e.forecast $e.previous 'ff'
      $n++
    }
  }
  return $n
}

#==================================================================
#  TRADINGVIEW
#  importance: 1 = high, 0 = medium, -1 = low
#==================================================================
function Get-TVEvents {
  $fromIso = $From.ToString('yyyy-MM-ddTHH:mm:ss.000Z')
  $toIso   = $To.ToString('yyyy-MM-ddTHH:mm:ss.000Z')
  $url = "https://economic-calendar.tradingview.com/events?from=$fromIso&to=$toIso&countries=$Countries"

  $headers = @{
    'Origin'     = 'https://www.tradingview.com'
    'Referer'    = 'https://www.tradingview.com/'
    'User-Agent' = $UA
  }

  $r = Invoke-Http -Url $url -Headers $headers
  if ($r.Status -ne 200) {
    Write-Note "tv: HTTP $($r.Status) - $($r.Error)"
    return 0
  }
  try { $j = $r.Body | ConvertFrom-Json }
  catch { Write-Note 'tv: JSON parse failed'; return 0 }

  if ($j.status -ne 'ok') {
    Write-Note "tv: unexpected status '$($j.status)'"
    return 0
  }

  $n = 0
  foreach ($e in $j.result) {
    $d = [datetimeoffset]::Parse(('' + $e.date), [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    if ($d -lt $From -or $d -gt $To) { continue }

    $impact = switch ([int]$e.importance) { 1 { 'high' } 0 { 'medium' } default { 'low' } }
    $cur    = '' + $e.currency
    if ($cur -eq '') { $cur = '' + $e.country }

    Add-Row (To-Epoch $d) $cur $impact $e.title $e.actual $e.forecast $e.previous 'tv'
    $n++
  }
  return $n
}

#==================================================================
#  INVESTING.COM
#  Expected to be refused (Cloudflare 403) from most datacentre and
#  many residential IPs. Implemented so it starts working unchanged
#  if the request is ever allowed (proxy, allowlisted network, or a
#  future endpoint that is not bot-protected).
#==================================================================
function Get-InvestingEvents {
  $req = Get-InvestingRequest

  $r = Invoke-Http -Url $req.Url -Method Post -Headers $req.Headers -Body $req.Body
  if ($r.Status -ne 200) {
    $why = if ($r.Error -ne '') { $r.Error } else { 'no body' }
    Write-Note ("investing: HTTP {0} ({1}) - skipped" -f $r.Status, ($why -replace '\s+',' '))
    return 0
  }
  if ($r.Body.Length -lt 100) {
    Write-Note 'investing: empty response - skipped'
    return 0
  }

  # The calendar fragment carries data-event-datetime and a
  # bull1/bull2/bull3 importance marker per row.
  $n = 0
  $blocks = [regex]::Matches($r.Body, '<tr[^>]*data-event-datetime="([^"]+)"[\s\S]*?(?=<tr[^>]*data-event-datetime=|\z)')
  foreach ($b in $blocks) {
    try {
      $dtTxt = $b.Groups[1].Value -replace '/', '-'
      $d     = [datetime]::Parse($dtTxt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
      if ($d -lt $From -or $d -gt $To) { continue }

      $html = $b.Value
      $cur  = ''
      $mCur = [regex]::Match($html, 'title="([A-Za-z ]+)"')
      if ($mCur.Success) { $cur = $mCur.Groups[1].Value }
      if ($cur.Length -gt 3) {
        $map = @{ 'United States'='USD'; 'Euro Zone'='EUR'; 'United Kingdom'='GBP'; 'Japan'='JPY';
                  'Canada'='CAD'; 'Australia'='AUD'; 'New Zealand'='NZD'; 'Switzerland'='CHF';
                  'China'='CNY'; 'Germany'='EUR'; 'France'='EUR'; 'Italy'='EUR'; 'Spain'='EUR' }
        if ($map.ContainsKey($cur)) { $cur = $map[$cur] }
      }

      $imp = 'low'
      if ($html -match 'bull3') { $imp = 'high' }
      elseif ($html -match 'bull2') { $imp = 'medium' }

      $title = ''
      $mT = [regex]::Match($html, '<td class="event"[^>]*>\s*<a[^>]*>([^<]+)</a>')
      if ($mT.Success) { $title = $mT.Groups[1].Value }

      Add-Row (To-Epoch $d) $cur $imp $title '' '' '' 'investing'
      $n++
    }
    catch { continue }
  }
  if ($n -eq 0) {
    $dbg = Join-Path $PSScriptRoot 'investing_raw.html'
    try { [System.IO.File]::WriteAllText($dbg, $r.Body, [System.Text.Encoding]::UTF8) } catch { }
    Write-Note "investing: HTTP 200 but no rows parsed - raw response saved to $dbg"
  }
  return $n
}

#==================================================================
#  OUTPUT
#==================================================================
function Get-OutputDirs {
  if ($OutDir -ne '') { return @($OutDir) }

  $base = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
  $found = @()
  if (Test-Path $base) {
    foreach ($t in (Get-ChildItem $base -Directory -ErrorAction SilentlyContinue)) {
      $files = Join-Path $t.FullName 'MQL5\Files'
      if (-not (Test-Path $files)) { continue }
      $isPepper = $false
      $origin = Join-Path $t.FullName 'origin.txt'
      if (Test-Path $origin) {
        $isPepper = ((Get-Content $origin -Raw) -match 'Pepperstone')
      }
      $found += [pscustomobject]@{ Path = (Join-Path $files 'EventMap'); Pepper = $isPepper }
    }
  }
  if ($found.Count -eq 0) { throw "No MT5 terminal data folder with MQL5\Files found under $base" }

  if ($AllTerminals) { return @($found | ForEach-Object { $_.Path }) }

  $pep = $found | Where-Object { $_.Pepper } | Select-Object -First 1
  if ($pep) { return @($pep.Path) }
  return @($found[0].Path)
}

function Write-Feed([string]$dir) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null

  $sorted = $Rows | Sort-Object epoch, source
  $stamp  = $Now.ToString('yyyy-MM-ddTHH:mm:ssZ')
  $lines  = New-Object System.Collections.ArrayList
  [void]$lines.Add('# eventmap 1')
  $meta = "# generated=$stamp provider=$($Providers -join ',') rows=$($sorted.Count)"
  if ($keptSrc.Count -gt 0) {
    $meta += ' cached=' + (($keptSrc.Keys | Sort-Object) -join ',')
  }
  [void]$lines.Add($meta)
  [void]$lines.Add('epoch|cur|impact|title|actual|forecast|previous|source')

  foreach ($r in $sorted) {
    [void]$lines.Add(('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f `
      $r.epoch, $r.currency, $r.impact, $r.title, $r.actual, $r.forecast, $r.previous, $r.source))
  }

  $file = Join-Path $dir 'events.csv'
  [System.IO.File]::WriteAllLines($file, $lines, [System.Text.Encoding]::ASCII)
  return $file
}

function Read-FeedRows([string]$file) {
  $out = @()
  if (-not (Test-Path $file)) { return $out }
  foreach ($line in [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::ASCII)) {
    if ($line -match '^\s*#' -or $line -match '^epoch\|') { continue }
    $p = $line -split '\|'
    if ($p.Count -ne 8) { continue }
    $out += [pscustomobject]@{
      epoch    = [long]$p[0]; currency = $p[1]; impact = $p[2]; title = $p[3]
      actual   = $p[4];       forecast = $p[5]; previous = $p[6]; source = $p[7]
    }
  }
  return $out
}

#==================================================================
#  RUN
#==================================================================
if ($ProxyTest) {
  Test-Egress
  return
}

if (-not $Quiet) {
  Write-Host ''
  Write-Host 'EventMap feed' -ForegroundColor Cyan
  Write-Host ("  window  {0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm} UTC" -f $From, $To)
  Write-Host ("  proxy   {0}" -f (Get-SafeProxy $Proxy))
}

$OutDirs  = @(Get-OutputDirs)
$PrevRows = @()
if ($OutDirs.Count -gt 0) { $PrevRows = @(Read-FeedRows (Join-Path $OutDirs[0] 'events.csv')) }

$counts = @{}
foreach ($p in $Providers) {
  switch ($p) {
    'ff'        { $counts['ff']        = Get-FFEvents }
    'tv'        { $counts['tv']        = Get-TVEvents }
    'investing' { $counts['investing'] = Get-InvestingEvents }
  }
}

# A provider that is down or rate limited must not delete the coverage it
# already delivered, and a run for one provider must not drop the others.
$fromE = To-Epoch $From
$toE   = To-Epoch $To
$keep  = @()
foreach ($p in @('ff','tv','investing')) {
  if ($Providers -notcontains $p)      { $keep += $p }   # not refreshed this run
  elseif ($counts[$p] -eq 0)           { $keep += $p }   # refresh failed
}

$kept    = 0
$keptSrc = @{}
if ($keep.Count -gt 0 -and $PrevRows.Count -gt 0) {
  foreach ($row in $PrevRows) {
    if ($keep -notcontains $row.source) { continue }
    if ($row.epoch -lt $fromE -or $row.epoch -gt $toE) { continue }
    $before = $Rows.Count
    Add-Row $row.epoch $row.currency $row.impact $row.title $row.actual $row.forecast $row.previous $row.source
    if ($Rows.Count -gt $before) { $kept++; $keptSrc[$row.source] = 1 }
  }
  if ($kept -gt 0) {
    Write-Note ("cached: kept {0} rows for {1}" -f $kept, (($keptSrc.Keys | Sort-Object) -join ','))
  }
}

$files = @()
foreach ($dir in $OutDirs) {
  $files += Write-Feed $dir
}

if (-not $Quiet) {
  Write-Host ''
  Write-Host ("  rows    {0}" -f $Rows.Count)
  foreach ($k in $counts.Keys) {
    $note = ''
    if ($kept -gt 0 -and $keep -contains $k) { $note = '  (cached)' }
    Write-Host ("  {0,-9} {1}{2}" -f $k, $counts[$k], $note)
  }
  foreach ($f in $files) {
    Write-Host ("  wrote   {0}" -f $f) -ForegroundColor Green
  }
  Write-Host ''
}

if ($PassThru) { $Rows | Sort-Object epoch }
