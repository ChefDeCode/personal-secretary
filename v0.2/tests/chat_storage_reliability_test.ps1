# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 合成聊天存储测试：两个短命后台写入器，各8条。可-SkipProcesses只做故障与字段合并。
param([switch]$SkipProcesses)
$ErrorActionPreference='Stop';$v2=Split-Path $PSScriptRoot -Parent
. (Join-Path $v2 'lib_聊天存储.ps1')
function Protect([string]$Text){[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))}
function Unprotect([string]$Text){[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))}
function Write-QualityCard($Item){}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 'lib_v2.ps1'),[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Write-ChatLine','Add-ChatItem','Get-ChatItems','Update-ChatItem','Get-ChatViewItems','Get-OlderChatItems'},$true)){. ([scriptblock]::Create($fn.Extent.Text))}
$script:pass=0;$script:fail=0
function Check([string]$Name,[bool]$Ok){if($Ok){$script:pass++}else{$script:fail++};'[{0}] {1}' -f $(if($Ok){'PASS'}else{'FAIL'}),$Name}
$testRoot=Join-Path $env:TEMP ('secretary_chat_storage_'+[guid]::NewGuid().ToString('n'));[void][IO.Directory]::CreateDirectory($testRoot)
$script:children=@();$script:OriginalAppend=${function:Write-ChatStorageAppendAt}
function Select-Store([string]$Name){$d=Join-Path $testRoot $Name;[void][IO.Directory]::CreateDirectory($d);$script:ChatFile=Join-Path $d 'chat.jsonl';$script:ChatArchive=Join-Path $d 'chat_archive.jsonl'}
function Read-Archive{@(Read-ChatStorage -Archive)}
try{
  $old=@{id='legacy';role='ai';text='original';card=@{status='open';text='old';failed=$false}}
  $one=$old|ConvertTo-Json -Depth 8|ConvertFrom-Json;$two=$old|ConvertTo-Json -Depth 8|ConvertFrom-Json
  $one.card.text='changed';$two.card.failed=$true;Select-Store 'legacy'
  foreach($it in @($old,$one,$two)){[IO.File]::AppendAllText($script:ChatFile,(Protect ($it|ConvertTo-Json -Depth 8 -Compress))+[Environment]::NewLine)}
  $last=@(Get-ChatItems)[0]
  Check 'legacy_stale_full_version_loses_other_field' ($last.card.text -eq 'old' -and $last.card.failed)
  # Real PS 5.1 pipeline values retain their scalar base type through nested conversion.
  $rawDates=@('2030-01-05T10:30:00','2030-01-06T11:00:00')
  $pipelineDates=@($rawDates|ForEach-Object {[Management.Automation.PSObject]::AsPSObject($_)})
  $mappedDates=ConvertTo-ChatStorageValue $pipelineDates
  Check 'pipeline_string_array_preserves_values' (@($mappedDates).Count -eq 2 -and $mappedDates[0] -is [string] -and $mappedDates[0] -ceq $rawDates[0] -and $mappedDates[1] -ceq $rawDates[1])
  $at=[datetime]::ParseExact($rawDates[0],'s',[Globalization.CultureInfo]::InvariantCulture)
  $nested=ConvertTo-ChatStorageValue ([pscustomobject]@{card=[pscustomobject]@{opts=@('synthetic-1','synthetic-2');optVals=$pipelineDates;at=$at;count=2;enabled=$true}})
  Check 'nested_options_and_date_values_remain_scalars' ($nested.card.opts[0] -is [string] -and $nested.card.opts[0] -ceq 'synthetic-1' -and $nested.card.optVals[1] -ceq $rawDates[1] -and $nested.card.count -is [int] -and $nested.card.enabled -is [bool])
  Check 'datetime_base_value_retains_type_and_ticks' ($nested.card.at -is [datetime] -and $nested.card.at.Ticks -eq $at.Ticks)
  Select-Store 'scalar_roundtrip'
  $dateItem=Add-ChatItem @{role='ai';card=@{status='open';opts=@('synthetic-1','synthetic-2');optVals=$pipelineDates;at=$rawDates[0]}}
  $dateRead=@(Get-ChatItems)[0];$dateRead.card.status='closed';Update-ChatItem $dateRead;$dateRead=@(Get-ChatItems)[0]
  Check 'options_dates_survive_storage_and_update_roundtrip' (@($dateRead.card.opts).Count -eq 2 -and $dateRead.card.opts[0] -ceq 'synthetic-1' -and $dateRead.card.optVals[0] -is [string] -and $dateRead.card.optVals[0] -ceq $rawDates[0] -and ([datetime]$dateRead.card.optVals[1]).ToString('s') -ceq $rawDates[1] -and $dateRead.card.at -ceq $rawDates[0])
  Select-Store 'merge'
  $item=Add-ChatItem @{role='ai';text='original';card=@{status='open';text='old';failed=$false}}
  $a=@(Get-ChatItems)[0];$b=@(Get-ChatItems)[0]
  $a.card.text='changed';Update-ChatItem $a;$b.card.failed=$true;Update-ChatItem $b
  $last=@(Get-ChatItems)[0];$history=@(Read-Archive)
  Check 'stale_updates_merge_distinct_nested_fields' ($last.card.text -eq 'changed' -and $last.card.failed)
  Check 'all_archive_versions_preserved' ($history.Count -eq 3 -and $history[0].text -eq 'original' -and $history[0].card.text -eq 'old')
  Check 'update_refreshes_callers_revision' ($b._chat_version -eq $last._chat_version -and $a._chat_version -ne $b._chat_version)
  $c=@(Get-ChatItems)[0]|ConvertTo-Json -Depth 20|ConvertFrom-Json;$d=@(Get-ChatItems)[0]
  $d.card.status='closed';Update-ChatItem $d;$c.card.result=@(@{ok=$true;text='synthetic'});Update-ChatItem $c
  $last=@(Get-ChatItems)[0]
  Check 'json_snapshot_does_not_revert_newer_status' ($last.card.status -eq 'closed' -and $last.card.result.Count -eq 1 -and $last.card.text -eq 'changed')
  $refItem=@(Get-ChatItems)[0];$refCard=$refItem.card;$refCard.text='identity';Update-ChatItem $refItem
  $refCard.failed=$false;Update-ChatItem $refItem
  Check 'update_keeps_nested_card_reference' ([object]::ReferenceEquals($refCard,$refItem.card) -and -not (@(Get-ChatItems)[0].card.failed))
  Select-Store 'view'
  $lines=New-Object Collections.Generic.List[string]
  1..100|ForEach-Object {$it=@{id=('v'+$_);role='me';text='synthetic';ts=('2030-01-01T00:00:'+('{0:00}' -f ($_ % 60)))}
    if($_ -le 5){$it.card=@{status=@('open','sending','scheduled','closed','closed')[$_-1];needsVerification=($_ -eq 4)}}
    $lines.Add((Protect ($it|ConvertTo-Json -Depth 8 -Compress)))}
  [IO.File]::WriteAllLines($script:ChatFile,$lines,(New-Object Text.UTF8Encoding $false))
  $all=@(Get-ChatItems);$view=@(Get-ChatViewItems -Items $all);$older=@(Get-OlderChatItems)
  Check 'view_keeps_recent80_and_all_unresolved_cards' ($view.Count -eq 84 -and @($view.id|Where-Object {$_ -in 'v1','v2','v3','v4'}).Count -eq 4 -and $view[-1].id -eq 'v100')
  Check 'older_view_is_reachable_without_duplicates' ($older.Count -eq 16 -and @($older|Where-Object {$view.id -contains $_.id}).Count -eq 0)
  Check 'view_filter_keeps_all_original_disk_records' (@(Get-ChatItems).Count -eq 100 -and @(Read-Archive).Count -eq 100)
  Select-Store 'after_archive';$script:FaultPath=$script:ChatFile
  function Write-ChatStorageAppendAt([string]$Path,[long]$Offset,[string]$Text){if($Path -eq $script:FaultPath){throw 'synthetic_crash'};& $script:OriginalAppend $Path $Offset $Text}
  $thrown=$false;try{[void](Add-ChatItem @{role='me';text='synthetic'})}catch{$thrown=$true}
  Check 'fault_after_archive_leaves_durable_pending' ($thrown -and (Test-Path -LiteralPath ($script:ChatFile+'.pending')) -and (Test-Path -LiteralPath $script:ChatArchive))
  Set-Item Function:Write-ChatStorageAppendAt $script:OriginalAppend
  $recovered=@(Get-ChatItems);$history=@(Read-Archive)
  Check 'restart_recovers_archive_only_write_once' ($recovered.Count -eq 1 -and $history.Count -eq 1 -and $recovered[0].text -eq 'synthetic')
  [void](Get-ChatItems);[void](Get-ChatItems)
  Check 'recovery_is_idempotent' (@(Read-Archive).Count -eq 1 -and @(Get-Content -LiteralPath $script:ChatFile).Count -eq 1)
  Select-Store 'partial';$script:FaultPath=$script:ChatArchive
  function Write-ChatStorageAppendAt([string]$Path,[long]$Offset,[string]$Text){if($Path -eq $script:FaultPath){throw 'synthetic_crash'};& $script:OriginalAppend $Path $Offset $Text}
  try{[void](Add-ChatItem @{role='me';text='synthetic'})}catch{}
  Set-Item Function:Write-ChatStorageAppendAt $script:OriginalAppend
  $txn=(Unprotect ([IO.File]::ReadAllText($script:ChatFile+'.pending')))|ConvertFrom-Json
  $bytes=[Text.Encoding]::UTF8.GetBytes([string]$txn.archive.text);[IO.File]::WriteAllBytes($script:ChatArchive,[byte[]]$bytes[0..9])
  $recovered=@(Get-ChatItems)
  Check 'partial_append_suffix_recovered_without_truncation' ($recovered.Count -eq 1 -and @(Read-Archive).Count -eq 1 -and (Get-Item -LiteralPath $script:ChatArchive).Length -eq $bytes.Length)
  Check 'transaction_state_committed_atomically' (((Unprotect ([IO.File]::ReadAllText($script:ChatFile+'.pending')))|ConvertFrom-Json).phase -eq 'complete')
  Check 'no_leftover_atomic_temp_files' (@(Get-ChildItem -LiteralPath (Split-Path $script:ChatFile -Parent) -Filter '*.tmp').Count -eq 0)
  Select-Store 'mutex';$name=Get-ChatStorageMutexName;$oldPath=$script:ChatFile;$script:ChatFile=$oldPath.ToUpperInvariant()
  Check 'same_path_casing_uses_same_lock' ((Get-ChatStorageMutexName) -eq $name);$script:ChatFile=$oldPath
  if(-not $SkipProcesses){
    $writer=Join-Path $testRoot 'writer.ps1';$module=(Join-Path $v2 'lib_聊天存储.ps1').Replace("'","''")
    $writerLines=@('param([string]$DataPath,[string]$Prefix)','$ErrorActionPreference=''Stop''','[Diagnostics.Process]::GetCurrentProcess().PriorityClass=''BelowNormal''')
    $writerLines+=('. '''+$module+'''')
    $writerLines+=@('function Protect([string]$Text){[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))}',
      'function Unprotect([string]$Text){[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))}',
      '$script:ChatFile=Join-Path $DataPath ''chat.jsonl'';$script:ChatArchive=Join-Path $DataPath ''chat_archive.jsonl''',
      '1..8|ForEach-Object {Save-ChatStorageItem @{id=($Prefix+$_);role=''me'';ts=''2030-01-01T00:00:00'';text=''synthetic''}}')
    [IO.File]::WriteAllLines($writer,[string[]]$writerLines,(New-Object Text.UTF8Encoding $true));$dataPath=Split-Path $script:ChatFile -Parent
    foreach($prefix in @('a','b')){$script:children+=Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$writer+'"'),'-DataPath',('"'+$dataPath+'"'),'-Prefix',$prefix)}
    foreach($process in $script:children){if(-not $process.WaitForExit(15000)){throw 'synthetic_writer_timeout'}}
    $all=@(Get-ChatItems);$history=@(Read-Archive)
    Check 'two_process_writers_preserve_all_records' ($all.Count -eq 16 -and $history.Count -eq 16 -and @($all.id|Sort-Object -Unique).Count -eq 16)
    Check 'both_background_writers_exit_success' (@($script:children|Where-Object {$_.ExitCode -ne 0}).Count -eq 0)
  }
}catch{Write-Output ('[DIAGNOSTIC] line='+$_.InvocationInfo.ScriptLineNumber+' '+$_.Exception.Message);Check ('unexpected_'+$_.Exception.GetType().Name) $false}
finally{
  Set-Item Function:Write-ChatStorageAppendAt $script:OriginalAppend
  foreach($process in $script:children){if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(3000)};$process.Dispose()}
  $path=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
  if($path.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($path).StartsWith('secretary_chat_storage_')){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}
}
"chat_storage_reliability_test: $script:pass pass, $script:fail fail"
if($script:fail){exit 1}