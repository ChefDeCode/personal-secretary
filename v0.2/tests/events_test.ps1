# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 「带时间的事」出卡流程测试：写入虚构事件（不来自真聊天）→ 秘书出卡 / 提问 / 两张连着的卡 → 模拟你点按钮 → 看定时、提醒、取消、改时间对不对。
# 不发送（Start-Send、Start-Turn 换成只记录）、不碰微信；全部在临时文件夹里
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . "$v2\lib_提醒.ps1"
$T = Join-Path $env:TEMP 'secretary_events_test'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\actions", "$T\root\data" | Out-Null
$script:ChatFile = "$T\chat.jsonl"; $script:ChatArchive = "$T\chat_archive.jsonl"; $script:ActDir = "$T\actions"; $script:V2Data = $T; $script:RemDir = $T; $script:Root = "$T\root"
$ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Step-Events', 'On-Choose', 'On-ChooseCore', 'Step-Scheduled', 'Close-StuckScheduled', 'Test-RepliedSince', 'Stop-Watch', 'Resolve-TaskTimeChoice', 'Apply-SendResultToCard' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$script:Started = New-Object System.Collections.ArrayList; $script:Turns = New-Object System.Collections.ArrayList; $script:Notices = 0
function Start-Send([string]$id, $it) { [void]$script:Started.Add($id) }; function Post($o) { }; function Show-Notice($t) { $script:Notices++ }; function Start-Turn($t) { [void]$script:Turns.Add($t) }
$realGetSwitch = ${function:Get-Switch}; function Get-Switch([string]$k) { if ($k -eq 'send_messages') { return $true }; & $realGetSwitch $k }
function Test-Quiet($n, $c) { $false }; function Request-ReadSnapshot {}
$script:SchedLast = [datetime]::MinValue; $script:EvLast = [datetime]::MinValue; $script:QAsked = New-Object System.Collections.ArrayList; $script:AskStats = @{}
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$now = Get-Date
function AddEv([hashtable]$e) { $d = [ordered]@{ conv = '测试联系人A'; 谁 = '测试联系人A'; 事情 = ''; 时间原话 = ''; 时区 = ''; 草稿 = ''; 指的是 = ''; 把握 = '高'; 问题 = ''; 建议回答 = @(); 原文 = ''; 原文时间 = $now.ToString('s') }; foreach ($k in $e.Keys) { $d[$k] = $e[$k] }
  $d.key = Get-EventKey $d.conv $d.类型 $d.事情 $d.时间原话; Add-Content (Get-EvPath) (Protect ($d | ConvertTo-Json -Compress -Depth 4)) -Encoding UTF8; $d.key }
. (Join-Path $v2 'lib_主后台.ps1')
function Get-ReadWorkerModules {@()}
# Functional event semantics use the actual worker body; thread handoff is covered separately.
function Start-SecWork {param($Key,$Modules,$InputObject,$Code,$Then,[switch]$Replace);$result=& ([scriptblock]::Create([string]$Code)) $InputObject;if($Then){& $Then @{ok=$true;data=$result}};$true}
function Tick { $script:EvLast = [datetime]::MinValue; Step-Events }
function CardOf($key) { Get-ChatItems | Where-Object { $_.card -and $_.card.key -eq $key } | Select-Object -Last 1 }
function Cards { @(Get-ChatItems | Where-Object { $_.card }) }

