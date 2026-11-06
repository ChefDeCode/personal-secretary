# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 纯合成数据：不运行主程序，不调用 UI，不联网，不读取真实消息。
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $codeRoot = Split-Path $v2 -Parent
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "[$(if ($ok) { 'PASS' } else { 'FAIL' })] $name" }
$testTempRoot = Join-Path $codeRoot 'review\test-scratch'; [void][IO.Directory]::CreateDirectory($testTempRoot)
$temp = Join-Path $testTempRoot ('secretary_queue_' + [guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($temp)
$script:QueueWorker = $null
try {
  $root = $temp; $data = Join-Path $temp 'data'; $script:V2Data = Join-Path $temp 'v0.2\data'
  [void][IO.Directory]::CreateDirectory($data); [void][IO.Directory]::CreateDirectory($script:V2Data)
  Copy-Item -LiteralPath (Join-Path $codeRoot '12_值守.ps1') -Destination (Join-Path $temp '12_值守.ps1')
  foreach ($lib in 'lib_整理队列.ps1', 'lib_质量.ps1', 'lib_事项.ps1', 'lib_提醒.ps1', 'lib_版本.ps1') { Copy-Item -LiteralPath (Join-Path $v2 $lib) -Destination (Join-Path $temp ('v0.2\' + $lib)) }
  [IO.File]::WriteAllText((Join-Path $temp 'config.json'), '{"features":{"today_list":true},"permissions":{"cloud_text":false}}', [Text.UTF8Encoding]::new($false))
  Add-Type -AssemblyName System.Security
  $entropy = [Text.Encoding]::UTF8.GetBytes('secretary-v0.1')
  function Protect([string]$s) { [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($s), $entropy, 'CurrentUser')) }
  function Unprotect([string]$s) { [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($s), $entropy, 'CurrentUser')) }
  function Get-Feature([string]$name) { $name -eq 'today_list' }
  function Get-Permission { $false }
  function Write-Quality { }
  $stats = @{ 错误 = 0; 提取批次 = 0; 提取条目 = 0; 需要你回的 = 0; 你答应别人的 = 0; 有截止时间的 = 0; 你在等谁 = 0 }
  $script:lastExtract = [datetime]::MinValue; $script:FeatDefaults = @{ today_list = $true }; $script:PermDefaults = @{ cloud_text = $false }
  . (Join-Path $v2 'lib_整理队列.ps1'); Initialize-ExtractQueue $data $script:V2Data
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $codeRoot '12_值守.ps1'), [ref]$null, [ref]$null)
  foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Extract-Todos', 'Start-QueueWorker', 'Step-QueueWorker', 'Invoke-LocalRules', 'Repair-TodoSpeaker', 'Get-SpeakerCode', 'Save-Messages' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
  function FakeMessage([string]$key, [string]$app = '微信', [bool]$baseline = $false) {
    [pscustomobject]@{ key = $key; app = $app; conv_key = 'synthetic-conversation'; conv = (Protect '合成会话'); sender = (Protect '合成发送者'); text = (Protect ('请检查合成文件 ' + $key + '？')); shown = ''; ts = (Get-Date).ToString('s'); baseline = $baseline }
  }
  $records = @('微信', 'Outlook', '文件', '插件' | ForEach-Object { FakeMessage 'same-source-key' $_ })
  Add-PersistentMessages $records
  Check 'all sources share durable queue without identity collision' (@(Get-PendingQueueMessages).Count -eq 4)
  Add-PersistentMessages $records
  Check 'same source delivery is idempotent' (@(Get-QueueJsonLines (Join-Path $data 'messages.jsonl')).Count -eq 4)
  Extract-Todos -Force
  Check 'non-WeChat work completes independently of screen changes' (@(Get-QueueJsonLines (Join-Path $data 'todos.jsonl')).Count -eq 4 -and @(Get-PendingQueueMessages).Count -eq 0)
  $bytes = [IO.File]::ReadAllBytes((Join-Path $data 'messages.jsonl'))
  Initialize-ExtractQueue $data $script:V2Data; Extract-Todos -Force
  Check 'restart does not duplicate successful effects' (@(Get-QueueJsonLines (Join-Path $data 'todos.jsonl')).Count -eq 4)
  Check 'source journal stays byte-identical after restart' ([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $data 'messages.jsonl'))))
  $baseRecord = FakeMessage 'baseline' '微信' $true; Add-PersistentMessages @($baseRecord)
  Check 'historical first screen is preserved without generating tasks' (@(Get-PendingQueueMessages).Count -eq 0)

  $message = FakeMessage 'fault-after-todos'; Add-PersistentMessages @($message)
  $script:QueueFault = 'after_todos'; $interrupted = $false
  try { Extract-Todos -Force } catch { $interrupted = $true }
  Check 'synthetic interruption occurs after durable output before ack' ($interrupted -and @(Get-PendingQueueMessages).Count -eq 1)
  $count = @(Get-QueueJsonLines (Join-Path $data 'todos.jsonl')).Count
  $script:QueueFault = ''; Initialize-ExtractQueue $data $script:V2Data; Extract-Todos -Force
  Check 'transaction recovery acknowledges without duplicating task' (@(Get-QueueJsonLines (Join-Path $data 'todos.jsonl')).Count -eq $count -and @(Get-PendingQueueMessages).Count -eq 0)

  $orphan = FakeMessage 'enqueue-before-journal'
  [void](Add-QueueEnvelope $orphan)
  Initialize-ExtractQueue $data $script:V2Data; Extract-Todos -Force
  Check 'restart restores message archive if process ended after enqueue' (@(Get-QueueJsonLines (Join-Path $data 'messages.jsonl') | Where-Object key -eq 'enqueue-before-journal').Count -eq 1)
  Check 'restored queue record is completed once' (@(Get-PendingQueueMessages).Count -eq 0)

  Add-PersistentMessages @((FakeMessage 'fault-before-ack'))
  $script:QueueFault = 'before_ack'; try { Extract-Todos -Force } catch { }
  $count = @(Get-QueueJsonLines (Join-Path $data 'todos.jsonl')).Count
  $script:QueueFault = ''; Extract-Todos -Force
  Check 'crash before acknowledgement replays effects once' (@(Get-QueueJsonLines (Join-Path $data 'todos.jsonl')).Count -eq $count -and @(Get-PendingQueueMessages).Count -eq 0)

  # 真正的首次升级：旧消息及旧确认在首次初始化队列之前已存在。
  $legacyData = Join-Path $temp 'legacy-data'
  $legacy = FakeMessage 'legacy'; Add-QueueLines (Join-Path $legacyData 'messages.jsonl') @($legacy | ConvertTo-Json -Compress)
  Add-QueueLines (Join-Path $legacyData 'extracted.keys') @('legacy')
  Initialize-ExtractQueue $legacyData $script:V2Data
  Check 'upgrade respects legacy extraction acknowledgements' (@(Get-PendingQueueMessages).Count -eq 0)
  Initialize-ExtractQueue $data $script:V2Data

  # 一个来源提交后、另一个尚未处理时退出，裸旧 key 不能替其他来源提前确认。
  $collisionA = FakeMessage 'cross-source-restart-key' 'synthetic-collision-a'
  $collisionB = FakeMessage 'cross-source-restart-key' 'synthetic-collision-b'
  Add-PersistentMessages @($collisionA, $collisionB)
  $script:QueueFault = 'after_todos'; $interrupted = $false
  try { Extract-Todos -Force } catch { $interrupted = $true }
  Check 'shared source key interruption leaves both inputs unacknowledged' ($interrupted -and @(Get-PendingQueueMessages).Count -eq 2)
  $script:QueueFault = ''; Initialize-ExtractQueue $data $script:V2Data; Extract-Todos -Force
  $collisionTasks = @(Get-QueueJsonLines (Join-Path $data 'todos.jsonl') | Where-Object { $_.app -in 'synthetic-collision-a','synthetic-collision-b' })
  Check 'restart commits each source sharing a key exactly once' ($collisionTasks.Count -eq 2 -and @($collisionTasks | Group-Object app).Count -eq 2)
  Check 'shared-key recovery acknowledges only after both effects' (@(Get-PendingQueueMessages).Count -eq 0)
  $allTasks = @(Get-QueueJsonLines (Join-Path $data 'todos.jsonl'))
  Check 'tasks carry stable identity and original-message provenance' (@($allTasks | Where-Object { -not $_.id -or -not $_.message_key -or -not $_.source_keys }).Count -eq 0)
  Check 'new message archives retain persistent queue ordering' (@(Get-QueueJsonLines (Join-Path $data 'messages.jsonl') | Where-Object { $_.key -ne 'legacy' -and -not $_.queue_sequence }).Count -eq 0)
  Check 'tasks expose original sequence for same-second replies' (@($allTasks | Where-Object { -not $_.source_sequence }).Count -eq 0)
  $datedPromise = @(Invoke-LocalRules @([pscustomobject]@{发送方='我';文本='我周五给组长发周报材料'}))
  Check 'dated promise remains a promise in offline extraction' ($datedPromise.Count -eq 1 -and $datedPromise[0].类别 -eq '你答应别人的' -and $datedPromise[0].截止)


  Add-PersistentMessages @((FakeMessage 'extract-failure'))
  function Get-Permission { $true }
  function Invoke-Claude { throw 'synthetic_provider_failure' }
  Extract-Todos -Force
  Check 'provider failure leaves input pending without acknowledgement' (@(Get-PendingQueueMessages).Count -eq 1)
  function Get-Permission { $false }
  Extract-Todos -Force
  Check 'next independent processing attempt recovers pending work' (@(Get-PendingQueueMessages).Count -eq 0)

  # 写盘失败不能污染内存去重状态；下次看到同一消息仍可保存。
  $knownConv = New-Object 'System.Collections.Generic.HashSet[string]'
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  $seenContent = New-Object 'System.Collections.Generic.HashSet[string]'
  function KeyOf([string]$value) { Get-QueueHash $value }
  $originalEnqueue = ${function:Add-PersistentMessages}
  function Add-PersistentMessages { throw 'synthetic_write_failure' }
  $sample = @([pscustomobject]@{发送方='合成发送者';文本='请检查恢复测试？';图片=$false;显示时间=''})
  try { [void](Save-Messages '合成写入测试' $sample $false) } catch { }
  Check 'failed durable write does not poison deduplication state' ($seen.Count -eq 0 -and $seenContent.Count -eq 0)
  Set-Item -Path Function:Add-PersistentMessages -Value $originalEnqueue
  $saved = Save-Messages '合成写入测试' $sample $false
  Check 'same message retries after durable-write failure' ($saved -eq 1 -and @(Get-PendingQueueMessages).Count -eq 1)
  Extract-Todos -Force

  # 使用实际事项合并库，先提交事项，再从队列提取改期消息。
  $script:DataDir = $data
  function Read-Jsonl([string]$name) { @(Get-QueueJsonLines (Join-Path $script:DataDir $name)) }
  . (Join-Path $v2 'lib_提醒.ps1'); . (Join-Path $v2 'lib_事项.ps1')
  $promise = FakeMessage 'promise-start' 'synthetic-revision'
  $promise.sender = Protect '我'; $promise.text = Protect '我周五发周报材料'
  Add-PersistentMessages @($promise); Extract-Todos -Force
  $before = @(Get-TrackedTodos | Where-Object app -eq 'synthetic-revision')
  $originalTaskId = $before[0].id
  $revision = FakeMessage 'promise-revision' 'synthetic-revision'
  $revision.sender = Protect '我'; $revision.text = Protect '周报材料改到周六发'
  Add-PersistentMessages @($revision); Extract-Todos -Force
  $after = @(Get-TrackedTodos | Where-Object app -eq 'synthetic-revision')
  Check 'queue revision updates original task instead of adding another' ($after.Count -eq 1 -and $after[0].id -eq $originalTaskId -and $after[0].due_at -and $after[0].revision -gt 0)
  $historyCount = @(Get-TaskHistory).Count
  Repair-QueueTransactions
  Check 'revision replay retains one history change' (@(Get-TaskHistory).Count -eq $historyCount)

  $pair1 = FakeMessage 'same-second-start' 'synthetic-same-second'
  $pair1.sender = Protect '我'; $pair1.text = Protect '我周五发周报材料'
  $pair2 = FakeMessage 'same-second-revision' 'synthetic-same-second'
  $pair2.sender = Protect '我'; $pair2.text = Protect '周报材料改到周六发'; $pair2.ts = $pair1.ts
  Add-PersistentMessages @($pair1, $pair2)
  $orderedInput = @(Get-PendingQueueMessages | Sort-Object sequence)
  Check 'messages captured in one second retain source order' ($orderedInput[0].message.key -eq 'same-second-start' -and $orderedInput[1].message.key -eq 'same-second-revision')
  Extract-Todos -Force
  $pairedTasks = @(Get-TrackedTodos | Where-Object app -eq 'synthetic-same-second')
  Check 'same-batch promise and revision form one tracked task' ($pairedTasks.Count -eq 1 -and $pairedTasks[0].revision -gt 0)

  # 从真实队列入口走“别人提出要求 → 用户答应”，应复用原请求，不能再新增承诺。
  $request = FakeMessage 'request-to-promise' 'synthetic-promise-chain'
  $request.text = Protect '请明天发周报材料给我？'
  Add-PersistentMessages @($request); Extract-Todos -Force
  $originalRequest = @(Get-TrackedTodos | Where-Object app -eq 'synthetic-promise-chain')
  $requestId = $originalRequest[0].id
  $promiseReply = FakeMessage 'promise-to-request' 'synthetic-promise-chain'
  $promiseReply.sender = Protect '我'; $promiseReply.text = Protect '明天发你'; $promiseReply.ts = $request.ts
  Add-PersistentMessages @($promiseReply); Extract-Todos -Force
  $promiseChain = @(Get-TrackedTodos | Where-Object app -eq 'synthetic-promise-chain')
  Check 'promise reply reuses original request through queue commit' ($promiseChain.Count -eq 1 -and $promiseChain[0].id -eq $requestId -and $promiseChain[0].status -eq 'promised' -and $promiseChain[0].category -eq '你答应别人的')
  Check 'promise conversion preserves original request and message identity' ($promiseChain[0].quote -eq (Unprotect $request.text) -and $promiseChain[0].message_key -eq $request.key -and $promiseChain[0].due_at)
  $requestHistoryCount = @(Get-TaskHistory | Where-Object id -eq $requestId).Count
  [void](Get-TaskReplyTransitions)
  Check 'reply scanner does not apply collector promise evidence twice' (@(Get-TaskHistory | Where-Object id -eq $requestId).Count -eq $requestHistoryCount)

  # 独立 worker 在假读取源阻塞期间仍消费队列；它只读取本测试临时目录。
  Add-PersistentMessages @((FakeMessage 'worker-independent'))
  $watch = [Diagnostics.Stopwatch]::StartNew(); Start-QueueWorker; $startMs = $watch.ElapsedMilliseconds
  $deadline = (Get-Date).AddSeconds(15)
  do { Start-Sleep -Milliseconds 150; $remaining = @(Get-PendingQueueMessages).Count } while ($remaining -and (Get-Date) -lt $deadline)
  Check 'worker starts asynchronously' ($startMs -lt 1500)
  Check 'worker consumes while collection thread is not polling' ($remaining -eq 0)
  $script:QueueWorker.stop.Set() | Out-Null
  if ($script:QueueWorker.handle.AsyncWaitHandle.WaitOne(5000)) { [void]$script:QueueWorker.ps.EndInvoke($script:QueueWorker.handle) }
  Check 'worker finishes without background errors' ($script:QueueWorker.ps.Streams.Error.Count -eq 0)
  Check 'queue payload remains encrypted' (-not ((Get-ChildItem -LiteralPath (Join-Path $script:QueueDir 'items') -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n").Contains('请检查合成文件'))
  "queue_reliability_test: $pass pass, $fail fail"
} finally {
  if ($script:QueueWorker) { [void]$script:QueueWorker.stop.Set(); if (-not $script:QueueWorker.handle.IsCompleted) { $script:QueueWorker.ps.Stop() }; $script:QueueWorker.ps.Dispose(); $script:QueueWorker.stop.Dispose() }
  $resolved = [IO.Path]::GetFullPath($temp)
  if (-not $resolved.StartsWith([IO.Path]::GetFullPath($testTempRoot), [StringComparison]::OrdinalIgnoreCase)) { throw 'test_cleanup_outside_temp' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
if ($fail) { exit 1 }
