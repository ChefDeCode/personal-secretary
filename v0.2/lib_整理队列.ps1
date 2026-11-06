# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 统一整理队列。items 是不可变的加密消息，transactions 是先写盘的整理结果；只追加，不删原文。
# 只有一位整理者持有命名锁。先持久化结果，再投影到原有文件，最后确认消息；每一步都可重放。
function Get-QueueHash([string]$text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Write-QueueAtomic([string]$path, [string]$text) {
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
  $tmp = $path + '.' + [guid]::NewGuid().ToString('n') + '.tmp'
  try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    $s = [IO.FileStream]::new($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $s.Write($bytes, 0, $bytes.Length); $s.Flush($true) } finally { $s.Dispose() }
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
  } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
function Invoke-QueueLock([string]$scope, [scriptblock]$body) {
  $mutex = [Threading.Mutex]::new($false, ('Local\SecretaryQueue_' + (Get-QueueHash ($script:QueueData.ToLowerInvariant() + '|' + $scope))))
  $locked = $false
  try {
    try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }   # 30 秒：整理那边整份消息存档重新扫一遍有时要 10 秒以上（2026-11-05 看文件夹等锁超时过 1 次）
    if (-not $locked) { throw 'queue_lock_timeout' }
    & $body
  } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
function Initialize-ExtractQueue([string]$dataPath, [string]$v2DataPath) {
  $script:QueueData = [IO.Path]::GetFullPath($dataPath)
  $script:QueueV2 = [IO.Path]::GetFullPath($v2DataPath)
  $script:QueueDir = Join-Path $script:QueueData 'extract_queue'
  foreach ($part in 'items', 'transactions', 'acks') { [void][IO.Directory]::CreateDirectory((Join-Path $script:QueueDir $part)) }
  # 裸 extracted.keys 只用于首次升级时已存在的旧消息，不能确认随后其他来源的同名 key。
  # 先原子保存准确的来源身份快照，再导入；迁移过程中退出也仍使用同一份快照。
  Invoke-QueueLock 'journal' {
    $migrationPath = Join-Path $script:QueueDir 'legacy_acks.json'
    if (-not [IO.File]::Exists($migrationPath)) {
      $legacy = @{}; $legacyPath = Join-Path $script:QueueData 'extracted.keys'
      if ([IO.File]::Exists($legacyPath)) { foreach ($key in [IO.File]::ReadLines($legacyPath)) { $legacy[$key] = $true } }
      $ids = New-Object System.Collections.Generic.List[string]
      foreach ($record in Get-QueueJsonLines (Join-Path $script:QueueData 'messages.jsonl')) {
        if (-not $record.key -or $record.queue_sequence -or -not $legacy[[string]$record.key]) { continue }
        $id = Get-QueueMessageId $record
        if (-not [IO.File]::Exists((Join-Path $script:QueueDir ('items\' + $id + '.json')))) { $ids.Add($id) }
      }
      Write-QueueAtomic $migrationPath ((@{ version = 1; ids = @($ids.ToArray()) } | ConvertTo-Json -Depth 4 -Compress))
    }
    $script:QueueLegacyAckIds = @{}
    foreach ($id in @(([IO.File]::ReadAllText($migrationPath) | ConvertFrom-Json).ids)) { $script:QueueLegacyAckIds[[string]$id] = $true }
  }
  $script:QueueJournalStamp = ''; $script:QueueSynced = $false; $script:QueueReady = $true
}
function Get-QueueMessageId($record) {
  if (-not $record.key) { throw 'message_key_required' }
  $app = if ($record.app) { [string]$record.app } else { '微信' }
  Get-QueueHash ($app + '|' + [string]$record.conv_key + '|' + [string]$record.key)
}
function Add-QueueEnvelope($record) {
  $id = Get-QueueMessageId $record
  $path = Join-Path $script:QueueDir ('items\' + $id + '.json')
  if (-not [IO.File]::Exists($path)) {
    # 调用方持有 journal 锁；独立序号保留同一秒多条消息的原顺序，时钟回拨也不改变顺序。
    $sequencePath = Join-Path $script:QueueDir 'sequence.json'; $sequence = 0L
    if ([IO.File]::Exists($sequencePath)) { $sequence = [long](([IO.File]::ReadAllText($sequencePath) | ConvertFrom-Json).last) }
    $sequence++
    Write-QueueAtomic $sequencePath ((@{ last = $sequence } | ConvertTo-Json -Compress))
    if ($record -is [Collections.IDictionary]) { $record['queue_sequence'] = $sequence }
    else { $record | Add-Member -NotePropertyName queue_sequence -NotePropertyValue $sequence -Force }
    Write-QueueAtomic $path (([ordered]@{ id = $id; sequence = $sequence; observed_at = [string]$record.ts; message = $record } | ConvertTo-Json -Depth 8 -Compress))
  } else {
    $existing = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($existing.sequence) {
      if ($record -is [Collections.IDictionary]) { $record['queue_sequence'] = [long]$existing.sequence }
      else { $record | Add-Member -NotePropertyName queue_sequence -NotePropertyValue ([long]$existing.sequence) -Force }
    }
  }
  $id
}
function Get-QueueJsonLines([string]$path) {
  if (-not [IO.File]::Exists($path)) { return }
  foreach ($line in [IO.File]::ReadLines($path, [Text.Encoding]::UTF8)) {
    if (-not $line.Trim()) { continue }
    try { $line | ConvertFrom-Json -ErrorAction Stop } catch { }
  }
}
function Add-QueueLines([string]$path, [string[]]$lines) {
  if (-not $lines.Count) { return }
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
  $stream = [IO.FileStream]::new($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
  try {
    $prefix = ''
    if ($stream.Length) { [void]$stream.Seek(-1, [IO.SeekOrigin]::End); if ($stream.ReadByte() -ne 10) { $prefix = "`n" } }
    [void]$stream.Seek(0, [IO.SeekOrigin]::End)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($prefix + ($lines -join "`n") + "`n")
    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
  } finally { $stream.Dispose() }
}
# —— 消息存档只读新增的部分（2026-11-05）：以前每存一条消息、每次整理都把整份存档（几千条）从头读一遍，还是在锁里读，最长要 10 秒以上 ——
# journal_mark.json 记：读到第几个字节、存档开头的指纹、id 索引有多长；journal_ids.txt 是存档里已有消息 id 的清单（只追加）
# 记号对不上（存档变短了、开头变了、索引对不上、记号坏了）才从头扫一遍，并记一行到 rescans.jsonl
$script:JournalIdSet = $null; $script:JournalIdxBytes = 0L; $script:QueueLockMs = New-Object System.Collections.ArrayList
function Get-JournalHead([string]$path) {
  if (-not [IO.File]::Exists($path)) { return '' }
  $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try { $n = [int][Math]::Min(256, $fs.Length); if (-not $n) { return '' }; $buf = New-Object byte[] $n; [void]$fs.Read($buf, 0, $n); Get-QueueHash ([Convert]::ToBase64String($buf)) } finally { $fs.Dispose() }
}
function Read-JournalMark { $p = Join-Path $script:QueueDir 'journal_mark.json'; if (-not [IO.File]::Exists($p)) { return $null }; try { [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { 'corrupt' } }
function Read-JournalIndexTail([string]$ip) {
  # 把索引里新长出来的部分读进内存（别的进程也可能往里追加过）
  if (-not [IO.File]::Exists($ip)) { return }
  $fs = [IO.File]::Open($ip, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try { if ($fs.Length -le $script:JournalIdxBytes) { return }; [void]$fs.Seek($script:JournalIdxBytes, [IO.SeekOrigin]::Begin); $buf = New-Object byte[] ($fs.Length - $script:JournalIdxBytes); [void]$fs.Read($buf, 0, $buf.Length)
    $txt = [Text.Encoding]::UTF8.GetString($buf); $cut = $txt.LastIndexOf("`n"); if ($cut -lt 0) { return }
    foreach ($id in $txt.Substring(0, $cut).Split("`n")) { $id = $id.Trim(); if ($id) { [void]$script:JournalIdSet.Add($id) } }
    $script:JournalIdxBytes += [Text.Encoding]::UTF8.GetByteCount($txt.Substring(0, $cut + 1)) } finally { $fs.Dispose() }
}
# 调用方持有 journal 锁。读存档里记号之后新写进来的完整行：入队、记 id；返回读了多少行、花了多少毫秒
function Invoke-JournalCatchUp {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $journal = Join-Path $script:QueueData 'messages.jsonl'; $ip = Join-Path $script:QueueDir 'journal_ids.txt'; $mp = Join-Path $script:QueueDir 'journal_mark.json'
  $len = if ([IO.File]::Exists($journal)) { (New-Object IO.FileInfo $journal).Length } else { 0L }
  $head = Get-JournalHead $journal; $mark = Read-JournalMark; $ipLen = if ([IO.File]::Exists($ip)) { (New-Object IO.FileInfo $ip).Length } else { 0L }
  $why = if ($mark -eq 'corrupt') { 'mark_corrupt' } elseif (-not $mark) { 'no_mark' } elseif ([long]$mark.offset -gt $len) { 'archive_shrank' } elseif ([long]$mark.offset -gt 0 -and [string]$mark.head -ne $head) { 'archive_replaced' } elseif ([long]$mark.index_bytes -ne $ipLen) { 'index_mismatch' } else { '' }
  if ($why) {
    $offset = 0L; [IO.File]::WriteAllText($ip, ''); $script:JournalIdSet = New-Object 'System.Collections.Generic.HashSet[string]'; $script:JournalIdxBytes = 0L
    if ($why -ne 'no_mark' -or $len -gt 0) { Add-QueueLines (Join-Path $script:QueueDir 'rescans.jsonl') @((@{ ts = (Get-Date).ToString('s'); why = $why; archive_bytes = $len } | ConvertTo-Json -Compress)) }
  } else {
    $offset = [long]$mark.offset
    if ($null -eq $script:JournalIdSet -or $script:JournalIdxBytes -gt $ipLen) { $script:JournalIdSet = New-Object 'System.Collections.Generic.HashSet[string]'; $script:JournalIdxBytes = 0L }
    Read-JournalIndexTail $ip
  }
  $read = 0
  if ($offset -lt $len) {
    $fs = [IO.File]::Open($journal, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { [void]$fs.Seek($offset, [IO.SeekOrigin]::Begin); $buf = New-Object byte[] ($len - $offset); $got = 0; while ($got -lt $buf.Length) { $k = $fs.Read($buf, $got, $buf.Length - $got); if ($k -le 0) { break }; $got += $k } } finally { $fs.Dispose() }
    $lastNl = [Array]::LastIndexOf($buf, [byte]10, $got - 1)   # 只处理完整的行：最后半行（还在写）留到下一次
    if ($lastNl -ge 0) {
      $newIds = New-Object System.Collections.Generic.List[string]
      foreach ($line in [Text.Encoding]::UTF8.GetString($buf, 0, $lastNl + 1).Split("`n")) {
        if (-not $line.Trim()) { continue }; $record = $null; try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $record.key) { continue }; $read++
        $id = Add-QueueEnvelope $record
        $ack = Join-Path $script:QueueDir ('acks\' + $id + '.json')
        if ($script:QueueLegacyAckIds -and $script:QueueLegacyAckIds[$id] -and -not [IO.File]::Exists($ack)) { Write-QueueAtomic $ack '{"state":"legacy_committed"}' }
        if ($script:JournalIdSet.Add($id)) { $newIds.Add($id) } }
      if ($newIds.Count) { Add-QueueLines $ip $newIds.ToArray() }
      $offset += $lastNl + 1
      $script:JournalIdxBytes = if ([IO.File]::Exists($ip)) { (New-Object IO.FileInfo $ip).Length } else { 0L } }
  }
  Write-QueueAtomic $mp ((@{ offset = $offset; head = $(if ($offset -gt 0) { Get-JournalHead $journal } else { '' }); index_bytes = $script:JournalIdxBytes; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress))
  @{ read = $read; ms = [int]$sw.ElapsedMilliseconds; rescan = $why }
}
function Add-PersistentMessages($records) {
  Invoke-QueueLock 'journal' {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [void](Invoke-JournalCatchUp)   # 先把别人新写的读进来，免得重复
    $journal = Join-Path $script:QueueData 'messages.jsonl'
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($record in @($records)) {
      $id = Add-QueueEnvelope $record
      if (-not $script:JournalIdSet.Contains($id)) { $lines.Add(($record | ConvertTo-Json -Depth 8 -Compress)) }
    }
    Add-QueueLines $journal $lines.ToArray()
    [void](Invoke-JournalCatchUp)   # 刚写进去的几行：记 id、推进记号（只读这几行）
    [void]$script:QueueLockMs.Add([int]$sw.ElapsedMilliseconds)
  }
}
function Sync-QueueJournal {
  # 导入原消息存档：只读记号之后新增的部分；只有首次迁移快照中的完整来源身份可沿用旧确认
  $journal = Join-Path $script:QueueData 'messages.jsonl'
  $stamp = if ([IO.File]::Exists($journal)) { $f = Get-Item -LiteralPath $journal; "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)" } else { '' }
  if ($script:QueueJournalStamp -eq $stamp -and $script:QueueSynced) { return }
  Invoke-QueueLock 'journal' { $r = Invoke-JournalCatchUp; [void]$script:QueueLockMs.Add($r.ms) }
  $script:QueueJournalStamp = $stamp; $script:QueueSynced = $true
}
function Get-PendingQueueMessages {
  Sync-QueueJournal
  foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:QueueDir 'items') -Filter '*.json' -File | Sort-Object Name) {
    if ([IO.File]::Exists((Join-Path $script:QueueDir ('acks\' + $f.BaseName + '.json')))) { continue }
    $o = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $o.message.baseline) { $o }
  }
}
function Write-QueueTransaction($envelopes, $todos, $events) {
  $ids = @($envelopes | ForEach-Object id | Sort-Object)
  $id = Get-QueueHash ($ids -join '|')
  $path = Join-Path $script:QueueDir ('transactions\' + $id + '.json')
  if (-not [IO.File]::Exists($path)) {
    $txn = [ordered]@{ id = $id; state = 'prepared'; at = (Get-Date).ToString('o'); message_ids = $ids; messages = @($envelopes | ForEach-Object message); todos = @($todos); events = @($events) }
    Write-QueueAtomic $path ($txn | ConvertTo-Json -Depth 12 -Compress)
  }
  $path
}
function Complete-QueueTransaction([string]$path) {
  $txn = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
  if ($txn.state -eq 'committed') { return }
  # 恢复在消息入队后、旧消息存档前的中断；消息和原文都不删除。
  Add-PersistentMessages @($txn.messages)
  Invoke-QueueLock 'effects' {
    $todoPath = Join-Path $script:QueueData 'todos.jsonl'
    $seen = @{}; foreach ($row in Get-QueueJsonLines $todoPath) { if ($row.id) { $seen[[string]$row.id] = $true } }
    foreach ($row in @($txn.todos)) {
      if (-not $row.id) { throw 'todo_id_required' }
      if (-not $seen[[string]$row.id]) {
        $merge = if (Get-Command Merge-TaskCandidate -ErrorAction SilentlyContinue) { Merge-TaskCandidate $row } else { $null }
        if (-not $merge -or -not $merge.updated) {
          Add-QueueLines $todoPath @($row | ConvertTo-Json -Depth 8 -Compress)
          $seen[[string]$row.id] = $true
        }
      }
    }
    if ($script:QueueFault -eq 'after_todos') { throw 'synthetic_commit_interruption' }
    $eventsPath = Join-Path $script:QueueV2 'events.jsonl'
    $seenEvents = @{}
    if ([IO.File]::Exists($eventsPath)) { foreach ($line in [IO.File]::ReadLines($eventsPath)) { try { $ev = (Unprotect $line) | ConvertFrom-Json; if ($ev.key) { $seenEvents[[string]$ev.key] = $true } } catch { } } }
    $eventLines = New-Object System.Collections.Generic.List[string]
    foreach ($ev in @($txn.events)) { if (-not $seenEvents[[string]$ev.key]) { $eventLines.Add([string]$ev.encrypted); $seenEvents[[string]$ev.key] = $true } }
    Add-QueueLines $eventsPath $eventLines.ToArray()
    if ($script:QueueFault -eq 'before_ack') { throw 'synthetic_ack_interruption' }
    foreach ($id in @($txn.message_ids)) { Write-QueueAtomic (Join-Path $script:QueueDir ('acks\' + $id + '.json')) ((@{ state = 'committed'; transaction = [string]$txn.id } | ConvertTo-Json -Compress)) }
    $legacyPath = Join-Path $script:QueueData 'extracted.keys'; $legacy = @{}
    if ([IO.File]::Exists($legacyPath)) { foreach ($key in [IO.File]::ReadLines($legacyPath)) { $legacy[$key] = $true } }
    $keys = @($txn.messages | ForEach-Object { if (-not $legacy[[string]$_.key]) { [string]$_.key; $legacy[[string]$_.key] = $true } })
    Add-QueueLines $legacyPath ([string[]]$keys)
    $txn.state = 'committed'; Write-QueueAtomic $path ($txn | ConvertTo-Json -Depth 12 -Compress)
  }
}
function Repair-QueueTransactions {
  foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:QueueDir 'transactions') -Filter '*.json' -File | Sort-Object Name) { Complete-QueueTransaction $f.FullName }
}
function Get-QueueWorkerState {
  $f = Join-Path $script:QueueDir 'worker.json'
  if ([IO.File]::Exists($f)) { try { [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { } }
}
function Write-QueueWorkerState([string]$state, [int]$pending = 0, [long]$elapsedMs = 0) {
  Write-QueueAtomic (Join-Path $script:QueueDir 'worker.json') ((@{ state = $state; pending = $pending; elapsed_ms = $elapsedMs; at = (Get-Date).ToString('o'); pid = $PID } | ConvertTo-Json -Compress))
}
