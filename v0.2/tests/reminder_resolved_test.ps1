# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 提醒卡处理过就不再回来（重启也不回来）：你在等谁 / 到期 / 自己的提醒；好的、稍后、不用再提醒、在今天里点了完成。全在临时文件夹，虚构的事，不碰真数据
# 「重启」= 另开一个 PowerShell 进程，只读临时文件夹里存下来的状态
param([string]$Child = '', [string]$At = '')
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; . "$v2\lib_v2.ps1"
$T = Join-Path $env:TEMP 'secretary_rem_resolved'
function Use-Sandbox { $script:CfgPath = "$T\config.json"; $script:RemDir = $T; $script:V2Data = $T; $script:DoneFile = "$T\done.json"; $script:DataDir = $T; $script:MemDir = $T }
if ($Child) { Use-Sandbox; $now = [datetime]$At
  switch ($Child) { 'active' { (@(Get-ActiveReminders) | ForEach-Object { $_.id }) -join ',' } 'tick' { (@(Invoke-ReminderTick $now) | ForEach-Object { $_.id }) -join ',' } }; return }
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
function Restart([string]$what, [datetime]$when) { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Child $what -At $when.ToString('s') 2>&1; (@($o) | Where-Object { $_ -is [string] }) -join '' }
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null; Use-Sandbox
[IO.File]::WriteAllText($script:CfgPath, '{"features":{"proactive":true},"remind":{"quietFrom":"23:00","quietTo":"06:00"}}')
$day = (Get-Date).Date.AddHours(12); $since = $day.AddDays(-1.5)
# 三件「你在等谁」（和截图里一样的卡），虚构内容
$todos = foreach ($i in 1..3) { [ordered]@{ ts = $since.AddMinutes($i).ToString('s'); 类别 = '你在等谁'; 事情 = (Protect "示例事情$i"); 谁 = (Protect "示例人$i"); 截止 = (Protect ''); conv = (Protect "示例聊天$i"); app = '微信' } }
[IO.File]::WriteAllLines("$T\todos.jsonl", [string[]]@($todos | ForEach-Object { $_ | ConvertTo-Json -Compress }))
$ids = @($todos | ForEach-Object { ($_.ts + '|' + $_.事情).GetHashCode().ToString('x8') })
$fired = @(Invoke-ReminderTick $day); Check "the three waiting cards show once ($($fired.Count))" ($fired.Count -eq 3)
Check 'they are still there after a restart while not handled' (@((Restart 'active' $day) -split ',' | Where-Object { $_ }).Count -eq 3)
Check 'and they do not fire a second time' ((Restart 'tick' $day.AddMinutes(5)) -eq '')
# 1) 在今天里点了「完成」（或自动认出你回过了）→ 卡片收掉，重启也不回来  ← 这次的毛病
Set-Done $ids[0] $true
Check 'item done -> its card is gone right away' (@(Get-ActiveReminders | Where-Object { $_.id -eq "wait|t:$($ids[0])" }).Count -eq 0)
Check 'item done -> still gone after a restart' ((Restart 'active' $day) -notmatch $ids[0])
# 以前留下来的：事情已经完成、卡片还在（就是你现在那三张的样子）→ 一打开就收掉
$s = Get-RemState; $s.active = @(@($s.active) + [pscustomobject]@{ id = "wait|t:$($ids[0])"; item = "t:$($ids[0])"; text = 'x'; ts = $day.ToString('s'); important = $false; parts = @() }); Save-RemState $s
Check 'an old leftover card for a done item is cleaned on start' ((Restart 'active' $day) -notmatch $ids[0])
# 2) 好的
Set-ReminderAction "wait|t:$($ids[1])" 'ok' $day
Check '"OK" -> gone, and not back after a restart or later ticks' ((Restart 'active' $day) -notmatch $ids[1] -and (Restart 'tick' $day.AddHours(2)) -notmatch $ids[1])
# 3) 稍后（1 小时）→ 存的是具体时间：到点前不回来，到点后回来一次
Set-ReminderAction "wait|t:$($ids[2])" 'later1h' $day
Check '"later" -> not back before its time (restart at +30 min)' ((Restart 'tick' $day.AddMinutes(30)) -notmatch $ids[2] -and (Restart 'active' $day.AddMinutes(30)) -notmatch $ids[2])
Check '"later" -> back once after its time (restart at +61 min)' ((Restart 'tick' $day.AddMinutes(61)) -match $ids[2])
Check '"later" -> fired once, not again' ((Restart 'tick' $day.AddMinutes(70)) -notmatch $ids[2])
# 4) 不用再提醒 → 这件事永远不再提
Set-ReminderAction "wait|t:$($ids[2])" 'mute' $day
Check '"do not remind again" -> gone and never back (even days later)' ((Restart 'active' $day.AddDays(2)) -notmatch $ids[2] -and (Restart 'tick' $day.AddDays(2)) -notmatch $ids[2])
# 5) 合起来的那张（「还有 N 件事要留意」）：里面的事都处理了就收掉
$s = Get-RemState; $s.active = @([pscustomobject]@{ id = 'merge|x'; item = 'merge'; text = '还有 2 件事要留意'; ts = $day.ToString('s'); important = $true; parts = @([pscustomobject]@{ id = "wait|t:$($ids[0])"; item = "t:$($ids[0])"; text = 'a' }, [pscustomobject]@{ id = 'custom|k'; item = 'k'; text = 'b' }) }); Save-RemState $s
$m = @(Get-ActiveReminders | Where-Object { $_.id -eq 'merge|x' }); Check 'merged card drops the handled part and keeps the rest' ($m.Count -eq 1 -and @($m[0].parts).Count -eq 1)
# 6) 旧格式的状态文件（缺字段、卡片没有 item）也能读
[IO.File]::WriteAllText("$T\reminders_state.json", '{"fired":{},"active":[{"id":"wait|t:zzz","text":"旧卡","ts":"2026-11-01T10:00:00"}]}')
$e = ''; try { $x = @(Get-ActiveReminders); [void](Invoke-ReminderTick $day) } catch { $e = $_.Exception.Message }; Check "old-format state loads without error $e" (-not $e)
# 7) 写文件是原子的：不留临时文件
Check 'state is written in one piece (no leftover temp file)' (-not (Test-Path "$T\reminders_state.json.tmp") -and -not (Test-Path "$T\done.json.tmp"))
# 8) 小浮窗和主窗口用的是同一个地方
$sec = [IO.File]::ReadAllText("$v2\秘书.ps1"); Check 'panel and main window read the same reminder store' ($sec -match 'function Get-ReminderView \{[^\r\n]*Get-ActiveReminders' -and $sec -match "'remAct'\s*\{\s*Set-ReminderAction")
"reminder_resolved_test: $pass pass, $fail fail"