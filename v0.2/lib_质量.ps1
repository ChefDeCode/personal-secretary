# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_质量.ps1 — 「先跑一周看准不准」用的本机记录（2026-11-03 起）。全部只在这台电脑上，不上传。
# quality.jsonl：只记类型、编号、时间、结果、计数，不记任何消息文字
#   ev = card     出了一张卡（src = chat 对话卡 / reminder 提醒卡 / today 今天清单的事）
#   ev = outcome  卡上的结果（好的 / 不用 / 不用再提醒 / 稍后 / 撤销 / 自动收掉 …）
#   ev = read     读一次微信：「谁说的」是怎么判断的（各条路的次数）、判断不了的条数
#   ev = visit    点进有未读的聊天：成功没有、切回去没有、因为你动了而中途停下
#   ev = note     你跟秘书说「漏了」「这条不对」「这不是我说的」
#   ev = shadow   影子对比：同一批消息 Haiku 和 Sonnet 各整理出几条、对上几条、各花多少钱（文字另外加密存在 shadow_texts.jsonl）
# quality_daily.txt：每天过了午夜写一行前一天的汇总（只有数字）
# resources.jsonl：每 10 分钟一行资源占用（只有数字）；试运行日志只追加，不截断、不删除
. (Join-Path $PSScriptRoot 'lib_版本.ps1')
function Get-QualFile([string]$name) { $d = if ($script:V2Data) { $script:V2Data } else { Join-Path $PSScriptRoot 'data' }; Join-Path $d $name }
function Write-Quality($rec) {
  $o = [ordered]@{ ts = (Get-Date).ToString('s') }; foreach ($k in $rec.Keys) { $o[$k] = $rec[$k] }
  Add-SecretaryLogLines -Path (Get-QualFile 'quality.jsonl') -Lines @(($o | ConvertTo-Json -Compress -Depth 4))
}
# 不可逆的短编号（聊天、事情）：只用来对比是不是同一个，看不出原文
function Get-QualHash([string]$s) { if (-not $s) { return '' }; ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').Substring(0, 12).ToLower() }

# —— 对话卡：每写一次带卡片的对话行，就记一下这张卡现在的状态（第一次出现 = 出卡，之后状态变了 = 结果）——
$script:QualCardSeen = @{}
function Write-QualityCard($item) {
    $c = $item.card; if (-not $c) { return }
    $id = [string]$item.id; $st = [string]$c.status; $sig = "$st|$([bool]$c.cancelled)|$([bool]$c.failed)"
    if ($script:QualCardSeen[$id] -eq $sig) { return }; $first = -not $script:QualCardSeen.ContainsKey($id)
    $out = if ($c.cancelled) { '不用' } elseif ($c.failed) { '没成' } elseif ($st -in 'sending', 'scheduled') { '好/照做' } elseif ($st -eq 'closed') { '关掉' } else { '' }
    $kind = switch ([string]$c.kind) { 'send' { '替你发' } 'reply' { '需要你回' } 'event' { '带时间的事' } 'question' { '问你' } 'source' { '接入来源' } default { [string]$c.kind } }
    if ($first -and $st -eq 'open') { Write-Quality @{ ev = 'card'; src = 'chat'; id = $id; kind = $kind; created = [string]$item.ts } }
    elseif ($out) { Write-Quality @{ ev = 'outcome'; src = 'chat'; id = $id; kind = $kind; out = $out; created = [string]$item.ts } }
    $script:QualCardSeen[$id] = $sig   # Only mark seen after the append succeeds.
}
# 提醒卡的种类（看编号开头）
function Get-RemKind([string]$id) { switch -Regex ($id) { '^reply\|' { '需要你回(提醒)' } '^wait\|' { '你在等谁' } '^(day|pre2h)\|' { '到期' } '^custom\|' { '你让我提醒的' } '^brief\|' { '早上简报' } '^merge\|' { '合起来的' } default { '其它提醒' } } }

# —— 你跟秘书说漏了 / 不对：记一笔，只回一句 ——
function Get-QualityNoteKind([string]$text) {
  $t = ($text -replace '\s', '')
  if ($t -match '不是我说的|这不是我|我没说') { return '不是我说的' }
  if ($t -match '漏了|没提醒我|怎么没看到|没记下|没整理到|少了一条') { return '漏了' }
  if ($t -match '这条不对|不对吧|搞错了|弄错了|识别错|整理错|这个不对') { return '不对' }
  ''
}

# —— 每天过了午夜：把前一天的数字汇总成一行写进 quality_daily.txt ——
function Write-QualityDaily([datetime]$now = (Get-Date)) {
  $sf = Get-QualFile 'quality_state.json'; $st = $null; try { $st = Get-Content $sf -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
  $last = if ($st -and $st.daily) { [datetime]$st.daily } else { $now.Date.AddDays(-1) }
  if ($last -ge $now.Date.AddDays(-1)) { if (-not $st) { [IO.File]::WriteAllText($sf, (@{ daily = $now.Date.AddDays(-1).ToString('yyyy-MM-dd') } | ConvertTo-Json -Compress)) }; return $null }
  $qf = Get-QualFile 'quality.jsonl'; $all = @(); if (Test-Path $qf) { $all = @(foreach ($l in [IO.File]::ReadLines($qf)) { try { $l | ConvertFrom-Json } catch {} }) }
  $lines = @()
  for ($d = $last.AddDays(1); $d -lt $now.Date; $d = $d.AddDays(1)) {
    $day = @($all | Where-Object { ([string]$_.ts).StartsWith($d.ToString('yyyy-MM-dd')) })
    $cards = @($day | Where-Object ev -eq 'card'); $outs = @($day | Where-Object ev -eq 'outcome')
    # 一天前出的卡，到现在还没有任何结果 = 放了 24 小时没人管
    $prev = @($all | Where-Object { $_.ev -eq 'card' -and ([string]$_.ts).StartsWith($d.AddDays(-1).ToString('yyyy-MM-dd')) })
    $doneIds = @{}; foreach ($o in @($all | Where-Object ev -eq 'outcome')) { $doneIds[[string]$o.id] = $true }
    $untouched = @($prev | Where-Object { -not $doneIds[[string]$_.id] }).Count
    $grp = { param($xs, $f) (($xs | Group-Object $f | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ') }
    $reads = @($day | Where-Object ev -eq 'read'); $spk = @{}; $unk = 0; foreach ($r in $reads) { $unk += [int]$r.unknown; foreach ($p in @($r.paths.PSObject.Properties)) { $spk[$p.Name] = [int]$spk[$p.Name] + [int]$p.Value } }
    $vis = @($day | Where-Object ev -eq 'visit'); $sh = @($day | Where-Object ev -eq 'shadow')
    $lines += "$($d.ToString('yyyy-MM-dd')) | 出卡 $($cards.Count)（$(& $grp $cards 'kind')） | 结果 $($outs.Count)（$(& $grp $outs 'out')） | 放了 24 小时没人管（前一天的卡）$untouched" +
      " | 自动收掉（回过了）$(@($outs | Where-Object { $_.out -eq '自动收掉' -and $_.replied }).Count)，被你撤销 $(@($outs | Where-Object out -eq '撤销自动收掉').Count)" +
      " | 读微信 $($reads.Count) 次，谁说的：$((($spk.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))，判断不了 $unk 条" +
      " | 点进未读 $($vis.Count)（成功 $(@($vis | Where-Object ok).Count)，切回 $(@($vis | Where-Object back).Count)，你动了停下 $(@($vis | Where-Object aborted).Count)）" +
      " | 你说漏了/不对 $(@($day | Where-Object ev -eq 'note').Count)（$(& $grp @($day | Where-Object ev -eq 'note') 'kind')）" +
      " | 影子对比 $($sh.Count) 批：对上 $(($sh | Measure-Object matched -Sum).Sum)，同一件事分类不同 $(($sh | Measure-Object type_diff -Sum).Sum)，只有 Sonnet $(($sh | Measure-Object sonnet_only -Sum).Sum)，只有 Haiku $(($sh | Measure-Object haiku_only -Sum).Sum)，Haiku 花 `$$([Math]::Round(($sh | Measure-Object haiku_cost -Sum).Sum, 4))"
  }
  if ($lines.Count) { Add-SecretaryLogLines -Path (Get-QualFile 'quality_daily.txt') -Lines ([string[]]$lines) }
  [IO.File]::WriteAllText($sf, (@{ daily = $now.Date.AddDays(-1).ToString('yyyy-MM-dd') } | ConvertTo-Json -Compress)); $lines
}

# —— 资源占用：每 10 分钟一行（秘书、值守、边缘线、界面背后的浏览器进程合计），加上透明读和值守每一步的用时 ——
if (-not ('QualGui' -as [type])) { Add-Type 'using System; using System.Runtime.InteropServices; public static class QualGui { [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr h, uint f); }' }
$script:ResPrev = @{}; $script:ResPrevAt = $null
function Get-SecretaryProcs {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $roles = @{}; foreach ($p in $all) { $c = [string]$p.CommandLine
    if ($p.Name -eq '秘书.exe') { $roles[[int]$p.ProcessId] = 'exe' } elseif ($p.Name -eq 'powershell.exe' -and $c -match 'v0\.2\\秘书\.ps1') { $roles[[int]$p.ProcessId] = 'main' } elseif ($p.Name -eq 'powershell.exe' -and $c -match '12_值守') { $roles[[int]$p.ProcessId] = 'watcher' } elseif ($p.Name -eq 'powershell.exe' -and $c -match '边缘线') { $roles[[int]$p.ProcessId] = 'edgeline' } }
  $q = New-Object System.Collections.Queue; foreach ($k in @($roles.Keys)) { $q.Enqueue($k) }
  while ($q.Count) { $pp = $q.Dequeue(); foreach ($c in @($all | Where-Object { $_.ParentProcessId -eq $pp -and $_.Name -eq 'msedgewebview2.exe' })) { if (-not $roles.ContainsKey([int]$c.ProcessId)) { $roles[[int]$c.ProcessId] = 'webview2'; $q.Enqueue([int]$c.ProcessId) } } }
  $roles
}
function Write-ResourceSample($extra) {
  $roles = Get-SecretaryProcs; $now = Get-Date; $n = [Environment]::ProcessorCount; $agg = [ordered]@{}
  foreach ($kv in $roles.GetEnumerator()) { $p = Get-Process -Id $kv.Key -ErrorAction SilentlyContinue; if (-not $p) { continue }; $r = $kv.Value
    if (-not $agg.Contains($r)) { $agg[$r] = [ordered]@{ n = 0; cpu = 0.0; priv_mb = 0; handles = 0; gdi = 0; user = 0; threads = 0 } }
    $a = $agg[$r]; $a.n++; $cpuMs = $p.TotalProcessorTime.TotalMilliseconds
    if ($script:ResPrevAt -and $script:ResPrev.ContainsKey($kv.Key)) { $a.cpu += [Math]::Round(($cpuMs - $script:ResPrev[$kv.Key]) / ($now - $script:ResPrevAt).TotalMilliseconds / $n * 100, 2) }
    $script:ResPrev[$kv.Key] = $cpuMs; $a.priv_mb += [int]($p.PrivateMemorySize64 / 1MB); $a.handles += $p.HandleCount; $a.threads += $p.Threads.Count
    try { $a.gdi += [QualGui]::GetGuiResources($p.Handle, 0); $a.user += [QualGui]::GetGuiResources($p.Handle, 1) } catch {} }
  $script:ResPrevAt = $now
  $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
  $rec = [ordered]@{ ts = $now.ToString('s'); procs = $agg; power = $(if ($b) { if ($b.BatteryStatus -eq 2) { 'ac' } else { 'battery' } } else { 'ac' }); battery = $(if ($b) { [int]$b.EstimatedChargeRemaining } else { $null }) }
  if ($extra) { foreach ($k in $extra.Keys) { $rec[$k] = $extra[$k] } }
  Add-SecretaryLogLines -Path (Get-QualFile 'resources.jsonl') -Lines @(($rec | ConvertTo-Json -Compress -Depth 5))
  $rec
}
# 一串毫秒数 → 中位数 / 95% / 最大 / 次数
function Get-MsStats($xs) { $a = @($xs | Sort-Object); if (-not $a.Count) { return @{ n = 0 } }; @{ n = $a.Count; p50 = $a[[int][Math]::Floor(($a.Count - 1) * 0.5)]; p95 = $a[[int][Math]::Floor(($a.Count - 1) * 0.95)]; max = $a[-1] } }

# —— Haiku 影子对比：同一批消息，Sonnet 照常整理（结果照常用），另外在后台让 Haiku 也整理一遍，只拿来比，不出卡、不显示、不做任何事 ——
# 一天最多花 $0.30（到了就当天停）；不拖慢正常的整理：在单独的后台线程里跑，正常流程不等它
$script:ShadowCapUsd = 0.30; $script:ShadowJobs = New-Object System.Collections.ArrayList
$script:ShadowPrice = @{ sonnet_in = 2.0; sonnet_out = 10.0; haiku_in = 0.10; haiku_out = 0.50 }   # 每百万 tokens（Haiku 5.5：提示不超过 10 万 tokens 时的价格）
function Get-ShadowSpent { $f = Get-QualFile 'shadow_state.json'; try { $s = Get-Content $f -Raw -ErrorAction Stop | ConvertFrom-Json; if ($s.date -eq (Get-Date).ToString('yyyy-MM-dd')) { return [double]$s.cost } } catch {}; 0.0 }
function Add-ShadowSpent([double]$c) { $f = Get-QualFile 'shadow_state.json'; $now = Get-Date; $v = (Get-ShadowSpent) + $c; [IO.File]::WriteAllText($f, (@{ date = $now.ToString('yyyy-MM-dd'); cost = [Math]::Round($v, 5) } | ConvertTo-Json -Compress)) }
function Start-HaikuShadow([string]$reqJson, $sonnetItems, [string]$conv, $sonnetUsage, [string]$key) {
  if ((Get-ShadowSpent) -ge $script:ShadowCapUsd) { return 'cap' }
  if (@($script:ShadowJobs | Where-Object { -not $_.h.IsCompleted }).Count -ge 2) { return 'busy' }   # 最多同时两批，不堆积
  $h = $reqJson -replace '"model":"claude-sonnet-5-5"', '"model":"claude-haiku-5-5"' -replace ',"fallbacks":"default"', '' -replace '"fallbacks":"default",', '' -replace '"max_tokens":4000', '"max_tokens":8000'
  $ps = [PowerShell]::Create(); [void]$ps.AddScript({ param($body, $k)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $r = Invoke-WebRequest -Uri 'https://api.anthropic.com/v1/messages' -Method Post -UseBasicParsing -TimeoutSec 120 -Headers @{ 'x-api-key' = $k; 'anthropic-version' = '2023-06-01' } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
      $j = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
      $items = @(); if ($j.stop_reason -ne 'refusal') { try { $items = @(((($j.content | Where-Object type -eq 'text' | ForEach-Object text) -join '') | ConvertFrom-Json).items) } catch {} }
      @{ ok = $true; items = $items; in = [int]$j.usage.input_tokens; out = [int]$j.usage.output_tokens; stop = [string]$j.stop_reason }
    } catch { $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }; @{ ok = $false; code = $code } } }).AddArgument($h).AddArgument($key)
  [void]$script:ShadowJobs.Add(@{ ps = $ps; h = $ps.BeginInvoke(); sonnet = @($sonnetItems); conv = $conv; su = $sonnetUsage; at = Get-Date }); 'started'
}
# 两条对不对得上：同一类，事情的字（两两一组）重合得够多
function Get-Bigrams([string]$s) { $s = ($s -replace '[\s，。、！？,.!?：:；;「」“”"''（）()]', '').ToLower(); $set = @{}; for ($i = 0; $i -lt $s.Length - 1; $i++) { $set[$s.Substring($i, 2)] = $true }; if ($s.Length -eq 1) { $set[$s] = $true }; $set }
function Test-SameItem($a, $b, [switch]$AnyType) {
  if (-not $AnyType -and [string]$a.类别 -ne [string]$b.类别) { return $false }
  $x = Get-Bigrams ([string]$a.事情); $y = Get-Bigrams ([string]$b.事情); if (-not $x.Count -or -not $y.Count) { return $false }
  $inter = @($x.Keys | Where-Object { $y.ContainsKey($_) }).Count; ($inter / [double]($x.Count + $y.Count - $inter)) -ge 0.35
}
function Compare-ShadowItems($sonnet, $haiku) {
  $used = @{}; $pairs = 0; $sOnly = @()
  foreach ($s in @($sonnet)) { $hit = $false; for ($i = 0; $i -lt @($haiku).Count; $i++) { if (-not $used[$i] -and (Test-SameItem $s @($haiku)[$i])) { $used[$i] = $true; $hit = $true; $pairs++; break } }; if (-not $hit) { $sOnly += $s } }
  # 第二遍：剩下的里面，说的是同一件事、但分到了不同的类（比如一个说「你答应的」、一个说「有截止时间的」）
  $typeDiff = 0; $sLeft = @(); foreach ($s in @($sOnly)) { $hit = $false; for ($i = 0; $i -lt @($haiku).Count; $i++) { if (-not $used[$i] -and (Test-SameItem $s @($haiku)[$i] -AnyType)) { $used[$i] = $true; $hit = $true; $typeDiff++; break } }; if (-not $hit) { $sLeft += $s } }
  $hOnly = @(for ($i = 0; $i -lt @($haiku).Count; $i++) { if (-not $used[$i]) { @($haiku)[$i] } })
  @{ matched = $pairs; type_diff = $typeDiff; sonnet_only = $sLeft; haiku_only = $hOnly }
}
# 收结果（值守每一轮调一次，不等）：写对比记录；两边对不上的条目文字加密存下来，一周后给你看例子（不会自动删）
function Receive-HaikuShadow([scriptblock]$Protect) {
  foreach ($jb in @($script:ShadowJobs)) {
    if (-not $jb.h.IsCompleted) { if (((Get-Date) - $jb.at).TotalMinutes -gt 5) { try { $jb.ps.Stop() } catch {}; $jb.ps.Dispose(); $script:ShadowJobs.Remove($jb); Write-Quality @{ ev = 'shadow_error'; why = 'timeout' } }; continue }
    $r = $null; try { $r = @($jb.ps.EndInvoke($jb.h))[0] } catch {}; $jb.ps.Dispose(); $script:ShadowJobs.Remove($jb)
    if (-not $r -or -not $r.ok) { Write-Quality @{ ev = 'shadow_error'; why = $(if ($r) { "http $($r.code)" } else { 'no result' }) }; continue }
    $hc = ($r.in * $script:ShadowPrice.haiku_in + $r.out * $script:ShadowPrice.haiku_out) / 1e6; Add-ShadowSpent $hc
    $sc = ([int]$jb.su.input_tokens * $script:ShadowPrice.sonnet_in + [int]$jb.su.output_tokens * $script:ShadowPrice.sonnet_out) / 1e6
    $cmp = Compare-ShadowItems $jb.sonnet $r.items; $bid = [guid]::NewGuid().ToString('n').Substring(0, 10); $chat = Get-QualHash $jb.conv
    $brief = { param($x) [ordered]@{ t = [string]$x.类别; k = Get-QualHash (([string]$x.事情 -replace '\s', '').ToLower()) } }
    Write-Quality @{ ev = 'shadow'; batch = $bid; chat = $chat; bucket = $jb.at.ToString('yyyy-MM-dd HH'); sonnet = @($jb.sonnet | ForEach-Object { & $brief $_ }); haiku = @($r.items | ForEach-Object { & $brief $_ })
      matched = $cmp.matched; type_diff = $cmp.type_diff; sonnet_only = @($cmp.sonnet_only).Count; haiku_only = @($cmp.haiku_only).Count; stop = $r.stop
      sonnet_tokens = @{ in = [int]$jb.su.input_tokens; out = [int]$jb.su.output_tokens }; haiku_tokens = @{ in = $r.in; out = $r.out }; sonnet_cost = [Math]::Round($sc, 5); haiku_cost = [Math]::Round($hc, 5) }
    $txt = @(foreach ($x in @($cmp.sonnet_only)) { & $Protect (([ordered]@{ batch = $bid; who = 'sonnet_only'; 类别 = $x.类别; 谁 = $x.谁; 事情 = $x.事情; 截止 = $x.截止 } | ConvertTo-Json -Compress)) }) + @(foreach ($x in @($cmp.haiku_only)) { & $Protect (([ordered]@{ batch = $bid; who = 'haiku_only'; 类别 = $x.类别; 谁 = $x.谁; 事情 = $x.事情; 截止 = $x.截止 } | ConvertTo-Json -Compress)) })
    if ($txt.Count) { Add-SecretaryLogLines -Path (Get-QualFile 'shadow_texts.jsonl') -Lines ([string[]]$txt) }
  }
}
