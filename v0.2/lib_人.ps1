# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_人.ps1 — 人和称呼：把「明远」「周明远」「Leo明远」认成同一个人
# 存储：data\people.jsonl（每行一个人，DPAPI 加密，只在这台电脑）
#   { id, name?, chats: [{ app, title }], aliases: [{ text, source = user_confirmed | user_told, created }], not_same: [ "标题或名字" ], memIds: [长期记忆里关于这个人的条目编号] }
# 名字只来自秘书已经读到的（会话标题 = 备注名、群里的发送人名字）和用户亲口说的；从不读微信数据库。
# 认人规则（Resolve-Person）：只有「会话标题完全一样」或「用户确认过的称呼」才直接用；其它（模糊、多个、没有）一律出选择卡问用户。
# AI 发现的「可能是同一个人」只是建议，要用户点「是」才连上；点「不是」也记住，不再问。
if (-not $script:PeopleFile) { $script:PeopleFile = Join-Path $script:V2Data 'people.jsonl' }
function Get-People { if (-not (Test-Path $script:PeopleFile)) { return @() }; @(Get-Content $script:PeopleFile -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { (MemU $_) | ConvertFrom-Json } catch {} } | Where-Object { $_ }) }
function Save-People($list) { $lines = @($list | ForEach-Object { MemP ($_ | ConvertTo-Json -Depth 6 -Compress) }); [IO.File]::WriteAllLines($script:PeopleFile, [string[]]$lines, (New-Object Text.UTF8Encoding $false)) }
function NormName([string]$s) { ($s -replace '\s', '' -replace '[（(]\d+[)）]$', '').ToLowerInvariant() }
function New-PersonRecord { [pscustomobject]@{ id = 'p' + [guid]::NewGuid().ToString('N').Substring(0, 8); name = ''; chats = @(); aliases = @(); not_same = @(); memIds = @() } }

# —— 拼音首字母：GB2312 一级汉字按拼音排序，用区位码区间算首字母（只用来找候选，找到了也要问用户）——
$script:PyStarts = @(45217, 45253, 45761, 46318, 46826, 47010, 47297, 47614, 48119, 49062, 49324, 49896, 50371, 50614, 50622, 50906, 51387, 51446, 52218, 52698, 52980, 53689, 54481)
$script:PyLetters = 'abcdefghjklmnopqrstwxyz'
$script:Gb = [Text.Encoding]::GetEncoding(936)
function Get-Initials([string]$s) {
  $sb = New-Object Text.StringBuilder
  foreach ($c in $s.ToCharArray()) {
    if ($c -match '[A-Za-z]') { continue }
    $b = $script:Gb.GetBytes([string]$c); if ($b.Length -ne 2) { continue }
    $code = $b[0] * 256 + $b[1]; if ($code -lt 45217 -or $code -gt 55289) { continue }
    for ($i = $script:PyStarts.Count - 1; $i -ge 0; $i--) { if ($code -ge $script:PyStarts[$i]) { [void]$sb.Append($script:PyLetters[$i]); break } }
  }
  $sb.ToString()
}
# 拼音（如 mingyuan）大致对得上汉字的首字母（my）：每个首字母按顺序出现，并且开头对上
function Test-PinyinLike([string]$q, [string]$han) {
  $q = $q.ToLowerInvariant(); if ($q -notmatch '^[a-z]{2,}$') { return $false }
  $ini = Get-Initials $han; if ($ini.Length -lt 2) { return $false }
  if ($q -eq $ini) { return $true }
  for ($s = 0; $s -le $ini.Length - 2; $s++) {   # 名字可能只是标题的一部分（例如 Leo明远 里的 明远）
    $sub = $ini.Substring($s); if ($q[0] -ne $sub[0]) { continue }
    $pos = 0; $ok = $true; foreach ($ch in $sub.ToCharArray()) { $j = $q.IndexOf($ch, $pos); if ($j -lt 0) { $ok = $false; break }; $pos = $j + 1 }
    if ($ok -and $q.Length -le $sub.Length * 6) { return $true }
  }
  $false
}
function Strip-Latin([string]$s) { ($s -replace '^[A-Za-z0-9_.\-\s]+', '' -replace '[A-Za-z0-9_.\-\s]+$', '') }

