# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
$ErrorActionPreference = 'Stop'
$v2=Split-Path $PSScriptRoot -Parent
$productRoot=Split-Path $v2 -Parent
$pass=0; $fail=0
function Check($name,$ok){if($ok){$script:pass++}else{$script:fail++}; "[$(if($ok){'PASS'}else{'FAIL'})] $name"}
function Import-TestFunctions([string]$file,[string[]]$names,[hashtable]$replace=@{}){
  $ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$null,[ref]$null)
  foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    if($names -contains $fn.Name){$code=$fn.Body.Extent.Text; $code=$code.Substring(1,$code.Length-2); if($fn.Parameters.Count){$code="param("+(($fn.Parameters|ForEach-Object{$_.Extent.Text}) -join ",")+")`n"+$code}; foreach($key in $replace.Keys){$code=$code.Replace($key,$replace[$key])}; Set-Item -Path ('function:script:'+ $fn.Name) -Value ([scriptblock]::Create($code))}
  }
}
function Done-Test { "RESULT: $script:pass / $($script:pass+$script:fail)"; if($script:fail){exit 1} }

function New-TestNode([string]$name,$kind,[string]$text=''){
  $node=[pscustomobject]@{Current=[pscustomobject]@{Name=$name;ControlType=$kind};Text=$text}
  $node | Add-Member ScriptMethod GetCurrentPattern {param($pattern)
    $range=[pscustomobject]@{Text=$this.Text}; $range | Add-Member ScriptMethod GetText {param($n) $this.Text.Substring(0,[Math]::Min($n,$this.Text.Length))}
    [pscustomobject]@{DocumentRange=$range;Current=[pscustomobject]@{Value=$this.Text}}
  }; $node
}
function New-TestRoot($nodes){
  $rt=[pscustomobject]@{Nodes=@($nodes);Reads=0}
  $rt | Add-Member ScriptMethod FindAll {param($scope,$condition)
    $this.Reads++; if($condition -is [Windows.Automation.PropertyCondition]) { @($this.Nodes | Where-Object {$_.Current.ControlType.Id -eq [int]$condition.Value}) } else { @($this.Nodes) }
  }; $rt
}
