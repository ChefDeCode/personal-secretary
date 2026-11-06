# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_事件.ps1 — 从聊天里自动发现「带时间的事」并出卡（你点了「好」才会定、才会发）；说不清楚的就在秘书对话里问你一句。
# 值守在整理消息时顺便找出事件（同一次模型调用，不多花钱），写进 data\events.jsonl（每行加密）；秘书每 15 秒看一眼新的，出卡或提问。
# 类型：提醒对方 / 叫你做事 / 你答应的 / 约好的事 / 你在等回复 / 重复提醒 / 改时间 / 取消 / 不清楚
# 时间：模型只抄原话（「11点」「周五前」「明天下午」），由这里按规则算（默认本机时间；明说时区才换算；光说「X点」取最近的那个）。
function Get-EvPath { Join-Path $script:V2Data 'events.jsonl' }
function Get-EvSeenPath { Join-Path $script:V2Data 'events_seen.txt' }
function Get-EventKey([string]$conv, [string]$type, [string]$what, [string]$time) { $s = "$conv|$type|$(($what -replace '\s', '').ToLower())|$($time -replace '\s', '')"; $b = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s)); ([BitConverter]::ToString($b) -replace '-', '').Substring(0, 16) }
function Get-NewEvents { $f = Get-EvPath; if (-not (Test-Path $f)) { return @() }; $seen = @{}; if (Test-Path (Get-EvSeenPath)) { foreach ($k in Get-Content (Get-EvSeenPath)) { $seen[$k] = 1 } }
  $out = @(); $keys = @{}; foreach ($l in Get-Content $f -Encoding UTF8) { if (-not $l) { continue }; $e = $null; try { $e = (Unprotect $l) | ConvertFrom-Json } catch {}; if ($e -and -not $seen.ContainsKey($e.key) -and -not $keys.ContainsKey($e.key)) { $keys[$e.key] = 1; $out += $e } }; $out }
function Set-EventSeen([string]$key) { Add-Content (Get-EvSeenPath) $key -Encoding UTF8 }

# —— 时间：先按定时的规则算；算不出再认「周五」「明天」（没几点）「晚点」这些，并说明是怎么定的；还是算不出就返回 $null（去问你）——
function Resolve-EventTime([string]$said, [string]$tz, [datetime]$now = (Get-Date)) {
  $s = ([string]$said -replace '\s', ''); if (-not $s) { return $null }
  $x = Resolve-SchedAt ([string]$said).Trim() $tz $now; if (-not $x) { $x = Resolve-SchedAt $s $tz $now }; if ($x) { return @{ local = $x.local; text = (Format-SchedAt $x $now); note = '' } }
  if ($tz -and -not (Resolve-Zone $tz)) { return $null }
  $note = ''; $d = $null
  $wd = @{ '一' = 1; '二' = 2; '三' = 3; '四' = 4; '五' = 5; '六' = 6; '日' = 0; '天' = 0; '末' = 6 }
  if ($s -match '(下)?(周|星期|礼拜)([一二三四五六日天末])') { $t = $wd[$Matches[3]]; $off = ($t - [int]$now.DayOfWeek + 7) % 7; if ($Matches[1]) { $off += 7 }; if ($off -eq 0 -and $s -notmatch '今') { $off = 0 }; $d = $now.Date.AddDays($off) }
  elseif ($s -match '后天') { $d = $now.Date.AddDays(2) } elseif ($s -match '明天|明早|明晚') { $d = $now.Date.AddDays(1) } elseif ($s -match '今天|今晚|今早') { $d = $now.Date }
  if ($d) {
    $rest = ($s -replace '(下)?(周|星期|礼拜)[一二三四五六日天末]', '' -replace '今天|明天|后天', '')
    $tm = $null; if ($rest -match '[0-9零〇一二两三四五六七八九十]+[点:：时]') { $tm = Resolve-CnTime ("今天" + $rest) $d.AddMinutes(-1) }
    if ($tm) { $d = $d.Date.Add($tm.TimeOfDay) }
    elseif ($s -match '晚') { $d = $d.AddHours(20); $note = '没说几点，先按晚上 8 点' }
    elseif ($s -match '下午') { $d = $d.AddHours(15); $note = '没说几点，先按下午 3 点' }
    elseif ($s -match '前$|之前|以前|截止') { $d = $d.AddHours(18); $note = '没说几点，先按那天下午 6 点前' }
    else { $d = $d.AddHours(9); $note = '没说几点，先按上午 9 点' }
    if ($d -le $now) { return $null }
    return @{ local = $d; text = (Format-SchedTime $d $now); note = $note } }
  if ($s -match '晚点|待会|一会儿?|稍后|回头') { $d = $now.AddHours(2); $d = $d.Date.AddHours($d.Hour).AddMinutes([Math]::Ceiling($d.Minute / 15) * 15); return @{ local = $d; text = (Format-SchedTime $d $now); note = '没说具体时间，先按 2 小时后' } }
  $null }

