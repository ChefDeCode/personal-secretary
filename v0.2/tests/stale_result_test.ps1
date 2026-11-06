# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# Only synthetic persisted actions and actual polling functions. No GUI or sender process.
$ErrorActionPreference='Stop';$v2=Split-Path $PSScriptRoot -Parent
$base=[IO.Path]::GetFullPath($env:TEMP);$testRoot=Join-Path $base ('secretary_stale_'+[guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:ActDir=Join-Path $testRoot 'actions';[void][IO.Directory]::CreateDirectory($script:ActDir);$script:V2Data=$testRoot
function Protect([string]$s){$s};function Unprotect([string]$s){$s}
. (Join-Path $v2 'lib_动作.ps1')
$script:pass=0;$script:fail=0
function Check($n,$ok){if($ok){$script:pass++;'[PASS] '+$n}else{$script:fail++;'[FAIL] '+$n}}
try{
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 '秘书.ps1'),[ref]$null,[ref]$null)
  $names=@('Start-Send','Poll-Sends','Apply-SendResultToCard','Invoke-SendRetry')
  foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $names},$true)){. ([scriptblock]::Create($f.Extent.Text))}
  function Get-Action($id){Get-ActionRecord $id};function Save-Action($a){Save-ReliableAction $a}
  function Set-Prop($o,$k,$v){Set-ActionField $o $k $v}
  function Get-Scheduled{@()};function Post($o){};function Get-TodayView{@()};function Unlock-Foreground{};function Set-ScheduledStatus($id,$s){}
  function Get-Switch($k){$true};function Read-Config{@{features=@{}}}
  function Record-TodoSendEvidence{param($TodoId,$ActionId,[bool]$IsFile,$Text);@{changed=$false}}
  $script:cards=@();function Get-ChatItems{$script:cards};function Update-ChatItem($it){$script:cards=@($it)}
  $script:Launches=0;function Start-Process{$script:Launches++;[pscustomobject]@{Id=0}}
  $script:Sending=@{};$script:SendStart=@{};$script:SendWorkers=@{};$script:SendQueue=$null;$script:FgLockUntil=$null;$script:AppDir=$v2
  $a=[pscustomobject]@{id='synthetic-action';status='confirmed';conv='synthetic';text='synthetic';file=''};Save-ReliableAction $a
  $a=Start-ActionAttempt $a.id 0;$oldAttempt=$a.attempt_id
  $it=[pscustomobject]@{id='synthetic-card';card=[pscustomobject]@{kind='send';actionId=$a.id;status='sending';who='synthetic';text='synthetic'}}
  Update-ChatItem $it;$script:Sending[$a.id]=$it;$script:SendStart[$a.id]=(Get-Date).AddMinutes(-1)
  [void](Save-ActionResult $a.id $false 'synthetic_preflight_failed' @())
  1..40|ForEach-Object{Poll-Sends}
  Check 'failure_never_auto_restarts_after40polls' ($script:Launches -eq 0)
  Check 'failure_is_terminal_until_manual_retry' (-not $script:Sending.ContainsKey($a.id) -and $it.card.failed -and $it.card.actionState -eq 'failed')
  Check 'explicit_retry_starts_exactly_once' ((Invoke-SendRetry $it.id) -eq 'started' -and $script:Launches -eq 1)
  Check 'prior_result_retained_and_not_current' ((Test-Path -LiteralPath (Join-Path $script:ActDir ($a.id+'.result.prev.json'))) -and -not(Test-Path -LiteralPath (Join-Path $script:ActDir ($a.id+'.result.json'))))
  [void](Start-ActionAttempt $a.id 0)
  Write-ActionAtomic (Join-Path $script:ActDir ($a.id+'.result.json')) (@{id=$a.id;attempt_id=$oldAttempt;ok=$true;state='succeeded'}|ConvertTo-Json -Compress)
  function Test-ActionWorkerAlive($a){$true}
  1..40|ForEach-Object{Poll-Sends}
  Check 'stale_result_does_not_complete_current_attempt' ($script:Sending.ContainsKey($a.id) -and $null -eq (Read-ActionResult $a.id))
  Check 'stale_result_cannot_create_extra_senders' ($script:Launches -eq 1)
}finally{
  $resolved=[IO.Path]::GetFullPath($testRoot);$prefix=$base.TrimEnd('\')+'\secretary_stale_'
  if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
'stale_result_test: {0} pass, {1} fail' -f $script:pass,$script:fail
if($script:fail){exit 1}

