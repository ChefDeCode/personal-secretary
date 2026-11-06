# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 一周质量记录（lib_质量.ps1）：出卡 / 结果记对了、不记任何消息文字、你说「漏了」记一笔、每天汇总一行、影子对比怎么算、资源占用一行。
# 全在临时文件夹，虚构内容；不调用任何模型（影子对比用假的结果）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
$T = Join-Path $env:TEMP 'secretary_quality'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null; $script:V2Data = $T
. "$v2\lib_质量.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
function Q { @(if (Test-Path "$T\quality.jsonl") { Get-Content "$T\quality.jsonl" -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } }) }
$secret = '示例秘密内容-不应出现在记录里'
# 1) 对话卡：出卡 → 点了 → 再写一次同样的状态不重复记
$item = [pscustomobject]@{ id = 'c1'; ts = (Get-Date).AddMinutes(-5).ToString('s'); text = $secret; card = [pscustomobject]@{ kind = 'send'; status = 'open'; cancelled = $false; failed = $false; draft = $secret } }
Write-QualityCard $item; Write-QualityCard $item
$item.card.status = 'sending'; Write-QualityCard $item
$i2 = [pscustomobject]@{ id = 'c2'; ts = (Get-Date).ToString('s'); card = [pscustomobject]@{ kind = 'question'; status = 'open'; cancelled = $false; failed = $false } }; Write-QualityCard $i2; $i2.card.cancelled = $true; $i2.card.status = 'closed'; Write-QualityCard $i2
$q = Q; Check "chat card: shown once, then 好/照做 ($(@($q | Where-Object id -eq 'c1').Count) lines)" (@($q | Where-Object { $_.id -eq 'c1' -and $_.ev -eq 'card' }).Count -eq 1 -and @($q | Where-Object { $_.id -eq 'c1' -and $_.out -eq '好/照做' }).Count -eq 1)
Check 'question card dismissed -> 不用' (@($q | Where-Object { $_.id -eq 'c2' -and $_.out -eq '不用' -and $_.kind -eq '问你' }).Count -eq 1)
Check 'no message text is ever written to the quality log' (-not ([IO.File]::ReadAllText("$T\quality.jsonl")).Contains($secret))
# 2) 你说漏了 / 不对
Check "feedback words are recognised (漏了 / 这条不对 / 这不是我说的 / normal text)" ((Get-QualityNoteKind '漏了一条') -eq '漏了' -and (Get-QualityNoteKind '这条不对') -eq '不对' -and (Get-QualityNoteKind '这不是我说的') -eq '不是我说的' -and (Get-QualityNoteKind '帮我给文件传输助手发消息') -eq '')
# 3) 影子对比怎么算对上
$s = @([pscustomobject]@{ 类别 = '需要你回的'; 事情 = '回复对方关于周五开会的时间' }, [pscustomobject]@{ 类别 = '你在等谁'; 事情 = '等对方交周报' })
$h = @([pscustomobject]@{ 类别 = '需要你回的'; 事情 = '回复周五开会时间' }, [pscustomobject]@{ 类别 = '你答应别人的'; 事情 = '明天带书' }, [pscustomobject]@{ 类别 = '有截止时间的'; 事情 = '等对方交周报' })
$c = Compare-ShadowItems $s $h; Check "same type + similar wording = same item; same wording, other type = counted apart (matched $($c.matched), type differs $($c.type_diff), Sonnet-only $(@($c.sonnet_only).Count), Haiku-only $(@($c.haiku_only).Count))" ($c.matched -eq 1 -and $c.type_diff -eq 1 -and @($c.sonnet_only).Count -eq 0 -and @($c.haiku_only).Count -eq 1)
# 4) 收影子结果：记数字和花费；对不上的条目文字加密另存；今天花到 $0.30 就停
$ps = [PowerShell]::Create(); [void]$ps.AddScript({ @{ ok = $true; items = @([pscustomobject]@{ 类别 = '需要你回的'; 事情 = '回复周五开会时间'; 谁 = 'x'; 截止 = '' }, [pscustomobject]@{ 类别 = '你答应别人的'; 事情 = '明天带书'; 谁 = 'x'; 截止 = '' }); in = 10000; out = 2000; stop = 'end_turn' } })
[void]$script:ShadowJobs.Add(@{ ps = $ps; h = $ps.BeginInvoke(); sonnet = $s; conv = 'chat-a'; su = [pscustomobject]@{ input_tokens = 10000; output_tokens = 1500 }; at = Get-Date }); Start-Sleep -Milliseconds 500
Receive-HaikuShadow { param($x) 'ENC:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($x)) }
$sh = @(Q | Where-Object ev -eq 'shadow')[0]
Check "shadow record: matched $($sh.matched) / Sonnet-only $($sh.sonnet_only) / Haiku-only $($sh.haiku_only); Haiku `$$($sh.haiku_cost), Sonnet `$$($sh.sonnet_cost)" ($sh.matched -eq 1 -and $sh.sonnet_only -eq 1 -and $sh.haiku_only -eq 1 -and [Math]::Abs($sh.haiku_cost - 0.002) -lt 1e-6 -and [Math]::Abs($sh.sonnet_cost - 0.035) -lt 1e-6)
Check 'the chat is stored only as a short hash' ($sh.chat.Length -eq 12 -and $sh.chat -ne 'chat-a')
$tx = @(Get-Content "$T\shadow_texts.jsonl"); Check "the two unmatched items are kept, encrypted ($($tx.Count))" ($tx.Count -eq 2 -and -not ($tx -join '').Contains('明天带书'))
Check "today's shadow spend is tracked (`$$(Get-ShadowSpent))" ([Math]::Abs((Get-ShadowSpent) - 0.002) -lt 1e-6)
Add-ShadowSpent 0.30; Check 'over $0.30 today -> no more shadow calls today' ((Start-HaikuShadow '{}' @() 'c' $null 'k') -eq 'cap')
# 5) 每天汇总：前一天一行；再调一次不重复
Remove-Item "$T\quality.jsonl"; $y = (Get-Date).Date.AddDays(-1); $yy = (Get-Date).Date.AddDays(-2)
$lines = @(
  (@{ ts = $yy.AddHours(10).ToString('s'); ev = 'card'; src = 'today'; id = 'old1'; kind = '需要你回的' } | ConvertTo-Json -Compress),
  (@{ ts = $y.AddHours(9).ToString('s'); ev = 'card'; src = 'reminder'; id = 'r1'; kind = '你在等谁' } | ConvertTo-Json -Compress),
  (@{ ts = $y.AddHours(9.5).ToString('s'); ev = 'outcome'; src = 'reminder'; id = 'r1'; out = '好的' } | ConvertTo-Json -Compress),
  (@{ ts = $y.AddHours(11).ToString('s'); ev = 'outcome'; src = 'today'; id = 't9'; out = '自动收掉'; replied = $true } | ConvertTo-Json -Compress),
  (@{ ts = $y.AddHours(12).ToString('s'); ev = 'read'; unknown = 2; paths = @{ 'bubble+colour' = 10; conflict = 2 } } | ConvertTo-Json -Compress),
  (@{ ts = $y.AddHours(13).ToString('s'); ev = 'visit'; ok = $true; back = $true; aborted = $false } | ConvertTo-Json -Compress),
  (@{ ts = $y.AddHours(14).ToString('s'); ev = 'note'; kind = '漏了' } | ConvertTo-Json -Compress))
[IO.File]::WriteAllLines("$T\quality.jsonl", [string[]]$lines)
[IO.File]::WriteAllText("$T\quality_state.json", (@{ daily = $yy.AddDays(-1).ToString('yyyy-MM-dd') } | ConvertTo-Json -Compress))
$d = @(Write-QualityDaily); $txt = [IO.File]::ReadAllText("$T\quality_daily.txt")
Check "one counts-only line per missed day ($($d.Count) lines)" ($d.Count -eq 2)
$ln = @($d | Where-Object { $_.StartsWith($y.ToString('yyyy-MM-dd')) })[0]
Check 'yesterday: 1 card, 1 outcome 好的, 1 auto-cleared, 12 speaker lines with 2 unknown, 1 visit, 1 note' ($ln -match '出卡 1' -and $ln -match '好的=1' -and $ln -match '自动收掉（回过了）1' -and $ln -match '判断不了 2' -and $ln -match '点进未读 1（成功 1' -and $ln -match '漏了=1')
Check "a card left alone for 24 hours is counted ($([regex]::Match($ln, '没人管（前一天的卡）\d+').Value))" ($ln -match '没人管（前一天的卡）1')
$n0 = (Get-Content "$T\quality_daily.txt").Count; [void](Write-QualityDaily); Check 'calling it again the same day adds nothing' ((Get-Content "$T\quality_daily.txt").Count -eq $n0)
# 6) 资源占用一行（秘书在跑的话能看到它的几个程序）
function Get-SecretaryProcs { @{} }; function Get-CimInstance { @() }
$r = Write-ResourceSample @{ ghost_reads = 3 }; Check "resource line written (processes seen: $(@($r.procs.Keys) -join ', '); power $($r.power))" ((Test-Path "$T\resources.jsonl") -and $r.ghost_reads -eq 3 -and $r.power)
Check "stage timing stats (p50 / p95 / max)" ((Get-MsStats @(100, 200, 300, 400, 2600)).max -eq 2600 -and (Get-MsStats @(100, 200, 300)).p50 -eq 200)
# 7) 接上了：值守和秘书都加载了这个记录
$w = [IO.File]::ReadAllText((Join-Path (Split-Path $v2 -Parent) '12_值守.ps1')); $l2 = [IO.File]::ReadAllText("$v2\lib_v2.ps1"); $sec = [IO.File]::ReadAllText("$v2\秘书.ps1"); $rem = [IO.File]::ReadAllText("$v2\lib_提醒.ps1")
Check 'wired in: watcher (reads, visits, stages, shadow, tick), chat cards, today items, reminders, notes, auto-clear' ($w -match 'lib_质量\.ps1' -and $w -match "ev = 'read'" -and $w -match "ev = 'visit'" -and $w -match 'Start-HaikuShadow' -and $w -match 'Write-QualityTick' -and $w -match "src\s*=\s*'today'" -and $l2 -match 'Write-QualityCard' -and $rem -match "src = 'reminder'" -and $sec -match 'Get-QualityNoteKind' -and $sec -match "out\s*=\s*'自动收掉'")
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"quality_test: $pass pass, $fail fail"

if($fail){exit 1}