# 草稿不能替你答应没说过的事：草稿里出现原文里没有的数字 / 钱 / 「答应、同意、可以」这类词，就不用这句草稿（改成问你）
function Test-SafeDraft([string]$draft, [string]$orig) {
  if (-not $draft) { return $false }; foreach ($m in [regex]::Matches($draft, '\d+')) { if (-not $orig.Contains($m.Value)) { return $false } }
  if ($draft -match '[元块¥$]|万|千' -and $orig -notmatch '[元块¥$]|万|千') { return $false }
  if ($draft -match '答应|同意|没问题|一定|保证|可以的' ) { return $false }; $true }
# 提问的预设答案：不能带日期、数字、钱，也不能替你同意
function Get-SafeAnswers($ans) { @(@($ans) | Where-Object { $_ -and $_.Length -le 16 -and $_ -notmatch '\d|[元块¥$]|同意|答应|可以|好的|没问题' } | Select-Object -First 3) }

# —— 把一个事件变成卡片（或提问）。返回 @{ kind = 'event' | 'question' | 'skip'; card }
function Build-EventCard($e, [datetime]$now = (Get-Date)) {
  $who = [string]$e.谁; $what = [string]$e.事情; $quote = [string]$e.原文; if ($quote.Length -gt 40) { $quote = $quote.Substring(0, 40) + '…' }
  $seen = "$(if ($who) { $who } else { '聊天里' })：$quote"
  $ask = { param($q, $why) $opts = @(Get-SafeAnswers $e.建议回答) + @('不用管'); @{ kind = 'question'; card = @{ kind = 'question'; status = 'open'; key = $e.key; conv = [string]$e.conv; who = $who; seen = $seen; title = $q; why = $why; opts = $opts; noInput = $false; result = @() } } }
  if ($e.类型 -eq '不清楚' -or $e.把握 -eq '低') { return (& $ask $(if ($e.问题) { [string]$e.问题 } else { "这件事要我帮你做点什么吗？（$what）" }) '说得不够清楚') }
  $t = $null; $pending = $false
  if ($e.类型 -notin '取消') { $t = Resolve-EventTime ([string]$e.时间原话) ([string]$e.时区) $now
    if (-not $t -and $e.类型 -in '提醒对方', '叫你做事', '你答应的', '约好的事', '你在等回复') { $pending = $true; $t = @{ local = $null; text = '（时间待定）'; note = '' } }
    elseif (-not $t -and $e.类型 -ne '改时间') { return (& $ask "$(if ($who) { $who } else { '对方' }) 说的「$($e.时间原话)」是什么时候？要我什么时候提醒？" '时间不清楚') } }
  $base = @{ status = 'open'; key = $e.key; conv = [string]$e.conv; who = $who; what = $what; seen = $seen; etype = [string]$e.类型; noInput = $false; result = @() }
  if ($t -and $t.local) { $base.at = $t.local.ToString('s'); $base.atText = $t.text; $base.note = $t.note }
  switch ([string]$e.类型) {
    '提醒对方' { if (-not (Test-SafeDraft ([string]$e.草稿) ([string]$e.原文))) { return (& $ask "$who 让你到时候提醒他（$what），要我到 $($t.text) 替你发一句提醒吗？发什么？" '草稿不能替你决定') }
                $base.draft = [string]$e.草稿; $base.title = "到点替你提醒 $who"; $base.action = "$($t.text) 替你给 $who 发：「$($e.草稿)」"; $base.opts = @('好，到点替你发', '不用') }
    '叫你做事' { $base.title = "$who 让你做的事"; $base.action = "$($t.text) 提醒你：$what$(if ($e.时间原话 -match '前') { '（提前 2 小时也提醒一次）' } else { '' })"; $base.opts = @('好', '不用') }
    '你答应的' { $base.title = '你答应的事'; $base.action = "$($t.text) 提醒你：$what"; $base.opts = @('好', '不用') }
    '约好的事' { $base.title = '约好的事'; $base.action = "放进「接下来」，$($t.text)（提前 10 分钟提醒你）：$what"; $base.opts = @('好', '不用') }
    '你在等回复' { if ($e.草稿 -and -not (Test-SafeDraft ([string]$e.草稿) ([string]$e.原文))) { $e.草稿 = '' }; $base.draft = [string]$e.草稿; $base.title = "你在等 $who"; $base.action = "$($t.text) 如果 $who 还没回，问你要不要催一下"; $base.opts = @('好', '不用') }
    '重复提醒' { $rep = $(if ($e.时间原话 -match '每周|每个?星期|每个?礼拜') { 'weekly' } else { 'daily' }); $base.repeat = $rep; $base.title = '重复提醒'; $base.action = "$(if ($rep -eq 'weekly') { '每周' } else { '每天' }) $($t.local.ToString('HH:mm'))$(if ($rep -eq 'weekly') { "（$('日一二三四五六'[[int]$t.local.DayOfWeek])）" }) 提醒你：$what（第一次 $($t.text)）"; $base.opts = @('好', '不用') }
    '改时间' { if (-not $t) { return (& $ask "$who 说时间改了，改到什么时候？" '新时间不清楚') }; $base.title = '时间改了'; $base.ref = [string]$e.指的是; $base.action = "「$(if ($e.指的是) { $e.指的是 } else { $what })」改到 $($t.text)"; $base.opts = @('按新时间', '不用') }
    '取消' { $base.title = '取消了'; $base.ref = [string]$e.指的是; $base.action = "「$(if ($e.指的是) { $e.指的是 } else { $what })」取消了"; $base.opts = @('取消这条', '不用') }
    default { return @{ kind = 'skip' } } }
  $base.kind = 'event'
  if ($pending) {   # 两张卡：一张问时间（给 2–3 个建议时间，最像的标「建议」），一张问做不做；两张都答了才定
    $sg = @(Get-TimeSuggestions ([string]$e.时间原话) $now); $link = [guid]::NewGuid().ToString('n').Substring(0, 8)
    $base.waitTime = $true; $base.link = $link; $base.ev = $e
    $tc = @{ kind = 'evtime'; status = 'open'; link = $link; key = "$($e.key)|t"; who = $who; seen = $seen; title = "什么时候？$(if ($e.时间原话) { "（$who 说的是「$($e.时间原话)」）" } else { '' })"; opts = @($sg | ForEach-Object { $_.label }); optVals = @($sg | ForEach-Object { $_.at }); noInput = $false; result = @() }
    return @{ kind = 'pair'; card = $base; time = $tc } }
  @{ kind = 'event'; card = $base } }
