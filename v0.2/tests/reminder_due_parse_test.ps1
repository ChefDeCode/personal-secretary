# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 截止原话的三条新规则：屏幕识别把日期横线认成「一」「彐」也能读；消息里提到的过去日期不当截止；只说钟点又比消息还早的，待你确认、不提醒。其它写法照旧。
# 只在后台跑：临时数据文件夹、虚构的事、假时钟；不开窗口、不碰真数据
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib_test_data.ps1'); $script:TestDataRoot = Use-TestDataFolder 'reminder_due_parse_test'
$v2 = Split-Path $PSScriptRoot -Parent; . "$v2\lib_v2.ps1"
$T = Join-Path $env:TEMP 'secretary_rem_due_parse'
function Use-Sandbox { $script:CfgPath = "$T\config.json"; $script:RemDir = $T; $script:V2Data = $T; $script:DoneFile = "$T\done.json"; $script:DataDir = $T; $script:MemDir = $T }
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null; Use-Sandbox
[IO.File]::WriteAllText($script:CfgPath, '{"features":{"proactive":true},"remind":{"brief":"09:00","quietFrom":"23:00","quietTo":"06:00"}}')
$msg = [datetime]'2026-11-07T17:04:00'   # 周六下午
function DueOf([string]$s, [switch]$Plain) { if ($Plain) { Resolve-TaskDue $s $msg } else { Resolve-TaskDue $s $msg -FromMessage } }
# 1) 识别错的横线
$r = DueOf "2026$([char]0x4E00)11$([char]0x4E00)09 09：30（示例备注）"; Check "OCR dash 一 in a full date is read as a date ($($r.at))" ($r.at -eq '2026-11-09T09:30:00' -and $r.has_time)
$r = DueOf "2026$([char]0x5F50)11$([char]0x4E00)10 10:00"; Check "OCR dash 彐 is read too ($($r.at))" ($r.at -eq '2026-11-10T10:00:00')
$r = DueOf "2026$([char]0xFF0D)11$([char]0x2014)12"; Check "full-width / long dashes are read too ($($r.at))" ($r.at -like '2026-11-12T*' -and -not $r.has_time)
$r = Resolve-Due "2026$([char]0x4E00)11$([char]0x4E00)09 09：30" $msg; Check 'Resolve-Due (also used for remembered promises) reads the OCR dash' ($r -and $r.at -eq [datetime]'2026-11-09T09:30:00')
$e = ''; try { $r = DueOf "2026$([char]0x5F50)0$([char]0x4E00)20 09：30"; $r2 = DueOf '13月40日' } catch { $e = $_.Exception.Message }
Check "a misread date (month 0, 13月40日) gives no deadline and no error $e" (-not $e -and -not $r.at -and -not $r2.at)
# 2) 消息里提到的过去日期
$r = DueOf "2026$([char]0x4E00)10$([char]0x4E00)20 09：30（示例备注）"; Check 'a date 18 days before the message is not a deadline (old)' (-not $r.at -and $r.old)
$r = DueOf '11月5日'; Check 'two days before the message: old' (-not $r.at -and $r.old)
$r = DueOf '11月6日'; Check 'one day before the message: still kept as a date' ($r.at -like '2026-11-06T*' -and -not $r.old)
# 3) 只有钟点、比消息时间早
foreach ($s in '9:30', '9点半', '上午9点半') { $r = DueOf $s; Check "time-only '$s' earlier than the message: no date, needs your time" (-not $r.at -and $r.needs_time) }
# 不受影响的写法
$r = DueOf '明天9:30'; Check "明天9:30 -> tomorrow 09:30 ($($r.at))" ($r.at -eq '2026-11-08T09:30:00' -and -not $r.needs_time)
$r = DueOf '今晚8点'; Check "今晚8点 -> today 20:00 ($($r.at))" ($r.at -eq '2026-11-07T20:00:00')
$r = DueOf '晚上8点'; Check "晚上8点 later than the message -> today 20:00 ($($r.at))" ($r.at -eq '2026-11-07T20:00:00')
$r = DueOf '下午6点'; Check "下午6点 later than the message -> today 18:00 ($($r.at))" ($r.at -eq '2026-11-07T18:00:00')
$r = DueOf '今天9点'; Check "今天9点 (says which day) stays today even though it has passed ($($r.at))" ($r.at -eq '2026-11-07T09:00:00')
$r = DueOf '周一下午3点'; Check "周一下午3点 -> Monday 15:00 ($($r.at))" ($r.at -eq '2026-11-09T15:00:00')
$r = DueOf '11月20日'; Check "11月20日 -> that date, no time ($($r.at))" ($r.at -like '2026-11-20T*' -and -not $r.has_time)
$r = DueOf '2026-11-20 10:00'; Check "ISO full date still works ($($r.at))" ($r.at -eq '2026-11-20T10:00:00')
$r = DueOf '等我一下'; Check '"等我一下" still has no deadline' (-not $r.at)
$r = DueOf '9:30' -Plain; Check 'your own answer to "when" (no message rules) is unchanged' ($r.at -eq '2026-11-07T09:30:00')
# 4) 事项和提醒：过去日期的事不算「有截止时间的」、不提醒；钟点比消息早的等你确认、不提醒；正常的照常
function Todo([string]$id, [string]$cat, [string]$due) { [ordered]@{ id = $id; ts = $msg.AddSeconds(20).ToString('s'); 原文时间 = $msg.ToString('s'); 类别 = $cat; 事情 = (Protect "示例事情 $id"); 谁 = (Protect '示例人'); 截止 = (Protect $due); 原文 = (Protect '示例原文'); conv = (Protect "示例聊天 $id"); app = '微信'; 发言 = 'other' } }
$todos = @((Todo 'old' '有截止时间的' "2026$([char]0x4E00)10$([char]0x4E00)20 09：30（示例备注）"), (Todo 'early' '有截止时间的' '9:30'), (Todo 'tomorrow' '有截止时间的' '明天9:30'), (Todo 'oldreply' '需要你回的' '11月1日'))
[IO.File]::WriteAllLines("$T\todos.jsonl", [string[]]@($todos | ForEach-Object { $_ | ConvertTo-Json -Compress }))
$tt = @{}; foreach ($one in Get-TrackedTodos) { $tt[$one.id] = $one }
Check 'old-date item is kept, text kept, but not 有截止时间的 and no deadline' ($tt.old -and $tt.old.category -ne '有截止时间的' -and -not $tt.old.due_at -and $tt.old.due_text -and $tt.old.what -and $tt.old.reason)
Check 'old date on another kind of item: same kind, just no deadline' ($tt.oldreply.category -eq '需要你回的' -and -not $tt.oldreply.due_at)
Check 'time-only-before-message item: no deadline, needs your time' (-not $tt.early.due_at -and $tt.early.needs_time)
Check 'normal item keeps its deadline' ($tt.tomorrow.due_at -eq '2026-11-08T09:30:00' -and -not $tt.tomorrow.needs_time)
$today = @(Get-Today $msg); Check 'today list: the old-date item is not in the due group' (@($today | Where-Object { $_.id -eq 'old' -and $_.group -eq 'due' }).Count -eq 0 -and @($today | Where-Object { $_.id -eq 'old' }).Count -eq 1)
$ids = @(foreach ($now in $msg.AddMinutes(1), $msg.AddHours(16), $msg.AddHours(17)) { Get-ReminderCandidates $now | ForEach-Object { $_.id } })
Check 'no due-today / 2-hours-left for the old-date or time-only items' (-not ($ids -match '\|t:(old|early|oldreply)\|'))
Check 'the normal item still gets its reminders tomorrow' (@($ids | Where-Object { $_ -match '^(day|pre2h)\|t:tomorrow\|' } | Sort-Object -Unique).Count -eq 2)
$q = @(Claim-TaskTimeQuestions $msg.AddMinutes(1)); Check 'the time-only item goes through the existing "when will you do this?" question (and only it)' ($q.Count -eq 1 -and $q[0].id -eq 'early')
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"reminder_due_parse_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
