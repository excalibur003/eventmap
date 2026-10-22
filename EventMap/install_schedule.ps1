#+------------------------------------------------------------------+
#|  install_schedule.ps1  —  refresh the EventMap feed automatically |
#|                                                                  |
#|  Registers (or removes) a Windows scheduled task that runs       |
#|  fetch_events.ps1 every N minutes. No admin rights needed for a  |
#|  per-user task.                                                  |
#|                                                                  |
#|  USAGE                                                           |
#|    powershell -ExecutionPolicy Bypass -File install_schedule.ps1 |
#|    powershell ... -IntervalMinutes 15                            |
#|    powershell ... -Remove                                        |
#+------------------------------------------------------------------+
[CmdletBinding()]
param(
  [int]    $IntervalMinutes = 30,
  [string] $TaskName        = 'EventMap feed',
  [string] $Provider        = 'ff,tv',

  # Persist the proxy as user environment variables so it is NOT
  # written into the scheduled task command line (which is readable
  # by other users and shows up in the task list).
  [string] $Proxy           = '',
  [string] $ProxyUser       = '',
  [switch] $ClearProxy,

  [switch] $Remove
)

$ErrorActionPreference = 'Stop'
$script  = Join-Path $PSScriptRoot 'fetch_events.ps1'
$log     = Join-Path $PSScriptRoot 'fetch.log'

if ($Remove) {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Yellow
  } else {
    Write-Host "No scheduled task named '$TaskName'." -ForegroundColor Yellow
  }
  return
}

if (-not (Test-Path $script)) { throw "fetch_events.ps1 not found next to this script." }

#--- proxy persistence (user scope) --------------------------------
if ($ClearProxy) {
  [Environment]::SetEnvironmentVariable('EVENTMAP_PROXY','','User')
  [Environment]::SetEnvironmentVariable('EVENTMAP_PROXY_USER','','User')
  Write-Host 'Cleared EVENTMAP_PROXY / EVENTMAP_PROXY_USER (user scope).' -ForegroundColor Yellow
}
if ($Proxy -ne '') {
  [Environment]::SetEnvironmentVariable('EVENTMAP_PROXY',$Proxy,'User')
  Write-Host "Saved EVENTMAP_PROXY = $Proxy (user scope)." -ForegroundColor Green
}
if ($ProxyUser -ne '') {
  [Environment]::SetEnvironmentVariable('EVENTMAP_PROXY_USER',$ProxyUser,'User')
  Write-Host 'Saved EVENTMAP_PROXY_USER (user scope, value hidden).' -ForegroundColor Green
}

$savedProxy = [Environment]::GetEnvironmentVariable('EVENTMAP_PROXY','User')

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Provider $Provider -Quiet *>> `"$log`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
  -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Refreshes the EventMap economic calendar feed into MT5.' | Out-Null

Write-Host ""
Write-Host "Scheduled task registered." -ForegroundColor Green
Write-Host "  name      $TaskName"
Write-Host "  every     $IntervalMinutes min"
Write-Host "  script    $script"
Write-Host "  log       $log"
if ($savedProxy) { Write-Host "  proxy     $savedProxy" } else { Write-Host "  proxy     direct" }
Write-Host ""
Write-Host "Run it once now, or wait a minute:" -ForegroundColor DarkGray
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Remove it with: -Remove" -ForegroundColor DarkGray