# 1) 时间明确：不问，直接出卡；点「好」→ 定时（只定、不发）
$k1 = AddEv @{ 类型 = '提醒对方'; 事情 = '交周报'; 时间原话 = '23:59'; 草稿 = '到点啦，记得交周报～'; 原文 = '23:59提醒我交周报' }; Tick
$c1 = CardOf $k1; Assert ($c1 -and $c1.card.kind -eq 'event' -and $c1.card.at) "certain time → one action card, no question ($($c1.card.atText))"
On-Choose $c1.id 1 ''; $c1 = CardOf $k1; Assert ($c1.card.status -eq 'scheduled' -and @(Get-Scheduled | Where-Object { $_.status -eq 'scheduled' }).Count -eq 1 -and $script:Started.Count -eq 0) 'click 好 → scheduled send job, nothing sent now'
# 2) 光说「X点」：不问
$k2 = AddEv @{ 类型 = '叫你做事'; 事情 = '回电话'; 时间原话 = "$(($now.AddHours(2)).Hour % 12)点"; 原文 = '记得回电话' }; Tick
$c2 = CardOf $k2; Assert ($c2 -and $c2.card.kind -eq 'event' -and $c2.card.at) "bare hour → card without question ($($c2.card.atText))"
# 3) 模糊但能猜（明天 / 周五前 / 晚点）：不问，卡上写怎么猜的
$k3 = AddEv @{ 类型 = '你答应的'; 事情 = '把资料发过去'; 时间原话 = '明天'; 原文 = '我明天发你'; 发言 = 'self' }; $k3b = AddEv @{ 类型 = '叫你做事'; 事情 = '交方案'; 时间原话 = '周五前'; 原文 = '周五前把方案给我' }; $k3c = AddEv @{ 类型 = '你答应的'; 事情 = '回消息'; 时间原话 = '晚点'; 原文 = '我晚点回你' }; Tick
$g = @($k3, $k3b, $k3c | ForEach-Object { CardOf $_ }); Assert (@($g | Where-Object { $_.card.kind -eq 'event' -and $_.card.note }).Count -eq 3) "vague with context → 3 cards, each says how it guessed ($(($g | ForEach-Object { $_.card.note }) -join ' / '))"
# 4) 猜不出：两张连着的卡；先选时间再点好
$k4 = AddEv @{ 类型 = '提醒对方'; 事情 = '交表'; 时间原话 = '过阵子'; 草稿 = '记得交表哦'; 原文 = '过阵子提醒我交表' }; Tick
$a4 = CardOf $k4; $t4 = CardOf "$k4|t"; Assert ($a4.card.waitTime -and $t4.card.kind -eq 'evtime' -and @($t4.card.opts).Count -ge 2 -and @($t4.card.opts)[0] -match '^建议') "unguessable → two linked cards (time: $(@($t4.card.opts) -join ' | '))"
On-Choose $t4.id 1 ''; $a4 = CardOf $k4; "   debug: at=$($a4.card.at) wait=$($a4.card.waitTime) status=$($a4.card.status) evType=$($a4.card.ev.类型) evTime=$($a4.card.ev.时间原话) t4status=$((CardOf "$k4|t").card.status) t4res=$(@((CardOf "$k4|t").card.result)[0].text) actItem=$((CardOf "$k4|t").card.actItem) a4id=$($a4.id)"; Assert ($a4.card.at -and -not $a4.card.waitTime -and $a4.card.status -eq 'open') 'order A: pick time first → action card gets the time, still waits for 好'
On-Choose $a4.id 1 ''; $a4 = CardOf $k4; Assert ($a4.card.status -eq 'scheduled') 'order A: then 好 → scheduled'
$k5 = AddEv @{ 类型 = '提醒对方'; 事情 = '买票'; 时间原话 = '改天'; 草稿 = '记得买票'; 原文 = '改天提醒我买票' }; Tick
$a5 = CardOf $k5; $t5 = CardOf "$k5|t"; On-Choose $a5.id 1 ''; $a5 = CardOf $k5; Assert ($a5.card.status -eq 'open' -and $a5.card.approvedPending -and @($a5.card.result)[0].text -match '等你选时间') 'order B: 好 first → shows 「等你选时间」, nothing scheduled yet'
$nJobs = @(Get-Scheduled | Where-Object { $_.status -eq 'scheduled' }).Count; On-Choose $t5.id 0 '明天上午10点'; $a5 = CardOf $k5; Assert ($a5.card.status -eq 'scheduled' -and @(Get-Scheduled | Where-Object { $_.status -eq 'scheduled' }).Count -eq $nJobs + 1) 'order B: then typed time → scheduled at once'
$k6 = AddEv @{ 类型 = '叫你做事'; 事情 = '看文件'; 时间原话 = '有空的时候'; 原文 = '有空的时候看下文件' }; Tick
$a6 = CardOf $k6; $t6 = CardOf "$k6|t"; On-Choose $a6.id 2 ''; $t6 = CardOf "$k6|t"; Assert ($t6.card.status -eq 'closed' -and (CardOf $k6).card.status -eq 'closed') '不用 on the action card closes both'
# 5) 提醒你自己 / 约好的事：定提醒（约好的事提前 10 分钟再提醒一次）
$k7 = AddEv @{ 类型 = '约好的事'; 事情 = '电话会'; 时间原话 = '明天下午3点'; 原文 = '明天下午3点电话会' }; Tick; On-Choose (CardOf $k7).id 1 ''
$rem = @(Get-CustomReminders | Where-Object { ([string]$_.key).StartsWith("ev|$k7") }); Assert ($rem.Count -eq 2) "appointment → reminder + 10-min heads-up ($($rem.Count) reminders)"
# 6) 等回复：到点没回 → 出一张「要不要催」的发送卡（不自动发）
$k8 = AddEv @{ 类型 = '你在等回复'; 事情 = '报价'; 时间原话 = '23:58'; 草稿 = '方便的时候回我一下报价吧'; 原文 = '23:58前给我报价'; 发言 = 'self' }; Tick; $c8 = CardOf $k8; On-Choose $c8.id 1 ''
$jobs = @(Get-Scheduled); foreach ($j in $jobs) { if ($j.actionId -eq "fu|$k8") { $j.at = $now.AddMinutes(-1).ToString('o') } }; Save-Scheduled $jobs; $script:SchedLast = [datetime]::MinValue; Step-Scheduled
$nudge = @(Get-ChatItems | Where-Object { $_.card -and $_.card.kind -eq 'send' -and $_.card.text -eq '方便的时候回我一下报价吧' }); Assert ($nudge.Count -eq 1 -and $nudge[0].card.status -eq 'open' -and $script:Started.Count -eq 0) 'waiting + no reply by the time → a 「要不要催」 send card (needs your click), nothing sent'
# 7) 重复提醒：到点提醒一次、自动排下一次
$k9 = AddEv @{ 类型 = '重复提醒'; 事情 = '喝水'; 时间原话 = '每天早上8点'; 原文 = '每天早上8点提醒我喝水' }; Tick; On-Choose (CardOf $k9).id 1 ''
$jobs = @(Get-Scheduled); foreach ($j in $jobs) { if ($j.actionId -eq "rep|$k9") { $j.at = $now.AddMinutes(-1).ToString('o') } }; Save-Scheduled $jobs; $script:SchedLast = [datetime]::MinValue; Step-Scheduled
$rj = Get-Scheduled | Where-Object { $_.actionId -eq "rep|$k9" }; Assert (@(Get-CustomReminders | Where-Object { ([string]$_.key).StartsWith("rep|$k9") }).Count -eq 1 -and [datetime]$rj.at -gt $now) 'recurring → reminds once and schedules the next one'
# 8) 改时间 / 取消：找到原来那张，你点了才改 / 才取消
$k10 = AddEv @{ 类型 = '改时间'; 事情 = '交周报'; 指的是 = '交周报提醒'; 时间原话 = '23:57'; 原文 = '改到23:57吧' }; Tick; $c10 = CardOf $k10
Assert ($c10 -and $c10.card.refItem -eq $c1.id) 'time change → card pointing at the original'
On-Choose $c10.id 1 ''; $j1 = Get-Scheduled | Where-Object { $_.actionId -eq (CardOf $k1).card.actionId }; Assert (([datetime]$j1.at).ToString('HH:mm') -eq '23:57') 'click 按新时间 → original job moved'
$k11 = AddEv @{ 类型 = '取消'; 事情 = '交周报'; 指的是 = '交周报提醒'; 原文 = '周报不用提醒了' }; Tick; On-Choose (CardOf $k11).id 1 ''
$j1 = Get-Scheduled | Where-Object { $_.actionId -eq (CardOf $k1).card.actionId }; Assert ($j1.status -eq 'cancelled' -and (CardOf $k1).card.status -eq 'closed') 'cancel → original job cancelled after your click'
# 9) 重复 / 你自己已经让秘书定过的：不再出卡
$n0 = (Cards).Count; [void](AddEv @{ 类型 = '提醒对方'; 事情 = '交周报'; 时间原话 = '23:59'; 草稿 = '到点啦，记得交周报～'; 原文 = '23:59提醒我交周报' }); Tick; Assert ((Cards).Count -eq $n0) 'same event read again → no second card'
# 10) 拿不准 / 草稿想替你答应钱 / 预设答案带数字：都改成问你，而且问题里的预设答案干净
$script:QAsked.Clear(); $k12 = AddEv @{ 类型 = '不清楚'; 事情 = '周末的事'; 问题 = '是要我周末提醒你吗？'; 建议回答 = @('周末提醒我', '周六10点提醒', '不用'); 原文 = '那个周末再弄' }; Tick; $q12 = CardOf $k12
Assert ($q12.card.kind -eq 'question' -and -not (@($q12.card.opts) | Where-Object { $_ -match '\d' }) -and @($q12.card.opts)[-1] -eq '不用管') "unclear → question; presets with numbers removed ($(@($q12.card.opts) -join ' | '))"
$script:QAsked.Clear(); $k13 = AddEv @{ 类型 = '提醒对方'; 事情 = '转账'; 时间原话 = '23:59'; 草稿 = '我答应转你500元'; 原文 = '记得提醒我转账' }; Tick; Assert ((CardOf $k13).card.kind -eq 'question') 'draft that commits money the user never said → asks instead of a card'
On-Choose $q12.id 1 ''; Assert ($script:Turns.Count -eq 1 -and $script:Turns[0] -match '周末提醒我') 'answering a question → hands it to the secretary to make a normal card (still needs 好)'
# 11) 提问每小时最多 3 个（多的先留着）
$script:QAsked.Clear(); $ks = 1..4 | ForEach-Object { AddEv @{ 类型 = '不清楚'; 事情 = "测试问题$_"; 问题 = "问题$_？"; 原文 = "模糊$_" } }; Tick
$asked = @($ks | Where-Object { CardOf $_ }).Count; Assert ($asked -eq 3) "questions rate-limited: 3 shown, the 4th waits ($asked shown)"
# 12) 设置 → 秘书可以自己做的事（这里换成假的设置，不动真设置）
function Get-ActRules { [ordered]@{ self_remind = 'do'; add_next = 'tell'; chase_reply = 'ask'; remind_other = 'ask'; reply_other = 'ask' } }
$k8 = AddEv @{ 类型 = '叫你做事'; 事情 = '交周报'; 时间原话 = '明天下午3点'; 原文 = '明天下午3点前交周报' }; Tick
$c8 = CardOf $k8; Assert ($c8.card.status -eq 'scheduled' -and $c8.card.auto -and (@($c8.card.result) | Where-Object { $_.text -match '按你的设置' })) "rule 直接做 → self reminder scheduled without a click"
$k9 = AddEv @{ 类型 = '叫你做事'; 事情 = '把文件发给财务'; 时间原话 = '明天下午4点'; 原文 = '明天把文件发给财务' }; Tick
$c9 = CardOf $k9; Assert ($c9.card.status -eq 'open' -and -not $c9.card.auto) "fixed floor: a file task still waits for your click"
$k10 = AddEv @{ 类型 = '约好的事'; 事情 = '开会'; 时间原话 = '后天上午10点'; 原文 = '后天上午10点开会' }; Tick
$c10 = CardOf $k10; Assert ($c10.card.status -eq 'closed' -and (@($c10.card.result)[0].text -match '只告诉你')) "rule 只告诉我 → card shown, nothing scheduled"
$n11 = $script:Started.Count; $k11 = AddEv @{ 类型 = '提醒对方'; 事情 = '交表'; 时间原话 = '明天上午9点'; 草稿 = '记得交表'; 原文 = '明天9点提醒我交表' }; Tick
$c11 = CardOf $k11; Assert ($c11.card.status -eq 'open' -and $script:Started.Count -eq $n11) "sending to someone else always waits for your click"
# 13) 学你的习惯：同类 3 次「不用」→ 问一次；只往少打扰改
function Get-ActRules { [ordered]@{ self_remind = 'ask'; add_next = 'ask'; chase_reply = 'ask'; remind_other = 'ask'; reply_other = 'ask' } }
Remove-Item (Get-LearnPath) -ErrorAction SilentlyContinue; $script:RuleSet = @(); function Set-ActRule([string]$k, [string]$val) { $script:RuleSet += "$k=$val"; '' }
$kd = 1..3 | ForEach-Object { AddEv @{ 类型 = '叫你做事'; 事情 = "测试不用$_"; 时间原话 = "明天上午$($_ + 8)点"; 原文 = "不用$_" } }; Tick
$learn = { @(Get-ChatItems | Where-Object { $_.card -and $_.card.kind -eq 'learn' }) }
On-Choose (CardOf $kd[0]).id 0 ''; On-Choose (CardOf $kd[1]).id 0 ''; Assert ((& $learn).Count -eq 0) 'two 不用 → no question yet'
On-Choose (CardOf $kd[2]).id 0 ''; $lc = @(& $learn); Assert ($lc.Count -eq 1 -and $lc[0].card.rule -eq 'self_remind') "third 不用 → asks once ($($lc[0].card.title))"
$kd4 = AddEv @{ 类型 = '叫你做事'; 事情 = '测试不用4'; 时间原话 = '明天上午12点'; 原文 = '不用4' }; Tick; On-Choose (CardOf $kd4).id 0 ''; Assert (@(& $learn).Count -eq 1) 'never asks the same thing twice'
On-Choose $lc[0].id 1 ''; Assert (($script:RuleSet -join ',') -eq 'self_remind=tell') "answer 以后只告诉我 → rule becomes 只告诉我 only ($($script:RuleSet -join ','))"
# 14) 帮我盯着：确认卡 → 点好开始盯 → 值守报来有动静 → 出一张只告诉你的卡 → 不再盯
$wc = Add-ChatItem @{ role = 'ai'; card = @{ kind = 'watch'; status = 'open'; what = '有人提到报价'; chat = '测试群'; days = 3; untilText = 'x'; opts = @('好，帮我盯着', '不用') } }; On-Choose $wc.id 1 ''
$wc = Get-ChatItems | Where-Object id -eq $wc.id; $wid = [string]$wc.card.watchId; Assert ($wc.card.status -eq 'scheduled' -and @(Get-Watches -Active).Count -eq 1) 'watch: click 好 → starts watching (stored encrypted)'
Assert (-not ((Get-Content (Get-WatchPath) -Raw) -match '报价')) 'watch list on disk does not contain the text in the clear'
$act = @(Get-Activity) | Where-Object { $_.item -eq $wc.id }; Assert ($act.state -eq '盯着' -and $act.canStop) "watch shows in 在办的事 as 盯着 with a stop button ($($act.next))"
$wast = [Management.Automation.Language.Parser]::ParseFile("$(Split-Path $v2 -Parent)\12_值守.ps1", [ref]$null, [ref]$null); $Root = Split-Path $T -Parent | Join-Path -ChildPath 'wtest_root'; New-Item -ItemType Directory -Force "$Root\v0.2\data" | Out-Null; Copy-Item (Get-WatchPath) "$Root\v0.2\data\watches.json"
foreach ($fn in $wast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Get-WatchPrompt' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$wp1 = Get-WatchPrompt '测试群'; $wp2 = Get-WatchPrompt '别的聊天'; Assert ($wp1 -match [regex]::Escape($wid) -and $wp1 -match '报价' -and -not $wp2) 'watcher tells the model about the watch only for the chat it is limited to'
Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
$kw = AddEv @{ conv = '测试群'; 类型 = '盯着的事'; 事情 = '有人问报价什么时候发'; 指的是 = $wid; 原文 = '报价什么时候发？' }; Tick
$hit = Get-ChatItems | Where-Object { $_.card -and $_.card.kind -eq 'watchhit' } | Select-Object -Last 1; Assert ($hit -and $hit.card.status -eq 'open' -and $script:Started.Count -eq $n11) 'watch hit → a tell-only card, nothing sent'
[void](AddEv @{ conv = '测试群'; 类型 = '盯着的事'; 事情 = '编号不对'; 指的是 = 'wnope'; 原文 = 'x' }); $nh = @(Get-ChatItems | Where-Object { $_.card.kind -eq 'watchhit' }).Count; Tick; Assert (@(Get-ChatItems | Where-Object { $_.card.kind -eq 'watchhit' }).Count -eq $nh) 'hit for an unknown watch id → ignored'
On-Choose $hit.id 2 ''; $wc = Get-ChatItems | Where-Object id -eq $wc.id; Assert (@(Get-Watches -Active).Count -eq 0 -and $wc.card.status -eq 'closed' -and ((@(Get-Activity) | Where-Object { $_.item -eq $wc.id }).state -eq '已取消')) 'choose 不用再盯了 → watch stops, shows 已取消'
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $script:ok / $script:tot passed"

if($script:ok -ne $script:tot){exit 1}