# 建议时间：按说法和现在的时间猜 2–3 个（最像的排第一并标「建议」）
function Get-TimeSuggestions([string]$said, [datetime]$now = (Get-Date)) {
  $c = New-Object System.Collections.ArrayList
  $add = { param($d, $w) if ($d -gt $now -and -not ($c | Where-Object { $_.d -eq $d })) { [void]$c.Add(@{ d = $d; w = $w }) } }
  $tonight = $now.Date.AddHours(20); $tmAm = $now.Date.AddDays(1).AddHours(9); $tmPm = $now.Date.AddDays(1).AddHours(15); $todayPm = $now.Date.AddHours(15)
  if ($said -match '早|上午') { & $add $tmAm 3 } elseif ($said -match '下午') { & $add $(if ($todayPm -gt $now.AddHours(1)) { $todayPm } else { $tmPm }) 3 } elseif ($said -match '晚') { & $add $(if ($tonight -gt $now.AddMinutes(30)) { $tonight } else { $now.Date.AddDays(1).AddHours(20) }) 3 }
  & $add $(if ($tonight -gt $now.AddMinutes(30)) { $tonight } else { $tmAm }) 2; & $add $tmAm 1; & $add $tmPm 0
  $i = 0; @($c | Sort-Object { - $_.w } | Select-Object -First 3 | ForEach-Object { $i++; @{ label = "$(if ($i -eq 1) { '建议：' } else { '' })$(Format-SchedTime $_.d $now)"; at = $_.d.ToString('s') } }) }

