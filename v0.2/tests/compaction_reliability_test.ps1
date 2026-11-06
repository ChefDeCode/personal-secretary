# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
$ErrorActionPreference='Stop'
$v2=Split-Path $PSScriptRoot -Parent
$tempRoot=Join-Path (Split-Path $v2 -Parent) 'review\test-temp'
[void][IO.Directory]::CreateDirectory($tempRoot)
$testRoot=Join-Path $tempRoot ('secretary_compaction_'+[guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:pass=0;$script:fail=0
function Check([string]$name,[bool]$ok){if($ok){$script:pass++}else{$script:fail++};Write-Output ('[{0}] {1}' -f $(if($ok){'PASS'}else{'FAIL'}),$name)}
function Protect([string]$s){[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))}
function Unprotect([string]$s){if(-not $s){return ''};[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))}
function Get-ChatItems {
  if(Test-Path -LiteralPath $script:ChatFile){foreach($line in [IO.File]::ReadLines($script:ChatFile,[Text.Encoding]::UTF8)){if($line){(Unprotect $line)|ConvertFrom-Json}}}
}
$v2Ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 'lib_v2.ps1'),[ref]$null,[ref]$null)
foreach($fn in $v2Ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-SummaryData','Get-Summary'},$true)){. ([scriptblock]::Create($fn.Extent.Text))}
. (Join-Path $v2 'lib_提醒.ps1')
. (Join-Path $v2 'lib_上下文维护.ps1')
function New-Scenario([string]$name){
  $script:V2Data=Join-Path $testRoot $name;[void][IO.Directory]::CreateDirectory($script:V2Data)
  $script:ChatFile=Join-Path $script:V2Data 'chat.jsonl';$script:ChatArchive=Join-Path $script:V2Data 'chat_archive.jsonl';$script:SummaryFile=Join-Path $script:V2Data 'summary.json'
}
function Add-SyntheticChat([int]$Start,[int]$Count){
  $lines=@(for($n=$Start;$n -lt ($Start+$Count);$n++){Protect (@{id=('synthetic-'+$n);ts=([datetime]'2026-11-04T12:00:00').AddSeconds($n).ToString('s');role='me';text=('SYNTHETIC_'+$n)}|ConvertTo-Json -Compress)})
  foreach($path in @($script:ChatFile,$script:ChatArchive)){[IO.File]::AppendAllLines($path,[string[]]$lines,[Text.UTF8Encoding]::new($false))}
}
function Save-SyntheticSummary($s){Write-FileAtomic $script:SummaryFile (Protect ($s|ConvertTo-Json -Depth 8 -Compress))}
try{
  # 复现原 Poll-Compaction 的 WriteAllLines(CompactKeep)：只在隔离合成文件执行原危险语句。
  New-Scenario 'before';Add-SyntheticChat 0 50;$keep=@(Get-ChatItems|Select-Object -Last 16);Add-SyntheticChat 50 1
  $lines=foreach($it in $keep){Protect ($it|ConvertTo-Json -Depth 8 -Compress)}
  [IO.File]::WriteAllLines($script:ChatFile,[string[]]@($lines))
  Check 'baseline_repro_chat_trimmed' (@(Get-ChatItems).Count -eq 16)
  Check 'baseline_repro_concurrent_append_lost' (-not @(Get-ChatItems|Where-Object id -eq 'synthetic-50').Count)

  New-Scenario 'normal';Add-SyntheticChat 0 50
  $work=New-CompactionWork;$same=New-CompactionWork;$txn=Read-CompactionTxn $work.id
  Check 'plan_keeps_original_model_and_limits' ($work.body.model -eq 'claude-sonnet-5-5' -and $work.body.max_tokens -eq 1200 -and $work.body.output_config.effort -eq 'low')
  Check 'plan_covers_only_older_rows' (@($txn.ids).Count -eq 34)
  Check 'pending_plan_survives_repeat' ($work.id -eq $same.id)
  Add-SyntheticChat 50 2
  $chatBefore=[IO.File]::ReadAllText($script:ChatFile);$archiveBefore=[IO.File]::ReadAllText($script:ChatArchive)
  $r=Save-CompactionAnswer $work.id ([pscustomobject]@{segment='SYNTHETIC_SUMMARY';stable=''})
  $savedSummary=Get-SummaryData
  # PS5 会把 @(Get-SummaryData).segments 的单元素枚举成 PSCustomObject，其 Count 是空值。
  Check 'summary_saved_once' ($r.applied -and @($savedSummary.segments).Count -eq 1 -and $savedSummary.segments[0].text -eq 'SYNTHETIC_SUMMARY' -and $savedSummary.segments[0].batch_id -eq $work.id)
  Check 'all_chat_bytes_preserved' ([IO.File]::ReadAllText($script:ChatFile) -ceq $chatBefore -and @(Get-ChatItems).Count -eq 52)
  Check 'all_archive_bytes_preserved' ([IO.File]::ReadAllText($script:ChatArchive) -ceq $archiveBefore)
  $summaryBefore=[IO.File]::ReadAllText($script:SummaryFile)
  $again=Save-CompactionAnswer $work.id ([pscustomobject]@{segment='DIFFERENT_DUPLICATE_CALLBACK';stable=''})
  Check 'duplicate_callback_is_idempotent' ($again.replayed -and -not $again.applied -and [IO.File]::ReadAllText($script:SummaryFile) -ceq $summaryBefore)
  . (Join-Path $v2 'lib_上下文维护.ps1')
  Check 'restart_uses_persisted_cursor' (-not (New-CompactionWork) -and @(Get-CompactionState).covered.Count -eq 34)
  Add-SyntheticChat 52 30;$second=New-CompactionWork;$secondTxn=Read-CompactionTxn $second.id
  Check 'next_batch_excludes_prior_rows' (@($secondTxn.ids).Count -eq 32 -and -not (@($secondTxn.ids)|Where-Object {$_ -in @($txn.ids)}))
  [void](Save-CompactionAnswer $second.id ([pscustomobject]@{segment='SYNTHETIC_SECOND';stable=''}))
  Check 'next_batch_retains_full_source' (@(Get-ChatItems).Count -eq 82 -and @(Get-CompactionState).covered.Count -eq 66)

  New-Scenario 'crash';Add-SyntheticChat 0 50;$work=New-CompactionWork;$crashed=$false
  try{[void](Save-CompactionAnswer $work.id ([pscustomobject]@{segment='SYNTHETIC_CRASH';stable=''}) -FailAfterSummary)}catch{if($_.Exception.Message -eq 'SYNTHETIC_CRASH_AFTER_SUMMARY'){$crashed=$true}else{throw}}
  Check 'crash_leaves_durable_prepared_result' ($crashed -and (Read-CompactionTxn $work.id).status -eq 'prepared' -and (Get-CompactionState).pending -eq $work.id)
  $summaryBefore=[IO.File]::ReadAllText($script:SummaryFile)
  . (Join-Path $v2 'lib_上下文维护.ps1');[void](New-CompactionWork)
  $savedSummary=Get-SummaryData
  Check 'restart_replays_without_duplicate_summary' (@($savedSummary.segments).Count -eq 1 -and $savedSummary.segments[0].batch_id -eq $work.id -and [IO.File]::ReadAllText($script:SummaryFile) -ceq $summaryBefore)
  Check 'restart_advances_cursor_after_summary' (@(Get-CompactionState).covered.Count -eq 34 -and -not (Get-CompactionState).pending -and (Read-CompactionTxn $work.id).status -eq 'applied')
  Check 'restart_never_rewrites_originals' (@(Get-ChatItems).Count -eq 50 -and [IO.File]::ReadAllText($script:ChatFile) -ceq [IO.File]::ReadAllText($script:ChatArchive))

  New-Scenario 'concurrent_summary';Add-SyntheticChat 0 50
  Save-SyntheticSummary ([pscustomobject]@{stable='ORIGINAL_STABLE';segments=@([pscustomobject]@{from='11-01';to='11-01';text='ORIGINAL_SEGMENT'})})
  $work=New-CompactionWork
  Save-SyntheticSummary ([pscustomobject]@{stable='NEW_STABLE';segments=@([pscustomobject]@{from='11-02';to='11-02';text='NEW_SEGMENT'})})
  [void](Save-CompactionAnswer $work.id ([pscustomobject]@{segment='SYNTHETIC_APPEND';stable='STALE_FOLD'}))
  $s=Get-SummaryData
  Check 'concurrent_summary_update_preserved' ($s.stable -eq 'NEW_STABLE' -and @($s.segments).Count -eq 2 -and $s.segments[0].text -eq 'NEW_SEGMENT')

  New-Scenario 'crash_then_summary_update';Add-SyntheticChat 0 50;$work=New-CompactionWork
  try{[void](Save-CompactionAnswer $work.id ([pscustomobject]@{segment='SYNTHETIC_RECOVER';stable=''}) -FailAfterSummary)}catch{if($_.Exception.Message -ne 'SYNTHETIC_CRASH_AFTER_SUMMARY'){throw}}
  $s=Get-SummaryData;$s.stable='UPDATED_AFTER_CRASH';Save-SyntheticSummary $s
  [void](New-CompactionWork);$s=Get-SummaryData
  Check 'replay_keeps_later_summary_update' ($s.stable -eq 'UPDATED_AFTER_CRASH' -and @($s.segments).Count -eq 1)
  Check 'transaction_payload_remains_encrypted' ((Get-Content -LiteralPath (Get-CompactionTxnPath $work.id) -Raw) -notmatch 'SYNTHETIC_RECOVER')
}finally{
  $resolved=[IO.Path]::GetFullPath($testRoot);$prefix=[IO.Path]::GetFullPath($tempRoot).TrimEnd('\')+'\secretary_compaction_'
  if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
Write-Output ('compaction_reliability_test: {0} pass, {1} fail' -f $script:pass,$script:fail)
if($script:fail){exit 1}
