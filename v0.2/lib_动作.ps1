# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# Durable execution state. Consent (pending/confirmed) is separate from these five states.
# The action is encrypted; the append-only audit contains only IDs, phases and counts.
function Set-ActionField($a, [string]$name, $value) {
  if ($a -is [System.Collections.IDictionary]) { $a[$name] = $value }
  else { $a | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
}
function Write-ActionAtomic([string]$path, [string]$text) {
  $dir = [IO.Path]::GetDirectoryName($path); [void][IO.Directory]::CreateDirectory($dir)
  $tmp = Join-Path $dir ([IO.Path]::GetFileName($path) + '.' + [guid]::NewGuid().ToString('n') + '.tmp')
  try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    $fs = [IO.FileStream]::new($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
  } finally { if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) } }
}
function Get-ActionState($a) {
  if (-not $a) { return 'unknown' }
  if ($a.execution_state -in 'queued','running','succeeded','failed','unknown') { return [string]$a.execution_state }
  switch ([string]$a.status) {
    { $_ -in 'pending','confirmed','scheduled' } { 'queued'; break }
    { $_ -in 'sent','done','succeeded' } { 'succeeded'; break }
    { $_ -in 'failed','cancelled' } { 'failed'; break }
    { $_ -in 'sending','started','running' } { 'running'; break }
    default { 'unknown' }
  }
}
function Get-ActionStateFromStatus([string]$status) {
  Get-ActionState ([pscustomobject]@{ status = $status })
}
function Get-ActionRecord([string]$id) {
  if ($id -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid action ID' }
  $f = Join-Path $script:ActDir "$id.json"
  if (Test-Path -LiteralPath $f) { (Unprotect ([IO.File]::ReadAllText($f))) | ConvertFrom-Json }
}
function Save-ReliableAction($a, [switch]$ExplicitResolution) {
  if (-not $a -or ([string]$a.id) -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid action ID' }
  $old = Get-ActionRecord ([string]$a.id)
  $state = Get-ActionStateFromStatus ([string]$a.status)
  if ($old) {
    $oldState = Get-ActionState $old
    if ($oldState -eq 'succeeded' -and $state -ne 'succeeded') { throw 'An already successful action cannot be rearmed' }
    if ($oldState -eq 'running' -and $state -eq 'queued') { throw 'Running action cannot be rearmed' }
    if ($oldState -eq 'unknown' -and $state -notin 'unknown','succeeded' -and -not $ExplicitResolution) { throw 'Unknown send result requires user verification' }
    foreach ($name in @('attempt_id','attempt_pid','phase','send_intent_at','send_pressed_at','verified_at','attempt_started_at')) {
      if ($null -eq $a.$name -and $null -ne $old.$name) { Set-ActionField $a $name $old.$name }
    }
  }
  Set-ActionField $a 'execution_state' $state
  Set-ActionField $a 'updated_at' ([DateTimeOffset]::Now.ToString('o'))
  Write-ActionAtomic (Join-Path $script:ActDir "$($a.id).json") (Protect ($a | ConvertTo-Json -Depth 12 -Compress))
}
function Write-ActionAudit($a, [string]$event) {
  $rec = @{ ts = [DateTimeOffset]::Now.ToString('o'); id = [string]$a.id; attempt = [string]$a.attempt_id; state = (Get-ActionState $a); phase = [string]$a.phase; ev = $event }
  [IO.File]::AppendAllLines((Join-Path $script:ActDir "$($a.id).audit.jsonl"), [string[]]@(($rec | ConvertTo-Json -Compress)), [Text.UTF8Encoding]::new($false))
}
function Get-ActionAttemptCount([string]$id, [datetime]$now = (Get-Date)) {
  $f = Join-Path $script:ActDir "$id.audit.jsonl"; $n = 0
  if (Test-Path -LiteralPath $f) {
    foreach ($l in [IO.File]::ReadLines($f)) { try { $r = $l | ConvertFrom-Json; if ($r.ev -eq 'attempt' -and ([DateTimeOffset]$r.ts).LocalDateTime -gt $now.AddMinutes(-2)) { $n++ } } catch {} }
  }
  $legacy = Join-Path $script:V2Data 'send_trace.jsonl'; $legacyN = 0
  if (Test-Path -LiteralPath $legacy) {
    foreach ($l in Get-Content -LiteralPath $legacy -Tail 300 -Encoding UTF8) { try { $r = $l | ConvertFrom-Json; if ($r.id -eq $id -and $r.ts -and [datetime]$r.ts -gt $now.AddMinutes(-2)) { $legacyN++ } } catch {} }
  }
  [Math]::Max($n, $legacyN)
}
function Start-ActionAttempt([string]$id, [int]$ownerPid = $PID) {
  $a = Get-ActionRecord $id
  if (-not $a -or $a.status -ne 'confirmed') { throw 'Action was not confirmed' }
  $state = Get-ActionState $a
  if ($state -in 'succeeded','unknown','running') { throw 'Action cannot be started in its current state' }
  if ((Get-ActionAttemptCount $id) -ge 3) { throw 'Attempt limit reached' }
  $a.status = 'running'; Set-ActionField $a 'phase' 'preparing'; Set-ActionField $a 'attempt_id' ([guid]::NewGuid().ToString('n'))
  Set-ActionField $a 'attempt_pid' $ownerPid; Set-ActionField $a 'attempt_started_at' ([DateTimeOffset]::Now.ToString('o'))
  foreach ($f in @('send_intent_at','send_pressed_at','verified_at')) { Set-ActionField $a $f '' }
  Save-ReliableAction $a; Write-ActionAudit $a 'attempt'; $a
}
function Set-ActionPhase([string]$id, [ValidateSet('send_intent','send_pressed','verified')][string]$phase) {
  $a = Get-ActionRecord $id
  if (-not $a -or (Get-ActionState $a) -ne 'running') { throw 'Action is not running' }
  $allowed = switch ($phase) { 'send_intent' { $a.phase -eq 'preparing' } 'send_pressed' { $a.phase -eq 'send_intent' } 'verified' { $a.phase -eq 'send_pressed' } }
  if (-not $allowed) { throw 'Out-of-order send phase' }
  Set-ActionField $a 'phase' $phase
  $key = switch ($phase) { 'send_intent' { 'send_intent_at' } 'send_pressed' { 'send_pressed_at' } 'verified' { 'verified_at' } }
  Set-ActionField $a $key ([DateTimeOffset]::Now.ToString('o'))
  if ($phase -eq 'verified') { $a.status = 'sent' }
  Save-ReliableAction $a; Write-ActionAudit $a $phase
}
function Save-ActionResult([string]$id, $ok, [string]$message, $steps, [string]$draft = '') {
  $a = Get-ActionRecord $id; if (-not $a) { throw 'Missing action' }
  $state = Get-ActionState $a
  if ($state -eq 'succeeded') { $ok = $true }
  elseif ($a.phase -in 'send_intent','send_pressed' -and $ok -ne $true) { $ok = $null }
  elseif ($ok -eq $true -and $a.phase -ne 'verified' -and $a.phase -ne 'user_verified') { $ok = $null }
  $state = if ($ok -eq $true) { 'succeeded' } elseif ($null -eq $ok) { 'unknown' } else { 'failed' }
  if ($a.replace) { Set-ActionField $a 'replace' $false }
  $a.status = switch ($state) { 'succeeded' { 'sent' } 'unknown' { 'unknown' } default { 'failed' } }
  Set-ActionField $a 'result_reason' $message
  Save-ReliableAction $a
  $r = @{ id = $id; attempt_id = [string]$a.attempt_id; state = $state; ok = $ok; steps = @($steps); message = $message; draft = $draft; retryable = $false }
  Write-ActionAtomic (Join-Path $script:ActDir "$id.result.json") (Protect ($r | ConvertTo-Json -Depth 8 -Compress))
  Write-ActionAudit $a 'result'; $r
}
function Read-ActionResult([string]$id) {
  $a = Get-ActionRecord $id; $f = Join-Path $script:ActDir "$id.result.json"
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try {
    $r = (Unprotect ([IO.File]::ReadAllText($f))) | ConvertFrom-Json
    if ($r.id -and $r.id -ne $id) { return $null }
    if ($a.attempt_id -and $r.attempt_id -ne $a.attempt_id) { return $null }
    $r
  } catch { $null }
}
function Test-ActionWorkerAlive($a) {
  if (-not $a.attempt_pid -or -not $a.attempt_started_at) { return $false }
  try {
    $p = Get-Process -Id ([int]$a.attempt_pid) -ErrorAction Stop
    $started = ([DateTimeOffset]$a.attempt_started_at).LocalDateTime
    $p.ProcessName -eq 'powershell' -and $p.StartTime -le $started -and ($started - $p.StartTime).TotalMinutes -lt 5
  } catch { $false }
}
function Recover-Action([string]$id, [switch]$KnownStopped) {
  $a = Get-ActionRecord $id; if (-not $a) { return $null }
  if (-not $KnownStopped -and (Test-ActionWorkerAlive $a)) { return $null }
  $state = Get-ActionState $a; $r = Read-ActionResult $id
  if ($state -eq 'succeeded' -or ($r -and $r.ok -eq $true)) {
    $a.status = 'sent'; Set-ActionField $a 'phase' 'verified'; Save-ReliableAction $a
    return (Save-ActionResult $id $true '已核对发出' @(@{ ok = $true; text = '已核对发出' }))
  }
  if ($r -and $state -notin 'running','unknown') { return $r }
  if ($a.phase -in 'preparing','launching' -or ($state -eq 'queued' -and $a.status -in 'pending','scheduled')) {
    return (Save-ActionResult $id $false '发送前已停止' @(@{ ok = $false; text = '记录确认尚未按发送，可手动重试' }))
  }
  if ($state -eq 'failed') { return (Save-ActionResult $id $false '执行已停止' @(@{ ok = $false; text = '这次没有完成，可手动重试' })) }
  # Missing legacy phase information is NOT proof of an unsent message.
  Save-ActionResult $id $null '结果待核对' @(@{ ok = $false; text = '发送结果尚未核对，请去微信看一眼；不会自动重发' })
}
function Resolve-ActionResult([string]$id, [ValidateSet('sent','retry')][string]$resolution) {
  $a = Get-ActionRecord $id
  if (-not $a -or (Get-ActionState $a) -ne 'unknown') { return $false }
  if ($resolution -eq 'sent') {
    $a.status = 'sent'; Set-ActionField $a 'phase' 'user_verified'; Set-ActionField $a 'verified_at' ([DateTimeOffset]::Now.ToString('o'))
    Save-ReliableAction $a -ExplicitResolution; Write-ActionAudit $a 'user_confirmed_sent'
    [void](Save-ActionResult $id $true '用户已核对发出' @(@{ ok = $true; text = '你已确认发出' }))
  } else {
    # Preserve prior result as an immutable attempt record; rearm only after this explicit choice.
    $old = Join-Path $script:ActDir "$id.result.json"
    if (Test-Path -LiteralPath $old) { [IO.File]::Move($old, (Join-Path $script:ActDir ($id + '.checked-' + [guid]::NewGuid().ToString('n') + '.result.json'))) }
    $a.status = 'failed'; Set-ActionField $a 'phase' 'user_confirmed_unsent'
    Save-ReliableAction $a -ExplicitResolution; Write-ActionAudit $a 'user_confirmed_unsent'
  }
  $true
}
function Enter-SendLease {
  $name = 'Local\SecretarySend-' + [Environment]::UserName
  $m = [Threading.Mutex]::new($false, $name); $owned = $false
  try { try { $owned = $m.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }; if ($owned) { return $m } } finally { if (-not $owned) { $m.Dispose() } }
  $null
}
function Exit-SendLease($lease) { if ($lease) { try { $lease.ReleaseMutex() } finally { $lease.Dispose() } } }

function Get-LocalOperationPath([string]$id) {
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($id)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
  Join-Path (Join-Path $script:ActDir 'operations') ($key+'.json')
}
function Get-LocalOperationState([string]$id) {
  $f=Get-LocalOperationPath $id
  if(Test-Path -LiteralPath $f){(Unprotect ([IO.File]::ReadAllText($f)))|ConvertFrom-Json}
}
function Set-LocalOperationState([string]$id,[ValidateSet('queued','running','succeeded','failed','unknown')][string]$state,[string]$phase='') {
  if(-not $id){throw 'Operation ID required'}
  $old=Get-LocalOperationState $id
  if($old -and $old.state -eq 'unknown' -and $state -in 'queued','running'){throw 'Unknown operation cannot run automatically'}
  if($old -and $old.state -eq 'succeeded' -and $state -in 'queued','running'){throw 'Completed operation cannot run twice'}
  $rec=@{id=$id;state=$state;phase=$phase;ts=[DateTimeOffset]::Now.ToString('o')}
  $f=Get-LocalOperationPath $id
  Write-ActionAtomic $f (Protect ($rec|ConvertTo-Json -Compress))
  $audit=@{ts=$rec.ts;state=$state;phase=$phase}
  [IO.File]::AppendAllLines(($f+'.audit.jsonl'),[string[]]@(($audit|ConvertTo-Json -Compress)),[Text.UTF8Encoding]::new($false))
  [pscustomobject]$rec
}
function Recover-LocalOperations {
  $d=Join-Path $script:ActDir 'operations';if(-not(Test-Path -LiteralPath $d)){return}
  foreach($f in Get-ChildItem -LiteralPath $d -Filter '*.json'){
    try{$r=(Unprotect ([IO.File]::ReadAllText($f.FullName)))|ConvertFrom-Json}catch{continue}
    if($r.state -eq 'running'){Set-LocalOperationState ([string]$r.id) 'unknown' 'interrupted'}
  }
}
