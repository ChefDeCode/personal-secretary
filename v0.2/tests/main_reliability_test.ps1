# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 '秘书.ps1'), [ref]$null, [ref]$errors)
$script:pass = 0; $script:fail = 0
function Check([string]$id, [bool]$ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; '[{0}] {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }),$id }
Check 'main-parse' (@($errors).Count -eq 0)
function Post($o) {}
function Add-ChatItem($o) { if ($o.role -eq 'me') { $script:me++ }; $o }
function Get-ChatItems { @() }
function Get-QualityNoteKind([string]$t) { if ($t -eq 'synthetic-feedback') { 'incorrect' } else { '' } }
function Write-Quality($o) { $script:notes++ }
function Start-Turn([string]$t) { $script:turns++ }
$handler = $ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Handle-UserSay' }, $true)
if ($handler) { . ([scriptblock]::Create($handler.Extent.Text)) }
$switches = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.SwitchStatementAst] }, $true))
$n = 0
foreach ($sw in $switches) {
  foreach ($cl in $sw.Clauses) {
    if ($cl.Item1.Value -ne 'say') { continue }
    $n++
    foreach ($feedback in @($false,$true)) {
      $script:me = 0; $script:turns = 0; $script:notes = 0
      $m = [pscustomobject]@{ text = $(if ($feedback) { 'synthetic-feedback' } else { 'synthetic-request' }) }
      $ok = $true
      try { . ([scriptblock]::Create(($cl.Item2.Statements | ForEach-Object { $_.Extent.Text }) -join "`n")) } catch { $ok = $false }
      Check "say-$n-$feedback" ($ok -and $script:me -eq 1 -and $script:turns -eq $(if ($feedback) { 0 } else { 1 }) -and $script:notes -eq $(if ($feedback) { 1 } else { 0 }))
    }
  }
}
Check 'both-surfaces' ($n -eq 2)
'main_reliability_test: {0} pass, {1} fail' -f $script:pass,$script:fail
if ($script:fail) { exit 1 }
