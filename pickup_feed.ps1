# +------------------------------------------------------------------+
# |  pickup_feed.ps1  —  pull the GitHub Actions feed into MT5         |
# |                                                                  |
# |  GitHub fetches the calendar (workflow: .github/workflows/feed.yml)|
# |  and commits feed/events.csv. This script only COPIES from there  |
# |  into the terminal data folder. It never talks to the providers.  |
# |                                                                  |
# |  USAGE                                                            |
# |    .\pickup_feed.ps1                 download once, report        |
# |    .\pickup_feed.ps1 -Install        schedule every 20 min        |
# |    .\pickup_feed.ps1 -Install -IntervalMinutes 60                 |
# |    .\pickup_feed.ps1 -Remove         remove the task              |
# +------------------------------------------------------------------+
[CmdletBinding()]
param(
  # Public repo: no token needed. If you ever make it private, use the
  # token URL form instead: https://<TOKEN>@raw.githubusercontent.com/...
  [string] $Url              = 'https://raw.githubusercontent.com/excalibur003/eventmap/main/feed/events.csv',
  [string] $Destination      = '',      # empty = auto-detect the terminal
  [int]    $IntervalMinutes  = 20,
  [string] $TaskName         = 'EventMap feed pickup',
  [switch] $Install,
  [switch] $Remove,
  [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'pickup.log'

function Note([string]$m) {
  if (-not $Quiet) { Write-Host "  $m" }
  Add-Content -Path $log -Value ("{0:s}  {1}" -f (Get-Date), $m)
}

# --- target: the terminal that actually has the indicator installed ---
function Get-Target {
  if ($Destination -ne '') { return $Destination }
  $base = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
  $best = $null
  if (Test-Path $base) {
    foreach ($t in (Get-ChildItem $base -Directory -ErrorAction SilentlyContinue)) {
      $feedDir = Join-Path $t.FullName 'MQL5\Files\EventMap'
      $origin  = Join-Path $t.FullName 'origin.txt'

      $originText = ''
      if (Test-Path $origin) {                    # MT5 writes origin.txt as UTF-16
        $b = [System.IO.File]::ReadAllBytes($origin)
        $originText = if ($b.Length -ge 2 -and $b[0] -eq 0xFF) {
          [System.Text.Encoding]::Unicode.GetString($b)
        } else {
          [System.Text.Encoding]::UTF8.GetString($b)
        }
      }
      $hasInd    = Test-Path (Join-Path $t.FullName 'MQL5\Indicators\EventMap\EventMap.ex5')
      $isPepper  = $originText -match 'Pepperstone'

      $score = 0
      if ($hasInd)   { $score = 4 }
      elseif ($isPepper) { $score = 2 }

      if ($best -eq $null -or $score -gt $best.score) {
        $best = @{ path = $feedDir; score = $score }
      }
    }
  }
  if ($best -eq $null) { throw "No terminal with MQL5\Files found under $base" }
  return $best.path
}

# --- registration / removal mirrors install_schedule.ps1 -------------
if ($Remove) {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Note "removed scheduled task '$TaskName'"
    Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Yellow
  } else {
    Write-Host "No scheduled task named '$TaskName'." -ForegroundColor Yellow
  }
  return
}

$script = $PSCommandPath
if ($Install) {
  # NOTE: do NOT append redirection like '*>> "$log"' to the arguments.
  # Task Scheduler passes them literally to powershell -File, where the
  # unbound positional '*' would bind to $Url and break every run
  # (curl: malformed URL, exit 3). Note() below already appends to $log.
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Quiet"

  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable

  Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger $trigger -Settings $settings -Force | Out-Null

  Write-Host "Scheduled task registered." -ForegroundColor Green
  Write-Host "  name      $TaskName"
  Write-Host "  every     $IntervalMinutes min"
  Write-Host "  from      $Url"
  Write-Host "  log       $log"
}

# --- the actual pickup -----------------------------------------------
$dir = Get-Target
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$Python   = 'python'
$ScriptDir = $PSScriptRoot

function Invoke-Step {
  # run a python helper; return $true if it exited 0
  # NOTE: the parameter must NOT be called $Args - that collides with the
  # automatic variable and silently receives an empty array.
  param([string]$File, [string[]]$StepArgs, [string]$Label)
  try {
    $p = Start-Process -FilePath $Python -ArgumentList (@('"' + $File + '"') + $StepArgs) `
           -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
    if ($p.ExitCode -eq 0) { Note "$Label ok"; return $true }
    Note "$Label failed (exit $($p.ExitCode)) - continuing"
  } catch {
    Note "$Label not run ($($_.Exception.Message)) - continuing"
  }
  return $false
}

# 1. cloud feed (Forex Factory, committed by GitHub Actions) -> temp file
$dest = Join-Path $dir 'events.csv'
$cloud = Join-Path $dir 'cloud_events.csv'
$final = Join-Path $dir 'events_out.csv'

curl.exe -sSfL -o $cloud $Url
if ($LASTEXITCODE -ne 0) {
  Note "curl failed (code $LASTEXITCODE) - previous events.csv kept"
  if (-not $Quiet) { Write-Host "  curl failed, kept the previous events.csv" -ForegroundColor Red }
  exit 1
}
Note ("downloaded {0}" -f (Split-Path $Url -Leaf))

# 2. investing.com via local headless browser (only if playwright is ready)
$inv  = Join-Path $dir 'feed_investing.csv'
$invArgs = @(
  "--out", "`"$inv`"",
  "--days-back", "2", "--days-forward", "8"
)
$InvOk = $false
# skip silently for 30 min after a failure so the browser is not relaunched constantly
$invState = Join-Path $env:TEMP 'eventmap_investing.ok'
$pauseState = Join-Path $env:TEMP 'eventmap_investing.pause'
$doInvesting = $true
if (Test-Path $pauseState) {
  $age = (Get-Date) - (Get-Item $pauseState).LastWriteTime
  if ($age.TotalMinutes -lt 30) { $doInvesting = $false }
}
if ($doInvesting) {
  try {
    $probe = Start-Process -FilePath $Python -ArgumentList '-c','"import playwright"' `
              -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
    if ($probe.ExitCode -ne 0) {
      Note "investing: playwright not installed - skipped (once only)"
      Set-Content -Path $pauseState -Value 'no playwright'
      $doInvesting = $false
    }
  } catch {
    Note "investing: python not available - skipped"
    Set-Content -Path $pauseState -Value 'no python'
    $doInvesting = $false
  }
}
if ($doInvesting) {
  $InvOk = Invoke-Step -File (Join-Path $ScriptDir 'fetch_investing.py') -StepArgs $invArgs `
            -Label "investing fetch"
  if (-not $InvOk) { Set-Content -Path $pauseState -Value 'fetch failed' }
  else {
    if (Test-Path $pauseState) { Remove-Item $pauseState -Force -ErrorAction SilentlyContinue }
  }
}

# fallback: if no previous investing file and this run failed, still merge what we have
# 3. merge cloud + investing -> final events.csv, then atomic swap into place
$invExists = Test-Path $inv
if ($InvOk -or $invExists) {
  $mArgs = @(
    (Join-Path $ScriptDir 'merge_feed.py'),
    "--out", "`"$final`"",
    "--in",  "`"$cloud`""
  )
  if ($invExists) { $mArgs += @("--in", "`"$inv`"") }
  $mArgs += @("--days-back","2","--days-forward","8")
  $merged = $false
  try {
    $p = Start-Process -FilePath $Python -ArgumentList $mArgs `
           -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
    $merged = ($p.ExitCode -eq 0)
  } catch {
    Note "merge not run ($($_.Exception.Message))"
  }
  if ($merged) {
    Move-Item -Path $final -Destination $dest -Force
    Note ("merged feed written -> {0}" -f $dest)
    if (-not $Quiet) { Write-Host "  merged  $dest" -ForegroundColor Green }
    exit 0
  }
  Note "merge failed - keeping the plain cloud copy"
}

# plain cloud copy (previous behavior)
Move-Item -Path $cloud -Destination $dest -Force
Note ("picked up {0} -> {1}" -f $Url, $dest)
if (-not $Quiet) { Write-Host "  wrote   $dest" -ForegroundColor Green }
