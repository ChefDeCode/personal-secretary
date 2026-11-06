# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 重启只作用于这个项目。用户已退出时不打开，发送期间不停止任何进程。
param([switch]$StartOnly)
$ErrorActionPreference = 'Stop'
function Test-SecretaryScriptProcess($Process, [string]$ScriptPath) {
  if ([string]$Process.Name -notin 'powershell.exe','pwsh.exe') { return $false }
  $pattern = '(?i)(?:^|\s)-File\s+(?:"' + [regex]::Escape($ScriptPath) + '"|' + [regex]::Escape($ScriptPath) + ')(?:\s|$)'
  [bool]([string]$Process.CommandLine -match $pattern)
}
function Get-SecretaryRestartPlan($Processes, $RunState, [string]$ProjectV2, [bool]$Busy, [bool]$StartOnly, [int]$CallerPid = 0) {
  $root = Split-Path $ProjectV2 -Parent
  $mainScript = Join-Path $ProjectV2 '秘书.ps1'; $sendScript = Join-Path $ProjectV2 '发送.ps1'
  $exe = Join-Path $ProjectV2 '秘书.exe'
  $main = @($Processes | Where-Object { (Test-SecretaryScriptProcess $_ $mainScript) -or ([string]$_.ExecutablePath -eq $exe) })
  $senders = @($Processes | Where-Object { Test-SecretaryScriptProcess $_ $sendScript })
  if (-not $RunState) { return @{ allowed = $false; reason = 'state_missing'; pids = @() } }
  if ($Busy -or $senders.Count) { return @{ allowed = $false; reason = 'sending'; pids = @() } }
  if ($RunState -and [bool]$RunState.clean) { return @{ allowed = $false; reason = 'user_closed'; pids = @() } }
  # StartOnly is permitted for a recorded crash only; it cannot override clean user exit.
  if (-not $main.Count -and -not ($StartOnly -and $RunState -and $RunState.clean -eq $false -and [int]$RunState.pid -gt 0)) {
    return @{ allowed = $false; reason = 'not_running'; pids = @() }
  }
  $scripts = @((Join-Path $root '12_值守.ps1'),(Join-Path $ProjectV2 '边缘线.ps1'),(Join-Path $root '07_AI边框特效.ps1'),$mainScript)
  $ids = @(foreach ($proc in $Processes) {
    if ([int]$proc.ProcessId -eq $CallerPid) { continue }
    $owned = [string]$proc.ExecutablePath -eq $exe
    foreach ($path in $scripts) { if (Test-SecretaryScriptProcess $proc $path) { $owned = $true; break } }
    if ($owned) { [int]$proc.ProcessId }
  })
  @{ allowed = $true; reason = 'restart'; pids = $ids; main = @($main | ForEach-Object { [int]$_.ProcessId }) }
}
$v2 = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $v2 '秘书.exe'
if (-not (Test-Path -LiteralPath $exe)) { Write-Output 'restart=missing_exe'; exit 1 }
. (Join-Path $v2 'lib_动作.ps1')
$lease = Enter-SendLease
if (-not $lease) { Write-Output 'restart=sending'; exit 2 }
try {
  $stateFile = Join-Path $v2 'data\run_state.json'
  $state = $null; if (Test-Path -LiteralPath $stateFile) { try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch { Write-Output 'restart=state_unreadable'; exit 3 } }
  $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
  $plan = Get-SecretaryRestartPlan $processes $state $v2 (Test-Path -LiteralPath (Join-Path $v2 'data\send_busy.flag')) ([bool]$StartOnly) $PID
  if (-not $plan.allowed) { Write-Output ('restart=' + $plan.reason); exit 3 }
  # Recheck clean exit immediately before stopping; a user quit wins over this request.
  if (Test-Path -LiteralPath $stateFile) { $current = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json; if ($current.clean) { Write-Output 'restart=user_closed'; exit 3 } }
  foreach ($procId in $plan.pids) {
    # Revalidate command line before terminating, so a reused PID cannot target another program.
    $currentProcesses = @(Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue)
    $fresh = Get-SecretaryRestartPlan $currentProcesses $state $v2 $false $true $PID
    if ($fresh.pids -contains $procId) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
  }
  if ($plan.pids.Count) { Start-Sleep -Milliseconds 500 }
  if (Test-Path -LiteralPath $stateFile) { $current = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json; if ($current.clean) { Write-Output 'restart=user_closed'; exit 3 } }
  Start-Process explorer.exe -WindowStyle Hidden -ArgumentList ('"' + $exe + '"')
  Write-Output 'restart=launched'
} finally { Exit-SendLease $lease }