# 改时间 / 取消：找到同一个聊天里、讲同一件事的那张卡（定了的、还没定的都算）
function Find-RefCard($items, [string]$conv, [string]$ref) {
  $r = ($ref -replace '\s', ''); $best = $null; $bs = 0
  foreach ($it in @($items | Where-Object { $_.card -and $_.card.kind -in 'event', 'send' -and $_.card.status -in 'open', 'scheduled' -and ($_.card.conv -eq $conv -or $_.card.who -eq $conv) })) {
    $w = ([string]$it.card.what + [string]$it.card.text -replace '\s', ''); $sc = 0; foreach ($ch in $r.ToCharArray()) { if ($w.Contains([string]$ch)) { $sc++ } }
    if ($sc -gt $bs) { $bs = $sc; $best = $it } }
  if ($best -and $bs -ge [Math]::Max(2, [int]($r.Length / 2))) { $best } else { $null } }
# 自定义提醒（你的提醒）去掉一条（改时间、取消用）
function Remove-CustomReminder([string]$keyPrefix) { $f = RemPath 'reminders_custom.jsonl'; if (-not (Test-Path $f)) { return }; $keep = @(Get-Content $f -Encoding UTF8 | Where-Object { $_ } | Where-Object { try { -not ([string]((MemU $_) | ConvertFrom-Json).key).StartsWith($keyPrefix) } catch { $true } }); [IO.File]::WriteAllLines($f, [string[]]$keep, (New-Object Text.UTF8Encoding $false)) }

# 「在办的事」：秘书发现的、你让它做的，都在这里；状态：待你确认 / 已安排 / 等对方 / 进行中 / 已完成 / 已取消。最近 7 天的，加上所有还没结束的
function Get-Activity([datetime]$now = (Get-Date)) {
  $out = @()
  foreach ($it in @(Get-ChatItems | Where-Object { $_.card -and ($_.card.kind -in 'event', 'question', 'watch' -or ($_.card.kind -eq 'send' -and ($_.card.at -or $_.card.status -in 'scheduled', 'sending'))) })) {
    $c = $it.card; $last = @($c.result) | Where-Object { $_ } | Select-Object -Last 1
    $state = switch ($c.status) { 'open' { if ($c.kind -eq 'question') { '待你回答' } else { '待你确认' } } 'scheduled' { if ($c.kind -eq 'watch') { '盯着' } elseif ($c.etype -eq '你在等回复') { '等对方' } else { '已安排' } } 'sending' { '进行中' }
      default { if ($c.cancelled -or ($last -and [string]$last.text -match '^(已取消|不用|好，不管)')) { '已取消' } elseif ($last -and $last.ok) { '已完成' } else { '已结束' } } }
    $active = $state -in '待你回答', '待你确认', '已安排', '等对方', '进行中', '盯着'
    $when = $(try { [datetime]$it.ts } catch { $now }); if (-not $active -and ($now - $when).TotalDays -gt 7) { continue }
    $what = if ($c.kind -eq 'send') { "给 $($c.who) 发「$($c.text)」" } elseif ($c.kind -eq 'question') { [string]$c.title } elseif ($c.kind -eq 'watch') { "盯着：$($c.what)" + $(if ($c.hits) { "（有过 $($c.hits) 次动静）" } else { '' }) } else { $(if ($c.action) { [string]$c.action } else { [string]$c.what }) }
    $next = switch ($state) { '待你确认' { "等你在卡片上点「$(@($c.opts)[0])」" } '待你回答' { '等你回答' } '已安排' { "到点（$($c.atText)）自动做" } '等对方' { "到点（$($c.atText)）看对方回没回" } '进行中' { '正在做' } '盯着' { if ($c.untilText) { "一直盯到 $($c.untilText)，有动静就告诉你" } else { '有动静就告诉你，直到你说停' } } default { if ($last) { [string]$last.text } else { '' } } }
    $atD = $(if ($c.at) { try { [datetime]$c.at } catch { $null } }); $toOther = ($c.kind -eq 'send' -or $c.etype -eq '提醒对方')
    $short = switch ($state) { '已安排' { if ($toOther) { '到点自动发' } else { '到点提醒你' } } '等对方' { '到点看对方回没回，没回再问你' } '盯着' { if ($c.untilText) { "盯到 $($c.untilText)，有动静就告诉你" } else { '有动静就告诉你' } } default { $next } }
    if ($atD -and $active -and $state -ne '盯着') { $short = "$short · 本机时间 $($atD.ToString('M月d日'))" }
    $timeShort = (([string]$c.atText) -replace '（[^）]*）', '').Trim(); if (-not $timeShort -and $it.ts) { try { $timeShort = ([datetime]$it.ts).ToString('HH:mm') } catch {} }
    $chatTxt = $(if ($c.conv) { [string]$c.conv } else { [string]$c.who })
    $out += [ordered]@{ item = $it.id; state = $state; short = $short; time = $timeShort; chatInWhat = ([bool]$chatTxt -and ([string]$what).Contains($chatTxt)); active = $active; title = $(if ($c.title) { [string]$c.title } elseif ($c.kind -eq 'send') { '替你发消息' } else { '事情' }); what = $what; at = [string]$c.atText; chat = $(if ($c.conv) { [string]$c.conv } else { [string]$c.who }); next = $next; canCancel = ($c.status -eq 'scheduled' -and $c.kind -ne 'watch'); canStop = ($c.kind -eq 'watch' -and $c.status -eq 'scheduled'); ts = $it.ts } }
  @($out | Sort-Object @{ e = { -not $_.active } }, @{ e = { $_.ts }; Descending = $true }) }
