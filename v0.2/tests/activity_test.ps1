# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 「在办的事」：虚构卡片（不是真聊天）算出状态对不对
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"
$now = Get-Date; $o = { param($m) $now.AddMinutes(-$m).ToString('o') }
$script:Fake = @(
  @{ id = 'a1'; ts = (& $o 5); card = @{ kind = 'event'; status = 'open'; title = '提醒对方'; action = '11 点提醒对方交周报'; conv = '测试A'; opts = @('好，到点提醒', '不用') } }
  @{ id = 'a2'; ts = (& $o 10); card = @{ kind = 'send'; status = 'scheduled'; who = '测试A'; text = '记得交周报'; at = $now.AddHours(1).ToString('o'); atText = '今天 23:00' } }
  @{ id = 'a3'; ts = (& $o 20); card = @{ kind = 'event'; status = 'scheduled'; etype = '你在等回复'; action = '等报价'; conv = '测试B'; atText = '周四 09:00' } }
  @{ id = 'a4'; ts = (& $o 30); card = @{ kind = 'question'; status = 'open'; title = '「那个事」是指什么时间？' } }
  @{ id = 'a5'; ts = (& $o 40); card = @{ kind = 'send'; status = 'closed'; at = 'x'; who = '测试A'; text = 'hi'; result = @(@{ ok = $true; text = '发出去了' }) } }
  @{ id = 'a6'; ts = (& $o 50); card = @{ kind = 'send'; status = 'closed'; at = 'x'; who = '测试A'; text = 'hi'; cancelled = $true } }
  @{ id = 'a7'; ts = $now.AddDays(-9).ToString('o'); card = @{ kind = 'send'; status = 'closed'; at = 'x'; who = '测试A'; text = 'old'; result = @(@{ ok = $true; text = '发出去了' }) } }
  @{ id = 'a8'; ts = (& $o 1); card = @{ kind = 'send'; status = 'open'; who = '测试A'; text = '普通草稿' } }
)
function Get-ChatItems { $script:Fake | ForEach-Object { [pscustomobject]$_ } }
. "$v2\lib_事件.ps1"
$r = @(Get-Activity $now); $pass = 0; $fail = 0
function Check($name, $ok) { if ($ok) { $script:pass++ } else { $script:fail++; "FAIL $name" } }
$s = @{}; foreach ($x in $r) { $s[$x.item] = $x.state }
Check 'event open'   ($s.a1 -eq '待你确认')
Check 'sched send'   ($s.a2 -eq '已安排')
Check 'waiting'      ($s.a3 -eq '等对方')
Check 'question'     ($s.a4 -eq '待你回答')
Check 'done'         ($s.a5 -eq '已完成')
Check 'cancelled'    ($s.a6 -eq '已取消')
Check 'old dropped'  (-not $s.ContainsKey('a7'))
Check 'plain draft not listed' (-not $s.ContainsKey('a8'))
Check 'active first' ((@($r | Select-Object -First 4 | Where-Object { $_.active }).Count) -eq 4)
Check 'cancel only scheduled' ((@($r | Where-Object { $_.canCancel } | ForEach-Object { $_.item }) -join ',') -eq 'a2,a3')
Check 'json ok' ([bool]($r | ConvertTo-Json -Depth 3))
$r | ForEach-Object { "$($_.item) $($_.state) cc=$($_.canCancel)" }; "activity_test: $pass pass, $fail fail"