# —— 名字的来源：会话标题（带最近时间）、群里的发送人（带所在的群）；测试里会替换这个函数 ——
function Get-PeopleSources {
  $chats = @{}; $senders = @{}
  foreach ($m in (Read-Jsonl 'messages.jsonl' 5000)) {
    $c = Unprotect $m.conv; if (-not $c) { continue }; $app = if ($m.app) { [string]$m.app } else { '微信' }; $ts = [string]$m.ts
    $k = "$app|$c"; if (-not $chats[$k] -or $chats[$k].last -lt $ts) { $chats[$k] = @{ app = $app; title = $c; last = $ts } }
    $s = Unprotect $m.sender; if ($s -and $s -notin '我', '对方', '不确定' -and $s -ne $c) { $sk = "$app|$s"; if (-not $senders[$sk] -or $senders[$sk].last -lt $ts) { $senders[$sk] = @{ app = $app; name = $s; group = $c; last = $ts } } }
  }
  foreach ($n in (Get-ConvNames)) { if (-not $chats["微信|$n"]) { $chats["微信|$n"] = @{ app = '微信'; title = $n; last = '' } } }
  @{ chats = @($chats.Values); senders = @($senders.Values) }
}

# —— 认人：返回 @{ status = direct | ask | none; chat = @{app;title}; said; cands = @(@{ app; title; why }) } ——
function Resolve-Person([string]$q, [string]$app = '') {
  $q = ($q -replace '\s', '').Trim(); if (-not $q) { return @{ status = 'none'; said = $q; cands = @() } }
  $src = Get-PeopleSources; $nq = NormName $q
  $chats = @($src.chats | Where-Object { -not $app -or $_.app -eq $app })
  # 1) 会话标题完全一样
  $exact = @($chats | Where-Object { (NormName $_.title) -eq $nq })
  if ($exact.Count -eq 1) { return @{ status = 'direct'; chat = @{ app = $exact[0].app; title = $exact[0].title }; said = $q; why = 'title' } }
  # 2) 用户确认过的称呼（或亲口说过的）
  $hits = @(foreach ($p in Get-People) { if (@($p.aliases | Where-Object { (NormName $_.text) -eq $nq }).Count -and @($p.chats).Count) { $p } })
  if ($hits.Count -eq 1) { $c = @($hits[0].chats | Where-Object { -not $app -or $_.app -eq $app }) | Select-Object -First 1; if ($c) { return @{ status = 'direct'; chat = @{ app = $c.app; title = $c.title }; said = $q; why = 'alias'; person = $hits[0].id } } }
  # 3) 其它：都只是候选，要问
  $cands = New-Object System.Collections.Generic.List[object]
  $add = { param($a, $t, $why, $last) if (-not ($cands | Where-Object { $_.app -eq $a -and $_.title -eq $t })) { $cands.Add(@{ app = $a; title = $t; why = $why; last = [string]$last }) } }
  foreach ($c in $exact) { & $add $c.app $c.title '名字一样' $c.last }
  foreach ($p in $hits) { foreach ($c in $p.chats) { $lc = $chats | Where-Object { $_.app -eq $c.app -and $_.title -eq $c.title } | Select-Object -First 1; & $add $c.app $c.title '确认过的称呼' $(if ($lc) { $lc.last }) } }
  foreach ($c in $chats) {
    $nt = NormName $c.title; $bare = NormName (Strip-Latin $c.title)
    if ($nq.Length -ge 2 -and ($nt.Contains($nq) -or ($nt.Length -ge 2 -and $nq.Contains($nt)))) { & $add $c.app $c.title '名字里有' $c.last; continue }
    if ($bare -and $bare -ne $nt -and ($bare -eq $nq -or ($bare.Length -ge 2 -and $nq.Contains($bare)))) { & $add $c.app $c.title '去掉字母后一样' $c.last; continue }
    if (Test-PinyinLike $q $c.title) { & $add $c.app $c.title '拼音像' $c.last }
  }
  # 群里的发送人：如果他（她）已经连到某个会话，就把那个会话作为候选；否则作为「群里的某人」列出来（不能直接发）
  foreach ($s in $src.senders) {
    $ns = NormName $s.name
    if ($ns -eq $nq -or ($nq.Length -ge 2 -and $ns.Contains($nq)) -or ($ns.Length -ge 2 -and $nq.Contains($ns)) -or (Test-PinyinLike $q $s.name)) {
      $linked = Get-People | Where-Object { @($_.aliases | Where-Object { (NormName $_.text) -eq $ns }).Count } | Select-Object -First 1
      if ($linked -and @($linked.chats).Count) { $c = @($linked.chats)[0]; & $add $c.app $c.title '群里的同一个人' $s.last }
    }
  }
  $list = @($cands | Sort-Object { $_.last } -Descending | Select-Object -First 4)
  @{ status = $(if ($list.Count) { 'ask' } else { 'none' }); said = $q; cands = $list }
}

