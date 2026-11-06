# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 上下文摘要只写 summary 和独立游标。chat / archive 原文从不裁剪、覆盖或删除。
# 每批先保存结果事务，再写摘要，再前移游标；崩溃后重放相同快照而不重复追加。
function Get-CompactionHash([string]$s){$h=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))-replace '-','').ToLowerInvariant()}finally{$h.Dispose()}}
function Get-CompactionDir {$p=Join-Path $script:V2Data 'compaction';[void][IO.Directory]::CreateDirectory($p);$p}
function Get-CompactionStatePath {Join-Path (Get-CompactionDir) 'state.json'}
function Get-CompactionState {
  $p=Get-CompactionStatePath
  if(-not (Test-Path -LiteralPath $p)){return [pscustomobject]@{covered=@();applied=@();pending=''}}
  $s=Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json
  if($null -eq $s.covered -or $null -eq $s.applied){throw 'Invalid compaction cursor'}
  $s
}
function Save-CompactionState($s){Write-FileAtomic (Get-CompactionStatePath) ($s|ConvertTo-Json -Depth 5 -Compress)}
function Get-CompactionTxnPath([string]$Id){if($Id -notmatch '^[a-f0-9]{64}$'){throw 'Invalid compaction batch id'};Join-Path (Get-CompactionDir) ($Id+'.json')}
function Read-CompactionTxn([string]$Id){$p=Get-CompactionTxnPath $Id;if(Test-Path -LiteralPath $p){(Unprotect (Get-Content -LiteralPath $p -Raw -Encoding UTF8))|ConvertFrom-Json}}
function Save-CompactionTxn($t){Write-FileAtomic (Get-CompactionTxnPath $t.id) (Protect ($t|ConvertTo-Json -Depth 16 -Compress))}
function Invoke-CompactionLock([scriptblock]$Body){
  $name='Local\SecretaryCompaction_'+(Get-CompactionHash ([IO.Path]::GetFullPath($script:SummaryFile))).Substring(0,24)
  $m=New-Object Threading.Mutex($false,$name);$held=$false
  try{try{$held=$m.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$held=$true};if(-not $held){throw 'Compaction is busy'};& $Body}finally{if($held){$m.ReleaseMutex()};$m.Dispose()}
}
function Complete-CompactionTxn($Txn,[switch]$FailAfterSummary){
  $state=Get-CompactionState
  if(@($state.applied) -contains [string]$Txn.id){
    if($Txn.status -ne 'applied'){$Txn.status='applied';Save-CompactionTxn $Txn}
    return @{applied=$false;id=$Txn.id;replayed=$true}
  }
  if($Txn.status -ne 'prepared' -or -not $Txn.new_summary){throw 'Compaction result is not prepared'}
  $current=Get-SummaryData
  $currentHash=Get-CompactionHash ($current|ConvertTo-Json -Depth 8 -Compress)
  $nextHash=Get-CompactionHash ($Txn.new_summary|ConvertTo-Json -Depth 8 -Compress)
  if($currentHash -ne $nextHash -and -not @($current.segments|Where-Object batch_id -eq $Txn.id).Count){
    if($currentHash -ne $Txn.prior_summary_hash){
      # 准备结果后若摘要另有更新，只追加本批分段，不用旧折叠结果覆盖新内容。
      $segment=@($Txn.new_summary.segments|Where-Object batch_id -eq $Txn.id)|Select-Object -Last 1
      if(-not $segment){throw 'Compaction result has no batch marker'}
      $Txn.new_summary=[pscustomobject]@{stable=[string]$current.stable;segments=@($current.segments)+@($segment)}
      $Txn.prior_summary_hash=$currentHash;Save-CompactionTxn $Txn
    }
    Write-FileAtomic $script:SummaryFile (Protect ($Txn.new_summary|ConvertTo-Json -Depth 8 -Compress))
  }
  if($FailAfterSummary){throw 'SYNTHETIC_CRASH_AFTER_SUMMARY'}
  $state.covered=@(@($state.covered)+@($Txn.ids)|Select-Object -Unique)
  $state.applied=@(@($state.applied)+@([string]$Txn.id)|Select-Object -Unique)
  $state.pending='';Save-CompactionState $state
  $Txn.status='applied';Save-CompactionTxn $Txn
  @{applied=$true;id=$Txn.id;replayed=$false}
}
function New-CompactionWork {
  Invoke-CompactionLock {
    $state=Get-CompactionState
    if($state.pending){
      $pending=Read-CompactionTxn ([string]$state.pending)
      if(-not $pending){throw 'Compaction cursor has no transaction'}
      if($pending.status -eq 'prepared'){[void](Complete-CompactionTxn $pending);$state=Get-CompactionState}
      elseif($pending.status -eq 'requested'){return @{id=$pending.id;body=$pending.body}}
    }
    $covered=@{};foreach($id in @($state.covered)){$covered[[string]$id]=$true}
    $items=@(Get-ChatItems|Where-Object {-not $covered[[string]$_.id]})
    if($items.Count -le 40){return $null}
    $old=@($items|Select-Object -First ($items.Count-16));$ids=@($old|ForEach-Object {[string]$_.id})
    $id=Get-CompactionHash (($old|ConvertTo-Json -Depth 12 -Compress)+'|'+(@($state.applied)-join ','))
    $existing=Read-CompactionTxn $id
    if($existing){$state.pending=$id;Save-CompactionState $state;if($existing.status -eq 'prepared'){[void](Complete-CompactionTxn $existing);return $null};if($existing.status -eq 'requested'){return @{id=$id;body=$existing.body}}}
    $range=@(([datetime]$old[0].ts).ToString('MM-dd'),([datetime]$old[-1].ts).ToString('MM-dd'))
    $txt=($old|ForEach-Object {"$(if($_.role -eq 'me'){'用户'}else{'秘书'})：$($_.text)$(if($_.card){"（确认卡 → $($_.card.who)，$($_.card.status)）"})"})-join "`n"
    $summary=Get-SummaryData;$fold=((Get-Summary).Length+250)-gt 800
    $older=if($fold){((@($summary.stable)+@($summary.segments|Select-Object -SkipLast 1|ForEach-Object {"（$($_.from) ~ $($_.to)）$($_.text)"}))|Where-Object {$_})-join "`n"}else{''}
    $schema=@{type='object';additionalProperties=$false;required=@('segment','stable');properties=@{segment=@{type='string'};stable=@{type='string'}}}
    $ask="segment：把下面这段用户与秘书的对话压缩成不超过 250 字的中文摘要，只保留以后还用得上的信息（用户的偏好、交代过的规则、答应的事、未完成的事、提到的人和时间）。`n"+
      $(if($fold){"stable：再把下面「较早的摘要」合并成不超过 400 字的总述（保留仍然有效的偏好、规则、答应的事）。`n较早的摘要：`n$older`n"}else{"stable：填空字符串。`n"})+"对话：`n$txt"
    $body=@{model='claude-sonnet-5-5';max_tokens=1200;output_config=@{effort='low';format=@{type='json_schema';schema=$schema}};messages=@(@{role='user';content=$ask})}
    $txn=[pscustomobject]@{id=$id;status='requested';ids=$ids;range=$range;body=$body;base_summary_hash=(Get-CompactionHash ($summary|ConvertTo-Json -Depth 8 -Compress));prior_summary_hash='';new_summary=$null;created=(Get-Date).ToString('s')}
    Save-CompactionTxn $txn;$state.pending=$id;Save-CompactionState $state
    @{id=$id;body=$body}
  }
}
function Save-CompactionAnswer([string]$BatchId,$Answer,[switch]$FailAfterSummary){
  Invoke-CompactionLock {
    $txn=Read-CompactionTxn $BatchId;if(-not $txn){throw 'Unknown compaction batch'}
    $state=Get-CompactionState
    if(@($state.applied) -contains $BatchId){return @{applied=$false;id=$BatchId;replayed=$true}}
    if($txn.status -eq 'requested'){
      if(-not $Answer -or -not [string]$Answer.segment){throw 'Empty compaction result'}
      $current=Get-SummaryData;$segments=@($current.segments);$stable=[string]$current.stable
      # 若别处更新过摘要，保留当前版本；旧请求的折叠结果不能覆盖更新。
      $unchanged=(Get-CompactionHash ($current|ConvertTo-Json -Depth 8 -Compress)) -eq $txn.base_summary_hash
      if([string]$Answer.stable -and $unchanged){$stable=[string]$Answer.stable;$segments=@($segments|Select-Object -Last 1)}
      $segments+=@([pscustomobject]@{from=[string]$txn.range[0];to=[string]$txn.range[1];text=[string]$Answer.segment;batch_id=[string]$txn.id})
      $txn.prior_summary_hash=Get-CompactionHash ($current|ConvertTo-Json -Depth 8 -Compress)
      $txn.new_summary=[pscustomobject]@{stable=$stable;segments=$segments};$txn.status='prepared';Save-CompactionTxn $txn
    }
    Complete-CompactionTxn $txn -FailAfterSummary:$FailAfterSummary
  }
}
