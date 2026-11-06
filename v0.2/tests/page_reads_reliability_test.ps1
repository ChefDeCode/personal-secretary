# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
$ErrorActionPreference='Stop'
$v2=Split-Path $PSScriptRoot -Parent
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 '秘书.ps1'),[ref]$null,[ref]$null)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Request-PageRead'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
$script:pass=0;$script:fail=0;$script:reads=0;$script:posted=@()
function Check($Name,$Ok){if($Ok){$script:pass++;'[PASS] '+$Name}else{$script:fail++;'[FAIL] '+$Name}}
function Get-ReadWorkerModules {@()}
function Start-SecWork {param($Key,$Modules,$InputObject,$Code,$Then,[switch]$Replace);$script:job=@{data=$InputObject;code=$Code;then=$Then;key=$Key};$true}
function Post($m){$script:posted+=,$m}
function Read-SlowSynthetic {$script:reads++;Start-Sleep -Milliseconds 120}
function Get-OlderChatItems {Read-SlowSynthetic;@{id='synthetic'}}
function Get-NameVariants($q){Read-SlowSynthetic;'synthetic'}
function Get-Health {Read-SlowSynthetic;@{count=1}}
function Get-MemPageData($q){Read-SlowSynthetic;@{count=1}}
function Get-PeoplePage {@{count=1}}
function Get-FilePage {@{count=1}}
function Get-Memory($id){Read-SlowSynthetic;@{sources=@('synthetic')}}
function Get-MemSource($s){@{id='synthetic'}}
foreach($page in @('older','names','health','memory','source')){
  $script:reads=0;$script:posted=@()
  $sw=[Diagnostics.Stopwatch]::StartNew();Request-PageRead $page @{q='synthetic';id='synthetic';related=$true};$sw.Stop()
  Check ($page+'_submission_under100ms_no_read') ($sw.ElapsedMilliseconds -lt 100 -and $script:reads -eq 0)
  $result=& ([scriptblock]::Create([string]$script:job.code)) $script:job.data
  Check ($page+'_worker_reads_without_ui_callback') ($script:reads -eq 1 -and $script:posted.Count -eq 0)
  & $script:job.then @{ok=$true;data=$result}
  Check ($page+'_result_returns_to_ui') ($script:posted.Count -eq $(if($page -eq 'memory'){3}else{1}))
}
$script:posted=@();& $script:job.then @{ok=$false;data=$null}
Check 'failed_read_does_not_replace_ui_with_empty_data' ($script:posted.Count -eq 0)
'page_reads_reliability_test: {0} pass, {1} fail' -f $script:pass,$script:fail
if($script:fail){exit 1}