# 设置 → 秘书可以自己做的事。默认都是「先问我」
$script:ActRules = [ordered]@{
  self_remind  = @{ label = '提醒我自己'; types = @('叫你做事', '你答应的'); allow = @('do', 'ask', 'tell') }
  add_next     = @{ label = '加到「接下来」'; types = @('约好的事'); allow = @('do', 'ask', 'tell') }
  chase_reply  = @{ label = '到点看对方回没回'; types = @('你在等回复'); allow = @('do', 'ask', 'tell') }   # 只是到点看一眼；真要催还会再问你
  remind_other = @{ label = '替我给别人发提醒'; types = @('提醒对方'); allow = @('ask', 'tell') }   # 发给别人：每条都要你点
  reply_other  = @{ label = '回复别人'; types = @(); allow = @('ask', 'tell') }
}
function Get-ActRules { $r = (Read-Config).rules; $o = [ordered]@{}; foreach ($k in $script:ActRules.Keys) { $x = [string]$(if ($r) { $r.$k }); $o[$k] = $(if ($x -in $script:ActRules[$k].allow) { $x } else { 'ask' }) }; $o }
function Set-ActRule([string]$k, [string]$val) {
  if (-not $script:ActRules.Contains($k) -or $val -notin $script:ActRules[$k].allow) { return '这一项不能这么设' }
  $cfg = Read-Config; if (-not $cfg.rules) { $cfg | Add-Member -NotePropertyName rules -NotePropertyValue ([pscustomobject]@{}) -Force }
  $cfg.rules | Add-Member -NotePropertyName $k -NotePropertyValue $val -Force; Save-Config $cfg; '' }
# 固定底线：发给别人、文件、钱、密码/登录、删除、接受邀请 → 永远每条都要你点，不看设置
function Test-FloorNeedsClick($c) {
  if ($c.kind -eq 'send' -or $c.etype -eq '提醒对方' -or $c.draft) { return $true }
  ([string]"$($c.what) $($c.action)") -match '文件|转账|付款|打钱|汇款|红包|密码|验证码|登录|登陆|删除|删掉|邀请|同意加入|接受' }
# 这张卡按你的设置该怎么办：do（自己做）/ ask（出卡问你）/ tell（只告诉你，不安排）。执行前再读一次设置
function Get-CardRule($c) {
  if ($c.kind -ne 'event' -or -not $c.at -or $c.waitTime) { return 'ask' }
  $k = $null; foreach ($rk in $script:ActRules.Keys) { if ([string]$c.etype -in $script:ActRules[$rk].types) { $k = $rk } }; if (-not $k) { return 'ask' }
  $r = (Get-ActRules)[$k]; if ($r -eq 'do' -and (Test-FloorNeedsClick $c)) { return 'ask' }; $r }