# —— 记住：用户在选择卡上选了 / 亲口说「X 就是 Y」——
function Find-PersonByChat($people, [string]$app, [string]$title) { $people | Where-Object { @($_.chats | Where-Object { $_.app -eq $app -and (NormName $_.title) -eq (NormName $title) }).Count } | Select-Object -First 1 }
function Add-PersonAlias([string]$app, [string]$title, [string]$alias, [string]$source = 'user_confirmed') {
  $all = @(Get-People); $p = Find-PersonByChat $all $app $title
  if (-not $p) { $p = New-PersonRecord; $p.chats = @([pscustomobject]@{ app = $app; title = $title }); $all += $p }
  if (-not @($p.aliases | Where-Object { (NormName $_.text) -eq (NormName $alias) }).Count -and (NormName $alias) -ne (NormName $title)) {
    $p.aliases = @(@($p.aliases) + [pscustomobject]@{ text = $alias; source = $source; created = (Get-Date).ToString('s') }) }
  $p.not_same = @(@($p.not_same) | Where-Object { (NormName $_) -ne (NormName $alias) })
  Save-People $all; $p.id
}
# 「周明远就是Leo明远」：b 必须对得上一个会话标题（或已有的人）；a 记成称呼
function Set-PeopleSame([string]$a, [string]$b) {
  $src = Get-PeopleSources
  foreach ($pair in @(@($a, $b), @($b, $a))) {
    $c = @($src.chats | Where-Object { (NormName $_.title) -eq (NormName $pair[1]) }) | Select-Object -First 1
    if ($c) { [void](Add-PersonAlias $c.app $c.title $pair[0] 'user_told'); return @{ ok = $true; text = "记住了：$($pair[0]) = $($c.title)" } }
  }
  $r = Resolve-Person $b; if ($r.status -eq 'direct') { [void](Add-PersonAlias $r.chat.app $r.chat.title $a 'user_told'); return @{ ok = $true; text = "记住了：$a = $($r.chat.title)" } }
  @{ ok = $false; text = "没找到叫「$b」或「$a」的聊天，先不记" }
}
# 用户点了「不是」：记下来，不再问
function Set-PeopleNotSame([string]$name, [string]$app, [string]$title) {
  $all = @(Get-People); $p = Find-PersonByChat $all $app $title
  if (-not $p) { $p = New-PersonRecord; $p.chats = @([pscustomobject]@{ app = $app; title = $title }); $all += $p }
  if (-not (@($p.not_same) | Where-Object { (NormName $_) -eq (NormName $name) })) { $p.not_same = @(@($p.not_same) + $name) }
  Save-People $all
}
# AI 发现的「可能是同一个人」：群里的发送人名字 和 某个单聊标题 有至少两个相同的汉字结尾（如 周明远 / Leo明远）；已经连上或说过「不是」的不再提
function Get-PeopleSuggestions {
  $src = Get-PeopleSources; $people = @(Get-People); $out = New-Object System.Collections.Generic.List[object]
  foreach ($s in $src.senders) {
    foreach ($c in $src.chats) {
      if ($c.app -ne $s.app -or (NormName $c.title) -eq (NormName $s.name)) { continue }
      $a = NormName (Strip-Latin $s.name); $b = NormName (Strip-Latin $c.title); if ($a.Length -lt 2 -or $b.Length -lt 2) { continue }
      $tail = 0; while ($tail -lt [Math]::Min($a.Length, $b.Length) -and $a[$a.Length - 1 - $tail] -eq $b[$b.Length - 1 - $tail]) { $tail++ }
      if ($tail -lt 2) { continue }
      $p = Find-PersonByChat $people $c.app $c.title
      if ($p -and (@($p.aliases | Where-Object { (NormName $_.text) -eq (NormName $s.name) }).Count -or @($p.not_same | Where-Object { (NormName $_) -eq (NormName $s.name) }).Count)) { continue }
      if (-not ($out | Where-Object { $_.name -eq $s.name -and $_.title -eq $c.title })) { $out.Add(@{ name = $s.name; group = $s.group; app = $c.app; title = $c.title }) }
    }
  }
  $out.ToArray()   # 不能写 @($out)：List 里装字典时 PowerShell 5.1 会报错
}
# —— 设置 → 记忆 → 人和称呼 ——
function Get-PeoplePage { @{ people = @(Get-People | ForEach-Object { @{ id = $_.id; name = [string]$_.name; chats = @($_.chats); aliases = @($_.aliases | ForEach-Object { @{ text = $_.text; source = $_.source } }) } }); suggestions = @(Get-PeopleSuggestions | Select-Object -First 5) } }
function Remove-PersonAlias([string]$id, [string]$text) { $all = @(Get-People); foreach ($p in $all) { if ($p.id -eq $id) { $p.aliases = @(@($p.aliases) | Where-Object { $_.text -ne $text }) } }; Save-People $all }
function Remove-Person([string]$id) { Save-People @(Get-People | Where-Object { $_.id -ne $id }) }   # 解除：这个人的所有称呼都忘掉（会话本身不受影响）

