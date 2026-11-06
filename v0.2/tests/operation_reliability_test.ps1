# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
$ErrorActionPreference='Stop';$v2=Split-Path $PSScriptRoot -Parent
$base=[IO.Path]::GetFullPath($env:TEMP);$testRoot=Join-Path $base ('secretary_operations_'+[guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($testRoot);$script:ActDir=Join-Path $testRoot 'actions';[void][IO.Directory]::CreateDirectory($script:ActDir)
function Protect([string]$s){$s};function Unprotect([string]$s){$s}
. (Join-Path $v2 'lib_动作.ps1')
$script:pass=0;$script:fail=0
function Check($n,$ok){if($ok){$script:pass++;'[PASS] '+$n}else{$script:fail++;'[FAIL] '+$n}}
try{
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 '秘书.ps1'),[ref]$null,[ref]$null)
  foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'On-Choose','Repair-LocalOperationCards'},$true)){. ([scriptblock]::Create($f.Extent.Text))}
  function Post($m){};function Set-Prop($o,$k,$v){Set-ActionField $o $k $v}
  $script:cards=@();$script:calls=0;$script:mode='success';$script:runningSeen=$false
  function Get-ChatItems{$script:cards};function Update-ChatItem($it){$script:cards=@($script:cards|Where-Object id -ne $it.id)+@($it)}
  function New-Card($id){$c=[pscustomobject]@{id=$id;card=[pscustomobject]@{kind='event';status='open';result=@()}};Update-ChatItem $c;$c}
  function On-ChooseCore($id,$k,$text){
    $script:calls++;$script:runningSeen=(Get-LocalOperationState $id).state -eq 'running'
    if($script:mode -eq 'throw'){throw 'synthetic_interruption'}
    $c=$script:cards|Where-Object id -eq $id;$c.card.status='closed';$c.card.result=@(@{ok=($script:mode -eq 'success')});Update-ChatItem $c
  }
  $c=New-Card 'one';On-Choose 'one' 1 ''
  Check 'running_is_durable_before_effect' $script:runningSeen
  Check 'success_persists_operation_and_card' ((Get-LocalOperationState 'one').state -eq 'succeeded' -and $c.card.actionState -eq 'succeeded')
  $c.card.status='open';On-Choose 'one' 1 ''
  Check 'success_blocks_duplicate_execution' ($script:calls -eq 1)
  $c=New-Card 'two';$script:mode='throw';On-Choose 'two' 1 ''
  Check 'exception_preserves_unknown_state' ((Get-LocalOperationState 'two').state -eq 'unknown' -and $c.card.actionState -eq 'unknown')
  $c.card.status='open';On-Choose 'two' 1 ''
  Check 'unknown_blocks_duplicate_execution' ($script:calls -eq 2)
  $c=New-Card 'three';$script:mode='failed';On-Choose 'three' 1 ''
  Check 'reported_failure_is_not_marked_success' ((Get-LocalOperationState 'three').state -eq 'failed' -and $c.card.actionState -eq 'failed')
  $c=New-Card 'four';[void](Set-LocalOperationState 'four' 'running');Repair-LocalOperationCards
  Check 'restart_marks_interruption_unknown_without_reexecution' ((Get-LocalOperationState 'four').state -eq 'unknown' -and $c.card.actionState -eq 'unknown' -and $script:calls -eq 3)
  $script:rule='do';function Get-CardRule($c){$script:rule}
  $c=New-Card 'auto-success';Set-Prop $c.card 'auto' $true;$script:mode='success';On-Choose $c.id 1 ''
  Check 'auto_success_keeps_existing_explanation' (@($c.card.result|Where-Object {$_.text -match '按你的设置'}).Count -eq 1)
  $c=New-Card 'auto-failed';Set-Prop $c.card 'auto' $true;$script:mode='failed';On-Choose $c.id 1 ''
  Check 'auto_failure_does_not_claim_arranged' (@($c.card.result|Where-Object {$_.text -match '按你的设置'}).Count -eq 0)
  $c=New-Card 'auto-revoked';Set-Prop $c.card 'auto' $true;$script:rule='ask';$before=$script:calls;On-Choose $c.id 1 ''
  Check 'changed_rule_is_rechecked_before_automatic_effect' ($script:calls -eq $before -and $c.card.status -eq 'open')
}finally{
  $resolved=[IO.Path]::GetFullPath($testRoot);$prefix=$base.TrimEnd('\')+'\secretary_operations_'
  if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
'operation_reliability_test: {0} pass, {1} fail' -f $script:pass,$script:fail
if($script:fail){exit 1}
