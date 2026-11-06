# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
$ErrorActionPreference='Stop'
$v2=Split-Path $PSScriptRoot -Parent
. (Join-Path $v2 'lib_v2.ps1')
. (Join-Path $v2 'lib_后台任务.ps1')
$tempRoot=Join-Path (Split-Path $v2 -Parent) 'review\test-temp';[void][IO.Directory]::CreateDirectory($tempRoot)
$T=Join-Path $tempRoot ('secretary_replied_'+[guid]::NewGuid().ToString('n'));[void][IO.Directory]::CreateDirectory((Join-Path $T 'root\data'))
$override=Join-Path $T 'override.ps1'
$code=@'
$script:Root='__T__\root';$script:V2Data='__T__';$script:DataDir='__T__\root\data';$script:DoneFile='__T__\done.json'
$script:ChatFile='__T__\chat.jsonl';$script:ChatArchive='__T__\chat_archive.jsonl';$script:RemDir='__T__';$script:PredFile='__T__\reply_preds.json';$script:MemDir='__T__';$script:MemMsgFile='__T__\root\data\messages.jsonl';$script:MemChatFile='__T__\chat_archive.jsonl'
'@.Replace('__T__',$T.Replace("'","''"))
[IO.File]::WriteAllText($override,$code,[Text.UTF8Encoding]::new($true));. $override
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 '秘书.ps1'),[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-AutoReplied','Save-AutoReplied','Test-UserReplied','Step-RepliedAlready','Get-Preds','Save-Preds','Close-RepliedIds','Show-TaskTimeQuestions'},$true)){. ([scriptblock]::Create($fn.Extent.Text))}
function Get-ReadWorkerModules {@((Join-Path $v2 'lib_v2.ps1'),$override)}
$script:posted=0;$script:refreshes=0
function Post($x){$script:posted++}
function Request-ReadSnapshot{param([switch]$Force,[switch]$Full)$script:refreshes++}
function RunReplied {
  $script:RepliedLast=[datetime]::MinValue;Step-RepliedAlready
  $sw=[Diagnostics.Stopwatch]::StartNew()
  while((Test-SecWorkPending) -and $sw.ElapsedMilliseconds -lt 30000){Step-SecWork;Start-Sleep -Milliseconds 20}
  if(Test-SecWorkPending){throw 'Synthetic worker timed out'}
}
$script:pass=0;$script:fail=0
function Check($n,$ok){if($ok){$script:pass++}else{$script:fail++};Write-Output ('[{0}] {1}' -f $(if($ok){'PASS'}else{'FAIL'}),$n)}
$t0=(Get-Date).AddHours(-3)
function M($min,$me,$who='SYNTHETIC',$text=''){@{t=$t0.AddMinutes($min);me=$me;who=$who;text=$text}}
function Todo($id,$cat,$what,$conv){@{id=$id;ts=$t0.ToString('s');类别=$cat;事情=(Protect $what);谁=(Protect $conv);conv=(Protect $conv);原文时间=$t0.ToString('s');原文=(Protect 'SYNTHETIC');app='微信'}|ConvertTo-Json -Compress}
function Msg($key,$min,$conv,$text){@{key=$key;ts=$t0.AddMinutes($min).ToString('s');conv=(Protect $conv);sender=(Protect '我');text=(Protect $text);app='微信'}|ConvertTo-Json -Compress}
try{
  Check 'single_response_detected' (Test-UserReplied @((M 0 $false),(M 5 $true)) $t0 'SYNTHETIC' $false)
  Check 'other_side_only_not_response' (-not (Test-UserReplied @((M 0 $false),(M 5 $false)) $t0 'SYNTHETIC' $false))
  Check 'group_direct_response' (Test-UserReplied @((M 0 $false),(M 3 $true)) $t0 'SYNTHETIC' $true)
  Check 'group_interleaving_kept' (-not (Test-UserReplied @((M 0 $false 'A'),(M 2 $false 'B'),(M 3 $true '我' '收到')) $t0 'SYNTHETIC' $true))
  Check 'group_explicit_reference' (Test-UserReplied @((M 0 $false),(M 2 $false 'B'),(M 3 $true '我' '@SYNTHETIC 收到')) $t0 'SYNTHETIC' $true)
  Check 'earlier_response_ignored' (-not (Test-UserReplied @((M -5 $true)) $t0 'SYNTHETIC' $false))
  [IO.File]::WriteAllLines((Join-Path $script:DataDir 'todos.jsonl'),[string[]]@((Todo a '需要你回的' '周报材料' 'SYNTHETIC_A'),(Todo b '你答应别人的' '接口资料' 'SYNTHETIC_B')),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllLines((Join-Path $script:DataDir 'messages.jsonl'),[string[]]@((Msg m1 4 'SYNTHETIC_A' '晚上聊')),[Text.UTF8Encoding]::new($false))
  Save-Preds @{a=@{opts=@('SYNTHETIC');fallback=$false}}
  RunReplied
  Check 'actual_worker_completed' ($script:SecWorkStats.completed -ge 1 -and $script:SecWorkStats.failed -eq 0)
  Check 'ordinary_response_keeps_task' (-not (Get-DoneSet).a -and (Get-TrackedTodos|Where-Object id -eq a).response_state -eq 'acknowledged')
  Check 'unrelated_promise_kept' (-not (Get-DoneSet).b)
  [IO.File]::AppendAllLines((Join-Path $script:DataDir 'messages.jsonl'),[string[]]@((Msg m2 5 'SYNTHETIC_A' '发你了')),[Text.UTF8Encoding]::new($false));RunReplied
  Check 'explicit_completion_closes_only_linked_task' ((Get-DoneSet).a -and -not (Get-DoneSet).b)
  Check 'completion_removes_encrypted_prediction' (-not (Get-Preds).ContainsKey('a') -and (Get-AutoReplied).a -eq 'auto')
  Check 'completion_requests_view_refresh' ($script:refreshes -ge 1)
  Set-Done a $false
  [IO.File]::AppendAllLines((Join-Path $script:DataDir 'messages.jsonl'),[string[]]@((Msg m3 6 'SYNTHETIC_A' '搞定了')),[Text.UTF8Encoding]::new($false));RunReplied
  Check 'undo_blocks_later_completion' (-not (Get-DoneSet).a)
}finally{
  if($script:SecWorkPool){try{$script:SecWorkPool.Close();$script:SecWorkPool.Dispose()}catch{}}
  $resolved=[IO.Path]::GetFullPath($T);$prefix=[IO.Path]::GetFullPath($tempRoot).TrimEnd('\')+'\secretary_replied_'
  if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
Write-Output ('replied_test: {0} pass, {1} fail' -f $script:pass,$script:fail)
if($script:fail){exit 1}
