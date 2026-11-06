# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 更新器.ps1 — 由秘书在下载、校验完更新包之后启动；秘书退出后：备份 → 覆盖 → 启动新版本 → 健康检查 → 起不来就恢复旧版本
# 只动更新包里列出的文件（以及备份它们）；data\（用户数据）永远不碰。每一步记到 <目标>\data\update_log.jsonl（只有版本、步骤、结果）。
param([Parameter(Mandatory)] [string]$Stage, [Parameter(Mandatory)] [string]$Target, [int]$WaitPid = 0, [string]$Version = '', [string]$OldVersion = '',
  [string]$StartExe = '', [string[]]$StartArgs = @('-Tray'), [int]$HealthSeconds = 60)
$ErrorActionPreference = 'Stop'
$log = Join-Path $Target 'data\update_log.jsonl'; New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
function Log([string]$step, [string]$result) { [IO.File]::AppendAllText($log, (@{ ts = (Get-Date).ToString('s'); from = $OldVersion; to = $Version; step = $step; result = $result } | ConvertTo-Json -Compress) + "`r`n") }
function Start-App { if ($StartExe) { (Start-Process $StartExe -ArgumentList $StartArgs -PassThru).Id } }
# 新版本健康：60 秒内写出了自己的运行标记（比更新开始晚），而且 15 秒后进程还活着
function Test-Healthy([datetime]$since) {
  $sf = Join-Path $Target 'data\run_state.json'; $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $HealthSeconds) {
    Start-Sleep -Milliseconds 500
    try { $rs = Get-Content $sf -Raw -ErrorAction Stop | ConvertFrom-Json; if (-not $rs.clean -and [datetime]$rs.started -ge $since.AddSeconds(-1)) {
        Start-Sleep -Seconds 15; return [bool](Get-Process -Id ([int]$rs.pid) -ErrorAction SilentlyContinue) } } catch {}
  }
  $false
}
try {
  if ($WaitPid) { try { Wait-Process -Id $WaitPid -Timeout 60 -ErrorAction Stop } catch {}; if (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) { Log 'wait' 'old version did not exit'; exit 1 } }
  $files = @(Get-ChildItem $Stage -Recurse -File | ForEach-Object { $_.FullName.Substring($Stage.TrimEnd('\').Length + 1) })
  if (@($files | Where-Object { $_ -match '^(data)(\\|$)' -or $_ -match '\.\.' }).Count) { Log 'check' 'refused: package touches data'; exit 1 }
  # 1) 备份：要被覆盖的文件 + 记下哪些是新增的
  $bk = Join-Path (Split-Path $Target -Parent) "update_backup\$OldVersion"; if (Test-Path $bk) { Remove-Item $bk -Recurse -Force }; New-Item -ItemType Directory -Force $bk | Out-Null
  $added = New-Object System.Collections.Generic.List[string]
  foreach ($f in $files) { $src = Join-Path $Target $f; if (Test-Path $src) { $dst = Join-Path $bk $f; New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null; Copy-Item $src $dst -Force } else { $added.Add($f) } }
  [IO.File]::WriteAllText((Join-Path $bk 'added.json'), (ConvertTo-Json @($added)))
  Log 'backup' "ok ($($files.Count - $added.Count) replaced, $($added.Count) new)"
  # 2) 覆盖
  foreach ($f in $files) { $dst = Join-Path $Target $f; New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null; Copy-Item (Join-Path $Stage $f) $dst -Force }
  Log 'install' 'ok'
  # 3) 启动新版本，看它能不能正常起来
  $t0 = Get-Date; [void](Start-App)
  if (Test-Healthy $t0) { Log 'health' 'ok'; Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue; exit 0 }
  # 4) 起不来：结束新版本，从备份恢复，启动旧版本
  Log 'health' 'failed → rolling back'
  try { $rs = Get-Content (Join-Path $Target 'data\run_state.json') -Raw | ConvertFrom-Json; if ([datetime]$rs.started -ge $t0.AddSeconds(-1)) { Stop-Process -Id ([int]$rs.pid) -Force -ErrorAction SilentlyContinue } } catch {}
  foreach ($f in $files) { $b = Join-Path $bk $f; if (Test-Path $b) { Copy-Item $b (Join-Path $Target $f) -Force } }
  foreach ($f in $added) { Remove-Item (Join-Path $Target $f) -Force -ErrorAction SilentlyContinue }
  $t1 = Get-Date; [void](Start-App); Log 'rollback' $(if (Test-Healthy $t1) { 'ok, old version running' } else { 'restored files; old version did not report healthy' })
  exit 2
} catch { Log 'error' $_.Exception.GetType().Name; exit 1 }
