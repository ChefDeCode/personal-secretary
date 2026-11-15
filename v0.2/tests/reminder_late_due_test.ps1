# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 「今天到期」不再追着刚整理出来的事、或者时间已经过了的事弹；「还有 2 小时」不为 2 小时内才整理出来的事弹。其它照常提醒。
# 只在后台跑：临时数据文件夹、虚构的事、假时钟；不开窗口、不碰真数据
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib_test_data.ps1'); $script:TestDataRoot = Use-TestDataFolder 'reminder_late_due_test'
$v2 = Split-Path $PSScriptRoot -Parent; . "$v2\lib_v2.ps1"
$T = Join-Path $env:TEMP 'secretary_rem_late_due'
function Use-Sandbox { $script:CfgPath = "$T\config.json"; $script:RemDir = $T; $script:V2Data = $T; $script:DoneFile = "$T\done.json"; $script:DataDir = $T; $script:MemDir = $T }
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null; Use-Sandbox
[IO.File]::WriteAllText($script:CfgPath, '{"features":{"proactive":true},"remind":{"brief":"09:00","quietFrom":"23:00","quietTo":"06:00"}}')
$d = (Get-Date).Date
function Todo([string]$id, [datetime]$at, [string]$cat, [string]$due) { [ordered]@{ id = $id; ts = $at.ToString('s'); 原文时间 = $at.ToString('s'); 类别 = $cat; 事情 = (Protect "示例事情 $id"); 谁 = (Protect '示例人'); 截止 = (Protect $due); conv = (Protect "示例聊天 $id"); app = '微信'; 发言 = 'other' } }
$todos = @(
  (Todo 'late930' $d.AddHours(17) '有截止时间的' '9点半')            # 17:00 才整理出来、9:30 早就过了（这次的三张卡就是这样）
  (Todo 'late15' $d.AddHours(10) '有截止时间的' '今天下午3点')        # 当天简报之后才整理出来：不弹「今天到期」，13:00 的「还有 2 小时」照常
  (Todo 'inside2h' $d.AddHours(14) '有截止时间的' '今天下午3点')      # 14:00 整理出来、15:00 到期：已经在 2 小时以内，不弹「还有 2 小时」
  (Todo 'early17' $d.AddDays(-1).AddHours(12) '有截止时间的' '明天下午5点')   # 前一天就知道：今天 9:00「今天到期」、15:00「还有 2 小时」照常
  (Todo 'earlyday' $d.AddDays(-1).AddHours(12) '你答应别人的' '明天') # 前一天就知道、只有日期：今天 9:00 照常
  (Todo 'lateday' $d.AddHours(11) '有截止时间的' '今天')              # 当天简报之后、只有日期：不弹「今天到期」
  (Todo 'reply1' $d.AddDays(-1).AddHours(20) '需要你回的' '')          # 「要你回」不受影响
)
[IO.File]::WriteAllLines("$T\todos.jsonl", [string[]]@($todos | ForEach-Object { $_ | ConvertTo-Json -Compress }))
function Ids([datetime]$now) { @(Get-ReminderCandidates $now | ForEach-Object { $_.id }) }
$all = Ids $d.AddHours(18)
Check 'late item whose time already passed: no "due today"' (-not ($all -match '^day\|t:late930\|'))
Check 'item first seen on its due day after the brief: no "due today"' (-not ($all -match '^day\|t:late15\|') -and -not ($all -match '^day\|t:lateday\|'))
Check 'item first seen inside the last 2 hours: no "2 hours left"' (-not (Ids $d.AddHours(14).AddMinutes(1) | Where-Object { $_ -match '^pre2h\|t:inside2h\|' }))
Check 'item first seen after the brief but more than 2 hours ahead: "2 hours left" still there' (@(Ids $d.AddHours(10).AddMinutes(1) | Where-Object { $_ -match '^pre2h\|t:late15\|' }).Count -eq 1)
Check 'item known the day before: "due today" still there in the morning' (@(Ids $d.AddHours(9) | Where-Object { $_ -match '^day\|t:(early17|earlyday)\|' }).Count -eq 2)
Check 'item known the day before with a time: "2 hours left" still there' (@(Ids $d.AddHours(9) | Where-Object { $_ -match '^pre2h\|t:early17\|' }).Count -eq 1)
Check 'item known the day before with a time: "due today" gone once that time has passed' (-not (Ids $d.AddHours(17).AddMinutes(1) | Where-Object { $_ -match '^day\|t:early17\|' }))
Check 'reply reminder untouched' (@(Ids $d.AddHours(9) | Where-Object { $_ -eq 'reply|t:reply1' }).Count -eq 1)
# 端到端：假时钟走一天，看实际弹出来的
$fired = New-Object System.Collections.Generic.List[string]
foreach ($h in 8.5, 9, 10.25, 11.25, 13.25, 14.25, 15.25, 17.25, 18) { foreach ($c in @(Invoke-ReminderTick $d.AddHours($h))) { $fired.Add([string]$c.id); foreach ($p in @($c.parts)) { if ($p) { $fired.Add([string]$p.id) } } } }
Check "over the day the late items never fire a 'due today' ($(@($fired | Where-Object { $_ -match '^day\|t:(late930|late15|lateday)\|' }).Count))" (-not ($fired -match '^day\|t:(late930|late15|lateday)\|'))
Check 'over the day the inside-2h item never fires "2 hours left"' (-not ($fired -match '^pre2h\|t:inside2h\|'))
Check "over the day the untouched reminders all fire once ($(@($fired | Where-Object { $_ -match '^(day\|t:early17|day\|t:earlyday|pre2h\|t:early17|pre2h\|t:late15|reply\|t:reply1)' }).Count)/5)" (@($fired | Where-Object { $_ -match '^(day\|t:early17|day\|t:earlyday|pre2h\|t:early17|pre2h\|t:late15|reply\|t:reply1)' } | Select-Object -Unique).Count -eq 5 -and @($fired | Where-Object { $_ -match '^(day|pre2h|reply)\|' }).Count -eq 5)
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"reminder_late_due_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
