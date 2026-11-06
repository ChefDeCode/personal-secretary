# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 整理队列只读消息存档新增的部分（2026-11-05）：不重复、不漏、重启中途不出错；记号坏了 / 存档换了才从头扫一遍并记下来；锁占用时间改前改后对比
# 全在临时文件夹，虚构的消息（只有编号，没有内容）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$T = Join-Path $env:TEMP ('secretary_qinc_' + [guid]::NewGuid().ToString('n').Substring(0, 6)); New-Item -ItemType Directory -Force "$T\data", "$T\v2" | Out-Null
. "$v2\lib_整理队列.ps1"
$journal = "$T\data\messages.jsonl"
function Msg([int]$i) { ([ordered]@{ ts = (Get-Date).AddMinutes(-5000 + $i).ToString('s'); app = '微信'; conv_key = 'c' + ($i % 7); key = 'k' + $i; sender = 's'; text = 't'; baseline = $false } | ConvertTo-Json -Compress) }
function Pending { @(Get-PendingQueueMessages).Count }
function IndexLines { @([IO.File]::ReadAllLines("$T\data\extract_queue\journal_ids.txt") | Where-Object { $_ }).Count }
function Restart { $script:JournalIdSet = $null; $script:JournalIdxBytes = 0L; $script:QueueSynced = $false; $script:QueueJournalStamp = ''; Initialize-ExtractQueue "$T\data" "$T\v2" }
function Rescans { if (Test-Path "$T\data\extract_queue\rescans.jsonl") { @(Get-Content "$T\data\extract_queue\rescans.jsonl" | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
Initialize-ExtractQueue "$T\data" "$T\v2"
# 1) 空存档
Check "empty archive: nothing pending, no rescan logged ($(Pending) pending, $(@(Rescans).Count) rescans)" ((Pending) -eq 0 -and @(Rescans).Count -eq 0)
# 2) 2500 条
[IO.File]::WriteAllLines($journal, [string[]](1..2500 | ForEach-Object { Msg $_ })); $script:QueueSynced = $false
$sw = [Diagnostics.Stopwatch]::StartNew(); $n = Pending; $first = $sw.ElapsedMilliseconds
Check "2500 archived messages are all queued once ($n pending, index $(IndexLines))" ($n -eq 2500 -and (IndexLines) -eq 2500)
$m = [IO.File]::ReadAllText("$T\data\extract_queue\journal_mark.json") | ConvertFrom-Json
Check "the mark points at the end of the archive ($($m.offset) of $((Get-Item $journal).Length) bytes)" ([long]$m.offset -eq (Get-Item $journal).Length)
# 3) 加一条：只读新的那一行；和旧代码比锁占用时间
$script:QueueLockMs.Clear(); Add-PersistentMessages @((Msg 2501 | ConvertFrom-Json)); $newMs = @($script:QueueLockMs)[-1]
Check "adding one message reads only the new line ($(Pending) pending; lock held $newMs ms)" ((Pending) -eq 2501 -and (IndexLines) -eq 2501)
$oldLib = Join-Path (Split-Path $v2 -Parent) '旧东西\备份文件\v0.2__lib_整理队列.ps1.bak_incremental'
if (Test-Path $oldLib) {
  # 同样 2500 条、同样加一条，用改之前的代码量一下锁占用时间
  $O = Join-Path $env:TEMP ('secretary_qold_' + [guid]::NewGuid().ToString('n').Substring(0, 6)); New-Item -ItemType Directory -Force "$O\data", "$O\v2" | Out-Null
  [IO.File]::WriteAllLines("$O\data\messages.jsonl", [string[]](1..2500 | ForEach-Object { Msg $_ })); [IO.File]::WriteAllText("$O\one.json", (Msg 2501))
  Copy-Item $oldLib "$O\old_queue.ps1"
  [IO.File]::WriteAllText("$O\time_old.ps1", ('. "' + "$O\old_queue.ps1" + '"; Initialize-ExtractQueue "' + "$O\data" + '" "' + "$O\v2" + '"; [void]@(Get-PendingQueueMessages); $sw = [Diagnostics.Stopwatch]::StartNew(); Add-PersistentMessages @(([IO.File]::ReadAllText("' + "$O\one.json" + '") | ConvertFrom-Json)); $sw.ElapsedMilliseconds'), (New-Object Text.UTF8Encoding $true))
  $oldMs = [int](@(& powershell -NoProfile -ExecutionPolicy Bypass -File "$O\time_old.ps1" 2>$null) | Select-Object -Last 1)
  Remove-Item $O -Recurse -Force -ErrorAction SilentlyContinue
  Check "lock hold for one new message with 2500 archived: before $oldMs ms -> after $newMs ms" ($oldMs -gt 0 -and [int]$newMs -lt $oldMs)
}# 4) 最后半行还没写完：不读；写完了才读，而且只读一次
$fs = [IO.File]::Open($journal, 'Append'); $half = [Text.Encoding]::UTF8.GetBytes((Msg 2502).Substring(0, 30)); $fs.Write($half, 0, $half.Length); $fs.Dispose(); $script:QueueSynced = $false
Check "a half-written last line is left for later ($(Pending) pending)" ((Pending) -eq 2501)
$fs = [IO.File]::Open($journal, 'Append'); $rest = [Text.Encoding]::UTF8.GetBytes((Msg 2502).Substring(30) + "`n"); $fs.Write($rest, 0, $rest.Length); $fs.Dispose(); $script:QueueSynced = $false
Check "once the line is complete it is read exactly once ($(Pending) pending, index $(IndexLines))" ((Pending) -eq 2502 -and (IndexLines) -eq 2502)
# 5) 中途重启：内存里的都没了，靠硬盘上的记号接着读；再存一条旧的（重复）和两条新的
Restart; Add-PersistentMessages @((Msg 100 | ConvertFrom-Json), (Msg 2503 | ConvertFrom-Json), (Msg 2504 | ConvertFrom-Json))
$keys = @([IO.File]::ReadAllLines($journal) | Where-Object { $_.Trim() } | ForEach-Object { ($_ | ConvertFrom-Json).key })
Check "after a restart: the old message is not written twice, the two new ones are added ($($keys.Count) lines, $(@($keys | Sort-Object -Unique).Count) unique, $(Pending) pending)" ($keys.Count -eq @($keys | Sort-Object -Unique).Count -and (Pending) -eq 2504 -and @(Rescans).Count -eq 0)
# 6) 记号坏了：从头扫一遍并记下原因；不重复、不漏
[IO.File]::WriteAllText("$T\data\extract_queue\journal_mark.json", '{broken'); Restart; $p6 = Pending
Check "corrupted mark -> one full rescan, logged as $(@(Rescans)[-1].why); still $p6 pending, index $(IndexLines) unique" ($p6 -eq 2504 -and (IndexLines) -eq 2504 -and @(Rescans)[-1].why -eq 'mark_corrupt')
# 7) 存档被换掉（开头不一样了）：从头扫，并记下来
$all = [IO.File]::ReadAllLines($journal); [IO.File]::WriteAllLines($journal, [string[]](@((Msg 9999)) + $all)); $script:QueueSynced = $false; $p7 = Pending
Check "archive replaced (start changed) -> rescan logged as $(@(Rescans)[-1].why); the extra message is added once ($p7 pending)" (@(Rescans)[-1].why -eq 'archive_replaced' -and $p7 -eq 2505 -and (IndexLines) -eq 2505)
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"queue_incremental_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
