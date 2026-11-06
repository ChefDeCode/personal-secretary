# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
$ErrorActionPreference='Stop'
$v2=Split-Path $PSScriptRoot -Parent
$tempRoot=Join-Path (Split-Path $v2 -Parent) 'review\test-temp';[void][IO.Directory]::CreateDirectory($tempRoot)
$testRoot=Join-Path $tempRoot ('secretary_task_reliability_'+[guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:pass=0;$script:fail=0
function Check([string]$name,[bool]$ok){if($ok){$script:pass++}else{$script:fail++};Write-Output ('[{0}] {1}' -f $(if($ok){'PASS'}else{'FAIL'}),$name)}
function Protect([string]$s){[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))}
function Unprotect([string]$s){if(-not $s){return ''};[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))}
function Write-Quality($x){}
function Close-ResolvedReminders{}
function Read-Jsonl([string]$name){$f=Join-Path $script:DataDir $name;if(Test-Path -LiteralPath $f){foreach($l in [IO.File]::ReadLines($f,[Text.Encoding]::UTF8)){if($l){$l|ConvertFrom-Json}}}}
. (Join-Path $v2 'lib_提醒.ps1')
. (Join-Path $v2 'lib_事项.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 'lib_v2.ps1'),[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-DoneSet','Set-Done','Get-Today','Resolve-Other'},$true)){. ([scriptblock]::Create($fn.Extent.Text))}
function New-Scenario([string]$name){$script:V2Data=Join-Path $testRoot $name;$script:DataDir=Join-Path $script:V2Data 'source';$script:RemDir=$script:V2Data;$script:DoneFile=Join-Path $script:V2Data 'done.json';[void][IO.Directory]::CreateDirectory($script:DataDir);$script:TaskHistorySig=$null;$script:TaskHistoryCache=@()}
$now=[datetime]'2026-11-04T12:00:00';$yesterday=$now.AddDays(-1)
function Add-Todo([string]$id,[string]$what,[string]$category='你答应别人的',[string]$due='周五',[string]$app='微信',[string]$conv='SYNTHETIC'){
  $t=[ordered]@{id=$id;ts=$yesterday.ToString('s');类别=$category;事情=(Protect $what);谁=(Protect 'SYNTHETIC');conv=(Protect $conv);截止=(Protect $due);原文=(Protect ('ORIGINAL_'+$id));原文时间=$yesterday.ToString('s');app=$app;source_keys=@('source-'+$id);message_key='source-'+$id}
  [IO.File]::AppendAllLines((Join-Path $script:DataDir 'todos.jsonl'),[string[]]@(($t|ConvertTo-Json -Compress)),[Text.UTF8Encoding]::new($false));$t
}
function Add-Message([string]$id,[string]$text,[datetime]$at=$now,[string]$app='微信',[string]$conv='SYNTHETIC',[string]$reply='',[string]$taskId='',[long]$sequence=0){
  $m=@{key=$id;ts=$at.ToString('s');sender=(Protect '我');text=(Protect $text);conv=(Protect $conv);app=$app;reply_key=$reply;task_id=$taskId;queue_sequence=$sequence}
  [IO.File]::AppendAllLines((Join-Path $script:DataDir 'messages.jsonl'),[string[]]@(($m|ConvertTo-Json -Compress)),[Text.UTF8Encoding]::new($false))
}
try{
  New-Scenario 'crossday';$raw=Add-Todo 'a' '周报材料';$sourceBefore=[IO.File]::ReadAllText((Join-Path $script:DataDir 'todos.jsonl'))
  Check 'cross_day_open_survives' (@(Get-Today $now).Count -eq 1)
  Check 'original_category_preserved' ((Get-Today $now).group -eq 'promise')
  Check 'future_bucket' ((Get-Today $now).due_bucket -eq 'soon')
  Add-Message 'm1' '晚上聊';[void](Get-TaskReplyTransitions $now)
  Check 'ordinary_reply_does_not_complete' (-not (Get-Today $now).done)
  Check 'ordinary_reply_records_response' ((Get-Today $now).response_state -eq 'acknowledged')
  Add-Message 'm2' '改到周六' $now.AddMinutes(1);[void](Get-TaskReplyTransitions $now)
  $t=@(Get-TrackedTodos)
  Check 'reschedule_keeps_one_identity' ($t.Count -eq 1 -and $t[0].id -eq 'a')
  Check 'reschedule_date_local' ([datetime]$t[0].due_at -eq [datetime]'2026-11-07T23:59:00')
  Check 'original_quote_survives_revision' ($t[0].quote -eq 'ORIGINAL_a')
  Check 'history_versions_retained' (@(Get-TaskHistory).Count -eq 2)
  $r=Record-TodoSendEvidence -TodoId a -ActionId send1 -IsFile -Now $now.AddHours(1)
  Check 'verified_file_completes_linked_task' ($r.completed -and (Get-Today $now).done)
  $hist=@(Get-TaskHistory).Count;[void](Record-TodoSendEvidence -TodoId a -ActionId send1 -IsFile)
  Check 'evidence_idempotent' (@(Get-TaskHistory).Count -eq $hist)
  Set-Done a $false
  Check 'undo_reopens' (-not (Get-Today $now).done)
  [void](Record-TodoSendEvidence -TodoId a -ActionId send2 -IsFile)
  Check 'undo_blocks_future_auto_completion' (-not (Get-Today $now).done)
  $script:TaskHistorySig=$null;$script:TaskHistoryCache=@()
  Check 'restart_keeps_undo_protection' ([bool](Get-TrackedTodos).no_auto_complete)
  Check 'source_never_rewritten' ($sourceBefore -ceq [IO.File]::ReadAllText((Join-Path $script:DataDir 'todos.jsonl')))
  New-Scenario 'multi';[void](Add-Todo a '周报材料');[void](Add-Todo b '接口设计')
  Add-Message m1 '搞定了';[void](Get-TaskReplyTransitions $now)
  Check 'ambiguous_completion_keeps_both' (@(Get-TrackedTodos).Count -eq 2)
  Add-Message m2 '接口设计搞定了' $now.AddMinutes(1);[void](Get-TaskReplyTransitions $now)
  Check 'topic_specific_completion_only_one' (@(Get-TrackedTodos).Count -eq 1 -and (Get-TrackedTodos).id -eq 'a')
  New-Scenario 'crossapp';[void](Add-Todo a '周报材料');[void](Add-Todo b '接口设计' '需要你回的' '' 'Outlook')
  Add-Message m1 '搞定了' $now 'Outlook';[void](Get-TaskReplyTransitions $now)
  Check 'same_name_cross_app_isolated' (@(Get-TrackedTodos).Count -eq 1 -and (Get-TrackedTodos).id -eq 'a')
  New-Scenario 'defer';[void](Add-Todo a '处理方案' '需要你回的' '')
  Add-Message m1 '等我一下';[void](Get-TaskReplyTransitions $now)
  $t=Get-TrackedTodos
  Check 'delay_converts_reply_to_promise' ($t.category -eq '你答应别人的' -and $t.response_state -eq 'promised')
  Check 'unknown_date_not_invented' ($t.needs_time -and -not $t.due_at)
  Check 'unclear_time_asks_once' (@(Claim-TaskTimeQuestions).Count -eq 1 -and @(Claim-TaskTimeQuestions).Count -eq 0)
  $future=(Get-Date).AddSeconds(61)
  Check 'undelivered_question_recovers_after_restart' (@(Claim-TaskTimeQuestions $future).Count -eq 1)
  Confirm-TaskTimeQuestion a $future
  $script:TaskHistorySig=$null
  Check 'delivered_question_not_repeated' (@(Claim-TaskTimeQuestions $future.AddHours(1)).Count -eq 0)
  [void](Set-TaskDueAnswer a '明天下午3点' $now)
  Check 'answer_updates_same_task' (@(Get-TrackedTodos).Count -eq 1 -and [datetime](Get-TrackedTodos).due_at -eq [datetime]'2026-11-05T15:00:00')
  New-Scenario 'unrelated';[void](Add-Todo a '周报材料')
  Add-Message m1 '游戏搞定了';[void](Get-TaskReplyTransitions $now)
  Check 'other_topic_completion_kept' (-not (Get-Today $now).done)
  Add-Message m2 '周报材料还没搞定了' $now.AddMinutes(1);[void](Get-TaskReplyTransitions $now)
  Check 'negated_completion_kept' (-not (Get-Today $now).done)
  New-Scenario 'merge';[void](Add-Todo a '周报材料')
  $cand=[pscustomobject]@{id='new';app='微信';conv=(Protect 'SYNTHETIC');事情=(Protect '周报材料');原文=(Protect '改到周六');截止=(Protect '周六');原文时间=$now.ToString('s')}
  $m=Merge-TaskCandidate $cand;$n=@(Get-TaskHistory).Count;$again=Merge-TaskCandidate $cand
  Check 'queue_revision_reuses_existing_task' ($m.updated -and -not $m.candidate -and $m.id -eq 'a' -and @(Get-TrackedTodos).Count -eq 1)
  Check 'queue_revision_replay_no_duplicate' ($again.updated -and @(Get-TaskHistory).Count -eq $n)
  $beforeDue=(Get-TrackedTodos).due_at;$cand.id='new-content';$cand.原文=Protect '周报材料改成周报详细版';$cand.事情=Protect '周报详细版';$cand.截止=Protect ''
  [void](Merge-TaskCandidate $cand)
  Check 'content_revision_preserves_deadline_and_original' ((Get-TrackedTodos).what -eq '周报详细版' -and (Get-TrackedTodos).due_at -eq $beforeDue -and (Get-TrackedTodos).quote -eq 'ORIGINAL_a')
  New-Scenario 'revision_old_and_new_date';[void](Add-Todo a '我周五发周报材料')
  $dateCandidate=[pscustomobject]@{id='date-revision';app='微信';conv=(Protect 'SYNTHETIC');事情=(Protect '周报材料');原文=(Protect '我周五发周报材料改到周六');截止=(Protect '周六');原文时间=$now.ToString('s')}
  [void](Merge-TaskCandidate $dateCandidate)
  Check 'reschedule_uses_new_date_when_old_date_repeated' ([datetime](Get-TrackedTodos).due_at -eq [datetime]'2026-11-07T23:59:00' -and @(Get-TrackedTodos).Count -eq 1)
  $file=Get-TaskJournalPath;[IO.File]::AppendAllText($file,'partial-corrupt');[void](Update-TrackedTask a @{reason='verified'} 'recovery')
  Check 'partial_history_tail_does_not_lose_latest' ((Get-TrackedTodos).reason -eq 'verified')
  New-Scenario 'buckets';[void](Add-Todo a 'A' '需要你回的' '2026-11-04T17:00:00');[void](Add-Todo b 'B' '有截止时间的' '2026-11-02T12:00:00');[void](Add-Todo c 'C' '你答应别人的' '')
  $buckets=@(Get-Today $now);Check 'three_remaining_date_buckets' (@($buckets|Where-Object due_bucket -eq today).Count -eq 1 -and @($buckets|Where-Object due_bucket -eq overdue).Count -eq 1 -and @($buckets|Where-Object due_bucket -eq undated).Count -eq 1)
  New-Scenario 'legacy';$legacy=Add-Todo a 'LEGACY';$legacy.Remove('id');[IO.File]::WriteAllLines((Join-Path $script:DataDir 'todos.jsonl'),[string[]]@(($legacy|ConvertTo-Json -Compress)),[Text.UTF8Encoding]::new($false));$oldId=($legacy.ts+'|'+$legacy.事情).GetHashCode().ToString('x8')
  Check 'legacy_identity_compatible' ((Get-Today $now).id -eq $oldId)
  Write-FileAtomic $script:DoneFile (ConvertTo-Json @($oldId))
  Check 'legacy_completion_compatible' ((Get-Today $now).done)
  Write-FileAtomic $script:DoneFile '[]';$kept=@{};$kept[$oldId]='kept';Write-FileAtomic (Join-Path $script:V2Data 'auto_replied.json') ($kept|ConvertTo-Json -Compress)
  [void](Record-TodoSendEvidence -TodoId $oldId -ActionId legacy-send -IsFile)
  Check 'legacy_undo_marker_preserved' (-not (Get-Today $now).done -and (Get-TrackedTodos).no_auto_complete)
  New-Scenario 'cancel';[void](Add-Todo a '周报材料');Add-Message m1 '不用了';[void](Get-TaskReplyTransitions $now)
  Check 'explicit_cancellation_closes_without_deleting' (@(Get-TrackedTodos).Count -eq 0 -and @(Get-TrackedTodos -IncludeClosed).Count -eq 1 -and @(Read-Jsonl 'todos.jsonl').Count -eq 1)
  New-Scenario 'word_collision';[void](Add-Todo a '预订会议室');[void](Add-Todo b '提交财务报表');Add-Message m1 '会议室空调维修搞定了';[void](Get-TaskReplyTransitions $now)
  Check 'shared_word_is_not_completion_evidence' (@(Get-TrackedTodos).Count -eq 2)
  New-Scenario 'short_topic';[void](Add-Todo a '会议室');Add-Message m1 '会议室空调维修搞定了';[void](Get-TaskReplyTransitions $now)
  Check 'short_subject_with_new_action_not_complete' (-not (Get-Today $now).done)
  New-Scenario 'cancel_collision';[void](Add-Todo a '提交项目资料')
  $bad=[pscustomobject]@{id='other';app='微信';conv=(Protect 'SYNTHETIC');事情=(Protect '午餐取消了');原文=(Protect '午餐取消了');截止=(Protect '');原文时间=$now.ToString('s')}
  $m=Merge-TaskCandidate $bad
  Check 'unrelated_single_task_cancellation_not_merged' (-not $m.updated -and @(Get-TrackedTodos).Count -eq 1)
  New-Scenario 'same_second';[void](Add-Todo a '周报材料');Add-Message m1 '搞定了' $yesterday '微信' 'SYNTHETIC' '' 'a';[void](Get-TaskReplyTransitions $now)
  Check 'same_second_explicit_reference_processed' ((Get-Today $now).done)
  New-Scenario 'same_second_sequence';$raw=Add-Todo a '周报材料';$raw.source_sequence=10
  [IO.File]::WriteAllLines((Join-Path $script:DataDir 'todos.jsonl'),[string[]]@(($raw|ConvertTo-Json -Compress)),[Text.UTF8Encoding]::new($false))
  Add-Message early '搞定了' $yesterday '微信' 'SYNTHETIC' '' 'a' 9;[void](Get-TaskReplyTransitions $now)
  Check 'older_sequence_not_applied_despite_same_second' (-not (Get-Today $now).done)
  Add-Message later '搞定了' $yesterday '微信' 'SYNTHETIC' '' '' 11;[void](Get-TaskReplyTransitions $now)
  Check 'later_sequence_processed_despite_same_second' ((Get-Today $now).done)
  $atomic=Join-Path $script:V2Data 'atomic.json';Write-FileAtomic $atomic '{"value":1}';Write-FileAtomic $atomic '{"value":2}'
  Check 'atomic_replacement_complete' ((Get-Content -LiteralPath $atomic -Raw|ConvertFrom-Json).value -eq 2 -and @(Get-ChildItem -LiteralPath $script:V2Data -Filter '*.tmp').Count -eq 0)
}finally{
  $resolved=[IO.Path]::GetFullPath($testRoot);$prefix=[IO.Path]::GetFullPath($tempRoot).TrimEnd('\')+'\secretary_task_reliability_'
  if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
Write-Output ('task_reliability_test: {0} pass, {1} fail' -f $script:pass,$script:fail)
if($script:fail){exit 1}
