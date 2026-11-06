# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode

function Test-SignedIn { $true }
function New-TestModelResult($body) {
  $uses=@($body.messages|ForEach-Object{$_.content}|Where-Object {$_.type -eq 'tool_use'})
  $hasSend=@($uses|Where-Object name -eq 'propose_send').Count -gt 0
  if($hasSend){return [pscustomobject]@{stop_reason='end_turn';content=@([pscustomobject]@{type='text';text='ready'});usage=@{input_tokens=1;output_tokens=1}}}
  $tool='propose_send';$toolInput=[pscustomobject]@{as_said='明远';text='【秘书测试】synthetic';file_id=''}
  if($script:ModelFixture -eq 'files'){
    if(-not @($uses|Where-Object name -eq 'find_file').Count){
      $tool='find_file';$toolInput=[pscustomobject]@{sender='张三';about='明远';type='';when='last';name_hint=''}
    }else{
      # Selection uses the real local search; the prior real find_file invocation sets provenance.
      $found=Find-Files '张三' '明远' '' 'last' ''
      if($found.top.Count){$toolInput.file_id=[string]$found.top[0].f.id}
    }
  }
  [pscustomobject]@{stop_reason='tool_use';content=@([pscustomobject]@{type='tool_use';id=('synthetic-tool-'+$uses.Count);name=$tool;input=$toolInput});usage=@{input_tokens=1;output_tokens=1}}
}
function Start-Claude($body) { [pscustomobject]@{IsCompleted=$true;Fixture=(New-TestModelResult $body)} }
function Read-Claude($task) { $task.Fixture }
function Start-AccountAI($body,$kind) { Start-Claude $body }
function Read-AccountAI($task) { $task.Fixture }
