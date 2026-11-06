# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
$ErrorActionPreference='Stop';$v2=Split-Path $PSScriptRoot -Parent
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 '秘书.ps1'),[ref]$null,[ref]$null)
$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Convert-BackgroundValue'},$true)
. ([scriptblock]::Create($f.Extent.Text))
$script:pass=0;$script:fail=0
function Check($n,$ok){if($ok){$script:pass++;'[PASS] '+$n}else{$script:fail++;'[FAIL] '+$n}}
$values=@('2030-01-01T10:00:00','2030-01-02T11:00:00')|ForEach-Object{$_}
$payload=[pscustomobject]@{model='synthetic';max_tokens=1200;stream=$false;messages=@([pscustomobject]@{role='user';content='synthetic'});opts=$values;number=3.5}
$result=Convert-BackgroundValue $payload
Check 'provider_dictionary_shape_retained' ($result -is [Collections.IDictionary] -and $result.messages[0] -is [Collections.IDictionary])
Check 'pipeline_strings_remain_strings' ($result.opts[0] -is [string] -and $result.opts[1] -eq '2030-01-02T11:00:00')
Check 'numeric_and_boolean_values_retained' ($result.max_tokens -eq 1200 -and $result.stream -is [bool] -and -not $result.stream -and $result.number -eq 3.5)
Check 'nested_message_text_retained' ($result.messages[0].content -is [string] -and $result.messages[0].content -eq 'synthetic')
'scalar_reliability_test: {0} pass, {1} fail' -f $script:pass,$script:fail
if($script:fail){exit 1}
