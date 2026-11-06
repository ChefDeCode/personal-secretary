# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_改动记录.ps1 — 秘书在自己文件夹以外动过的一切，都只能经过这里，并记进 data\changes.jsonl（卸载时按倒序原样还原）
# 能记的种类：startup_link（「启动」文件夹里的快捷方式）、hkcu_value（当前用户注册表的一个值）、user_env（当前用户环境变量）、
#            folder（在程序文件夹以外建的文件夹，比如临时工作文件夹）、scheduled_task（计划任务）、credential（Windows 凭据）
# 每一行：时间、种类、目标、改之前（不存在就是 absent）、改之后。写入是「先写临时文件再换过去」，坏行在读的时候跳过并报告
# 不依赖秘书别的代码：秘书坏了、打不开的时候，卸载程序也能用它
function Get-ChangeJournalPath { if ($script:ChangeJournal) { $script:ChangeJournal } elseif ($script:V2Data) { Join-Path $script:V2Data 'changes.jsonl' } else { Join-Path $PSScriptRoot 'data\changes.jsonl' } }
function Add-ChangeRecord([string]$Kind, [string]$Target, $Before, $After, [hashtable]$Extra = @{}) {
  $p = Get-ChangeJournalPath; [void][IO.Directory]::CreateDirectory((Split-Path $p))
  $rec = [ordered]@{ ts = (Get-Date).ToString('s'); kind = $Kind; target = $Target; before = $Before; after = $After }; foreach ($k in $Extra.Keys) { $rec[$k] = $Extra[$k] }
  $m = [Threading.Mutex]::new($false, 'Local\SecretaryChangeJournal'); $held = $false
  try { try { $held = $m.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $held = $true }
    $old = if ([IO.File]::Exists($p)) { [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) } else { '' }
    if ($old -and -not $old.EndsWith("`n")) { $old += "`n" }
    $tmp = "$p.tmp"; [IO.File]::WriteAllText($tmp, $old + ($rec | ConvertTo-Json -Compress -Depth 4) + "`n", (New-Object Text.UTF8Encoding $false))
    if ([IO.File]::Exists($p)) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { [IO.File]::Move($tmp, $p) }
  } finally { if ($held) { $m.ReleaseMutex() }; $m.Dispose() }
}
# 读记录：坏行跳过，返回 @{ items; bad }
function Read-ChangeJournal([string]$Path = (Get-ChangeJournalPath)) {
  $items = New-Object System.Collections.ArrayList; $bad = 0
  if ([IO.File]::Exists($Path)) { foreach ($l in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) { if (-not $l.Trim()) { continue }; try { $o = $l | ConvertFrom-Json -ErrorAction Stop; if ($o.kind -and $o.target) { [void]$items.Add($o) } else { $bad++ } } catch { $bad++ } } }
  @{ items = @($items); bad = $bad; exists = [IO.File]::Exists($Path) }
}
function Test-ChangeRecorded([string]$Kind, [string]$Target) { @((Read-ChangeJournal).items | Where-Object { $_.kind -eq $Kind -and $_.target -eq $Target }).Count -gt 0 }

