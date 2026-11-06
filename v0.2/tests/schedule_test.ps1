# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 定时发送的逻辑测试（不发送、不碰微信：Start-Send 换成只记录；时间用写进去的假时间）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"
$T = Join-Path $env:TEMP 'secretary_sched_test'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\actions" | Out-Null
$script:ChatFile = "$T\chat.jsonl"; $script:ChatArchive = "$T\chat_archive.jsonl"; $script:ActDir = "$T\actions"; $script:V2Data = $T
$ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Step-Scheduled', 'Close-StuckScheduled', 'Apply-SendResultToCard' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$script:Sending = @{}; $script:Started = New-Object System.Collections.ArrayList; function Start-Send([string]$id, $it) { [void]$script:Started.Add($id); $script:Sending[$id]=$it }; function Post($o) { }
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$now = Get-Date
# 时间解析
$a1 = Resolve-SchedTime '23:00' ([datetime]'2026-11-01 20:55'); Assert ($a1 -eq [datetime]'2026-11-01 23:00') "「23:00」 at 20:55 → today 23:00"
$a2 = Resolve-SchedTime '11:00' ([datetime]'2026-11-01 20:55'); Assert ($a2 -eq [datetime]'2026-11-02 11:00') "「11:00」 at 20:55 (already past) → tomorrow 11:00"
$a3 = Resolve-SchedTime '2026-11-02 09:30' ([datetime]'2026-11-01 20:55'); Assert ($a3 -eq [datetime]'2026-11-02 09:30') 'full date-time kept'
Assert ($null -eq (Resolve-SchedTime '十一点')) 'unreadable time → refused (tool asks again)'
# 三张卡：到点（10 分钟前到）、过点太久（45 分钟前）、还没到（明天）、已取消
function NewCard($minsFromNow) { $a = New-SendAction '文件传输助手' "【秘书测试】定时$minsFromNow" ''; $a.status = 'scheduled'; Save-Action $a; $it = Add-ChatItem @{ role = 'ai'; card = @{ kind = 'send'; actionId = $a.id; who = '文件传输助手'; text = $a.text; at = $now.AddMinutes($minsFromNow).ToString('s'); status = 'scheduled'; result = @() } }; Add-Scheduled $a.id $now.AddMinutes($minsFromNow) $it.id; @{ a = $a; it = $it } }
$due = NewCard -10; $late = NewCard -45; $future = NewCard 600; $canc = NewCard -5; $ac = Get-Action $canc.a.id; $ac.status = 'cancelled'; Save-Action $ac
$script:SchedLast = [datetime]::MinValue; Step-Scheduled
$jobs = @(Get-Scheduled)
Assert ($script:Started -contains $due.a.id -and ($jobs | Where-Object actionId -eq $due.a.id).status -eq 'started') 'due 10 min ago → sent through the normal path (Start-Send), job marked started'
Assert (-not ($script:Started -contains $late.a.id) -and ($jobs | Where-Object actionId -eq $late.a.id).status -eq 'asked' -and @(Get-ChatItems | Where-Object { $_.card -and $_.card.kind -eq 'askfg' -and $_.card.actionId -eq $late.a.id }).Count -eq 1) 'due 45 min ago → NOT sent on its own; asks 「…的提醒还没发，现在还要发吗？」'
Assert (-not ($script:Started -contains $future.a.id) -and ($jobs | Where-Object actionId -eq $future.a.id).status -eq 'scheduled') 'not due yet → untouched'
Assert (-not ($script:Started -contains $canc.a.id) -and ($jobs | Where-Object actionId -eq $canc.a.id).status -eq 'cancelled') 'cancelled → never sent'
$script:SchedLast = [datetime]::MinValue; $n0 = $script:Started.Count; Step-Scheduled; Assert ($script:Started.Count -eq $n0) 'running the check again sends nothing twice'
# 存起来的任务在「重启」后还在（重新读文件）
Assert (@(Get-Scheduled).Count -eq 4) 'jobs persist on disk (survive restart)'
# AI 工具：schedule_send 只弹卡，不定、不发
$script:PendingCards = New-Object System.Collections.ArrayList
$msg = Invoke-AgentTool 'schedule_send' ([pscustomobject]@{ as_said = '文件传输助手'; text = '【秘书测试】到点提醒'; at = (Get-Date).AddHours(1).ToString('yyyy-MM-dd HH:mm'); tz = '' })
Assert (@($script:PendingCards).Count -eq 1 -and $script:PendingCards[0].at -and $msg -match '定时确认卡') "tool schedule_send → one confirm card with a time, nothing scheduled yet ($(@($script:PendingCards).Count) card)"
# 时区规则（假定「现在」= 2026-11-01 20:55 本机）
$n0 = [datetime]'2026-11-01 20:55'
$z1 = Resolve-SchedAt '23:00' '' $n0; Assert ($z1.local -eq [datetime]'2026-11-01 23:00' -and -not $z1.zoneLabel) "no zone said → local time: $(Format-SchedAt $z1 $n0)"
$z2 = Resolve-SchedAt '11:00' '北京时间' $n0; Assert ($z2.local -eq [datetime]'2026-11-01 22:00' -and $z2.zoneLabel -eq '北京时间') "北京时间 11:00 → local 22:00 today: $(Format-SchedAt $z2 $n0)"
$z3 = Resolve-SchedAt '19:00' '美西' $n0; Assert ($z3.local -eq [datetime]'2026-11-01 22:00') "美西 19:00 → local 22:00: $(Format-SchedAt $z3 $n0)"
$z4 = Resolve-SchedAt '20:00' '' $n0; Assert ($z4.local -eq [datetime]'2026-11-02 20:00' -and (Format-SchedAt $z4 $n0) -match '^明天') "20:00 already passed today → next one, shown as 明天: $(Format-SchedAt $z4 $n0)"
Assert ($null -eq (Resolve-SchedAt '11:00' '火星时间' $n0)) 'unknown zone name → refused (asks again)'
$z5 = Resolve-SchedAt '2026-11-02 09:00' 'UTC' $n0; Assert ($z5.utc -eq [datetime]'2026-11-02 09:00' -and $z5.local -eq [datetime]'2026-11-02 04:00') "UTC 09:00 → local 04:00, stored as absolute time"
# 中文说法（「现在」= 2026-11-01 20:56 本机）
$n1 = [datetime]'2026-11-01 20:56'
function CT($said) { $x = Resolve-SchedAt $said '' $n1; @{ at = $x.local; text = (Format-SchedAt $x $n1) } }
$c = CT '11点'; Assert ($c.at -eq [datetime]'2026-11-01 23:00' -and $c.text -match '^今晚 23:00') "bare 11点 at 20:56 → $($c.text)"
$c = CT '8点'; Assert ($c.at -eq [datetime]'2026-11-02 08:00' -and $c.text -match '^明天上午 08:00') "bare 8点 at 20:56 → $($c.text)"
$c = CT '明天11点'; Assert ($c.at -eq [datetime]'2026-11-02 11:00' -and $c.text -match '^明天上午 11:00') "明天11点 → $($c.text)"
$c = CT '上午11点'; Assert ($c.at -eq [datetime]'2026-11-02 11:00' -and $c.text -match '^明天上午') "上午11点 at 20:56 → $($c.text)"
$c = CT '今晚十一点半'; Assert ($c.at -eq [datetime]'2026-11-01 23:30') "今晚十一点半 → $($c.text)"
$c = CT '后天下午3点15'; Assert ($c.at -eq [datetime]'2026-11-03 15:15') "后天下午3点15 → $($c.text)"
$c = CT '21点'; Assert ($c.at -eq [datetime]'2026-11-01 21:00') "21点 (24-hour) → $($c.text)"
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $script:ok / $script:tot passed"

if($script:ok -ne $script:tot){exit 1}