# 学你的习惯：同一类事 14 天里你点了 3 次「不用」→ 问一次「以后这类不用提醒了吗？」。只会往「少打扰」改（改成只告诉我），从不自己放宽；设置里随时改回来
function Get-LearnPath { Join-Path $script:V2Data 'learn.json' }
function Get-Learn { $p = Get-LearnPath; $o = @{}; if (Test-Path $p) { try { (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $o[$_.Name] = $_.Value } } catch {} }; $o }
function Save-Learn($o) { [IO.File]::WriteAllText((Get-LearnPath), ($o | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false)) }
function Get-RuleKeyOf($c) { foreach ($rk in $script:ActRules.Keys) { if ([string]$c.etype -in $script:ActRules[$rk].types) { return $rk } }; $null }
# 记一次「不用」；该问的时候返回规则名
function Add-Dismissal($c, [datetime]$now = (Get-Date)) {
  $rk = Get-RuleKeyOf $c; if (-not $rk) { return $null }
  $L = Get-Learn; $e = $L[$rk]; if (-not $e) { $e = [pscustomobject]@{ times = @(); asked = '' } }
  $ts = @(@($e.times) | Where-Object { $_ -and ($now - [datetime]$_).TotalDays -le 14 }) + $now.ToString('s')
  $e = [pscustomobject]@{ times = $ts; asked = [string]$e.asked }; $L[$rk] = $e; Save-Learn $L
  if ($ts.Count -ge 3 -and -not $e.asked -and (Get-ActRules)[$rk] -ne 'tell') { return $rk }; $null }
function Set-LearnAsked([string]$rk, [string]$answer) { $L = Get-Learn; $e = $L[$rk]; if (-not $e) { $e = [pscustomobject]@{ times = @(); asked = '' } }; $L[$rk] = [pscustomobject]@{ times = @($e.times); asked = $answer }; Save-Learn $L }
# 帮我盯着：你说「帮我盯着 X」→ 点「好」后一直盯着（可设几天），在「在办的事」里能看到、能停
function Get-WatchPath { Join-Path $script:V2Data 'watches.json' }
function Get-Watches([switch]$Active, [datetime]$now = (Get-Date)) {
  $p = Get-WatchPath; $w = @(); if (Test-Path $p) { try { $w = @(Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }
  $w = @($w | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; what = Unprotect $_.what; chat = $(if ($_.chat) { Unprotect $_.chat } else { '' }); status = [string]$_.status; created = [string]$_.created; until = [string]$_.until; hits = [int]$_.hits; item = [string]$_.item } })
  if ($Active) { $w = @($w | Where-Object { $_.status -eq 'on' -and (-not $_.until -or [datetime]$_.until -gt $now) }) }; $w }
function Save-Watches($w) { $out = @($w | ForEach-Object { [ordered]@{ id = $_.id; what = Protect $_.what; chat = $(if ($_.chat) { Protect $_.chat } else { '' }); status = $_.status; created = $_.created; until = $_.until; hits = $_.hits; item = $_.item } }); [IO.File]::WriteAllText((Get-WatchPath), (ConvertTo-Json @($out) -Depth 3), (New-Object Text.UTF8Encoding $false)) }
function Add-Watch([string]$what, [string]$chat, [int]$days, [string]$item) {
  $w = @(Get-Watches); $id = 'w' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
  $w += [pscustomobject]@{ id = $id; what = $what; chat = $chat; status = 'on'; created = (Get-Date).ToString('s'); until = $(if ($days -gt 0) { (Get-Date).AddDays($days).ToString('s') } else { '' }); hits = 0; item = $item }; Save-Watches $w; $id }
function Set-WatchStatus([string]$id, [string]$status) { $w = @(Get-Watches); foreach ($x in $w) { if ($x.id -eq $id) { $x.status = $status } }; Save-Watches $w }
function Add-WatchHit([string]$id) { $w = @(Get-Watches); foreach ($x in $w) { if ($x.id -eq $id) { $x.hits++ } }; Save-Watches $w }