# —— 能做的改动（每个都先记、再改）——
# 「启动」文件夹里的快捷方式：$On = $true 建 / 覆盖，$false 删
function Set-JournaledStartupLink([string]$LinkPath, [bool]$On, [string]$TargetExe = '', [string]$Arguments = '', [string]$WorkDir = '', [string]$Icon = '', [string]$Description = '') {
  $before = if (Test-Path -LiteralPath $LinkPath) { 'present' } else { 'absent' }
  if ($On) {
    Add-ChangeRecord 'startup_link' $LinkPath $before 'present'
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($LinkPath); $s.TargetPath = $TargetExe; $s.Arguments = $Arguments; $s.WorkingDirectory = $WorkDir; $s.WindowStyle = 7
    if ($Icon -and (Test-Path $Icon)) { $s.IconLocation = $Icon }; if ($Description) { $s.Description = $Description }; $s.Save()
  } elseif ($before -eq 'present') { Add-ChangeRecord 'startup_link' $LinkPath 'present' 'absent'; Remove-Item -LiteralPath $LinkPath -Force }
}
# 当前用户注册表的一个值（HKCU 下）；$Value = $null 表示删掉这个值
function Set-JournaledHkcuValue([string]$Key, [string]$Name, $Value) {
  if ($Key -notlike 'HKCU:\*') { throw 'only HKCU' }
  $keyExisted = Test-Path $Key; $before = 'absent'; if ($keyExisted) { $v = (Get-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue).$Name; if ($null -ne $v) { $before = [string]$v } }
  Add-ChangeRecord 'hkcu_value' "$Key|$Name" $before $(if ($null -eq $Value) { 'absent' } else { [string]$Value }) @{ key_existed = $keyExisted }
  if ($null -eq $Value) { if ($keyExisted) { Remove-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue } }
  else { if (-not $keyExisted) { New-Item -Path $Key -Force | Out-Null }; Set-ItemProperty -Path $Key -Name $Name -Value $Value }
}
# 当前用户环境变量；$Value = $null 表示删掉
function Set-JournaledUserEnv([string]$Name, $Value) {
  $cur = [Environment]::GetEnvironmentVariable($Name, 'User'); $before = if ($null -eq $cur) { 'absent' } else { $cur }
  Add-ChangeRecord 'user_env' $Name $before $(if ($null -eq $Value) { 'absent' } else { [string]$Value })
  [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
}
# 在程序文件夹以外建一个文件夹（比如临时工作文件夹）；已经有了就只记一笔（卸载时不删别人原来就有的）
function New-JournaledFolder([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path); $before = if (Test-Path -LiteralPath $full) { 'present' } else { 'absent' }
  if (-not (Test-ChangeRecorded 'folder' $full)) { Add-ChangeRecord 'folder' $full $before 'present' }
  [void][IO.Directory]::CreateDirectory($full); $full
}

# —— 补记（老版本已经做过、但当时没记的改动）：只补确实是秘书的东西 ——
function Sync-ChangeJournalBackfill([string]$AppRoot) {
  $added = 0
  $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) '个人秘书.lnk'
  if ((Test-Path -LiteralPath $lnk) -and -not (Test-ChangeRecorded 'startup_link' $lnk)) { Add-ChangeRecord 'startup_link' $lnk 'absent' 'present' @{ backfill = $true }; $added++ }
  foreach ($d in @(Get-ChildItem $env:TEMP -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(secretary_|sec_datacheck_|snap_\d)' })) {
    if (-not (Test-ChangeRecorded 'folder' $d.FullName)) { Add-ChangeRecord 'folder' $d.FullName 'absent' 'present' @{ backfill = $true }; $added++ } }
  $added
}

# —— 还原：倒序把每一条改回去；只动记录里有的东西。返回每一条的结果 ——
function Undo-ExternalChanges([string]$Path = (Get-ChangeJournalPath)) {
  $j = Read-ChangeJournal $Path; $out = New-Object System.Collections.ArrayList
  # 同一个目标只按「最早那一次之前」的样子还原
  $first = [ordered]@{}; foreach ($c in $j.items) { $k = "$($c.kind)|$($c.target)"; if (-not $first.Contains($k)) { $first[$k] = $c } }
  $keys = @($first.Keys); [array]::Reverse($keys)
  foreach ($k in $keys) { $c = $first[$k]; $res = 'ok'
    try {
      switch ($c.kind) {
        'startup_link' { if ($c.before -eq 'absent' -and (Test-Path -LiteralPath $c.target)) { Remove-Item -LiteralPath $c.target -Force } }
        'hkcu_value' { $key, $name = ([string]$c.target).Split('|', 2)
          if ($c.before -eq 'absent') { if (Test-Path $key) { Remove-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue; if (-not $c.key_existed -and -not @((Get-Item $key).Property).Count -and -not @(Get-ChildItem $key).Count) { Remove-Item $key -Force } } }
          else { if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }; Set-ItemProperty -Path $key -Name $name -Value $c.before } }
        'user_env' { [Environment]::SetEnvironmentVariable([string]$c.target, $(if ($c.before -eq 'absent') { $null } else { [string]$c.before }), 'User') }
        'folder' { if ($c.before -eq 'absent' -and (Test-Path -LiteralPath $c.target)) { Remove-Item -LiteralPath $c.target -Recurse -Force } }
        'scheduled_task' { if ($c.before -eq 'absent') { Unregister-ScheduledTask -TaskName ([string]$c.target) -Confirm:$false -ErrorAction SilentlyContinue } }
        'credential' { if ($c.before -eq 'absent') { & cmdkey "/delete:$($c.target)" | Out-Null } }
        default { $res = 'unknown kind' }
      } } catch { $res = 'failed: ' + $_.Exception.Message }
    [void]$out.Add([pscustomobject]@{ kind = $c.kind; target = $c.target; result = $res }) }
  @{ results = @($out); bad = $j.bad; exists = $j.exists }
}
# 还原以后检查：记录里的东西都回到改之前的样子了吗
function Test-ExternalLeftovers([string]$Path = (Get-ChangeJournalPath)) {
  $left = New-Object System.Collections.ArrayList
  foreach ($c in (Read-ChangeJournal $Path).items) {
    $still = switch ($c.kind) {
      'startup_link' { $c.before -eq 'absent' -and (Test-Path -LiteralPath $c.target) }
      'folder' { $c.before -eq 'absent' -and (Test-Path -LiteralPath $c.target) }
      'user_env' { $cur = [Environment]::GetEnvironmentVariable([string]$c.target, 'User'); if ($c.before -eq 'absent') { $null -ne $cur } else { $cur -ne [string]$c.before } }
      'hkcu_value' { $key, $name = ([string]$c.target).Split('|', 2); $cur = if (Test-Path $key) { (Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue).$name } else { $null }; if ($c.before -eq 'absent') { $null -ne $cur } else { [string]$cur -ne [string]$c.before } }
      default { $false } }
    if ($still) { [void]$left.Add("$($c.kind): $($c.target)") } }
  @($left | Sort-Object -Unique)
}