# —— 迁移：长期记忆里已有的「人」条目，每条连到一个人（不改记忆本身；先备份）——
function Sync-PeopleFromMemory {
  if (-not (Get-Command Get-Memories -ErrorAction SilentlyContinue)) { return 0 }
  $mems = @(Get-Memories | Where-Object { $_.type -eq 'person' }); if (-not $mems.Count) { return 0 }
  if ((Test-Path $script:PeopleFile) -and -not (Test-Path "$script:PeopleFile.bak")) { Copy-Item $script:PeopleFile "$script:PeopleFile.bak" }
  $mf = Join-Path $script:MemDir 'memory.jsonl'; if ((Test-Path $mf) -and -not (Test-Path "$mf.bak-people")) { Copy-Item $mf "$mf.bak-people" }
  $all = @(Get-People); $n = 0
  foreach ($m in $mems) {
    if ($all | Where-Object { @($_.memIds) -contains $m.id }) { continue }
    $nm = @($m.people | Where-Object { $_ }) | Select-Object -First 1; if (-not $nm) { continue }
    $p = $all | Where-Object { $_.name -eq $nm -or @($_.chats | Where-Object { (NormName $_.title) -eq (NormName $nm) }).Count } | Select-Object -First 1
    if (-not $p) { $p = New-PersonRecord; $p.name = [string]$nm; $all += $p }
    $p.memIds = @(@($p.memIds) + $m.id | Select-Object -Unique); $n++
  }
  Save-People $all; $n
}
