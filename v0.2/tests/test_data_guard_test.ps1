# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 测试只用自己的临时数据文件夹：加载秘书代码后，数据和设置都指向临时文件夹；测试里往真正的数据文件夹写日志会被拒绝
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$v2 = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'lib_test_data.ps1'); $script:TestDataRoot = Use-TestDataFolder 'test_data_guard_test'
. "$v2\lib_v2.ps1"
$tmp = [IO.Path]::GetFullPath($script:TestDataRoot)
Check 'after loading, the message data folder is the test folder' ([IO.Path]::GetFullPath($script:DataDir).StartsWith($tmp, [StringComparison]::OrdinalIgnoreCase))
Check 'after loading, the secretary data folder is the test folder' ([IO.Path]::GetFullPath($script:V2Data).StartsWith($tmp, [StringComparison]::OrdinalIgnoreCase))
Check 'after loading, the settings file is the test copy' ([IO.Path]::GetFullPath($script:CfgPath).StartsWith($tmp, [StringComparison]::OrdinalIgnoreCase))
Check 'paths made from them while loading (chat, people, done list) are in the test folder too' ((@($script:ChatFile, $script:PeopleFile, $script:DoneFile) | Where-Object { -not ([IO.Path]::GetFullPath($_).StartsWith($tmp, [StringComparison]::OrdinalIgnoreCase)) }).Count -eq 0)
$cfg = try { Get-Content -Encoding UTF8 $script:CfgPath -Raw | ConvertFrom-Json } catch { $null }
Check 'the settings copy holds no AI keys' (-not $cfg -or -not $cfg.ai -or -not $cfg.ai.keys -or -not @($cfg.ai.keys.PSObject.Properties).Count)
# 往测试文件夹写：照常写
Write-Quality @{ ev = 'guard-probe'; id = 'p1' }
$q = Join-Path $script:V2Data 'quality.jsonl'
Check 'writing into the test folder works as usual' ((Test-Path $q) -and ([IO.File]::ReadAllText($q) -match 'guard-probe'))
# 往「真正的」地方写（临时文件夹、测试副本以外）：被拒绝，文件不会出现
$probeDir = Join-Path $env:LOCALAPPDATA ('SecretaryGuardProbe_' + [guid]::NewGuid().ToString('n').Substring(0, 6)); $probe = Join-Path $probeDir 'quality.jsonl'
try {
  Add-SecretaryLogLines -Path $probe -Lines @('{"ev":"should-not-be-written"}')
  Check 'a log write outside the test and temp folders is refused (no file, no folder)' (-not (Test-Path $probeDir))
  Check 'Test-TestWriteBlocked: temp and test-runs copies allowed, other folders refused' (-not (Test-TestWriteBlocked (Join-Path ([IO.Path]::GetTempPath()) 'x.jsonl')) -and -not (Test-TestWriteBlocked 'C:\x\data\test-runs\1\project\v0.2\data\quality.jsonl') -and (Test-TestWriteBlocked $probe))
  $old = $env:SECRETARY_TEST; Remove-Item Env:SECRETARY_TEST
  Check 'outside tests nothing is blocked' (-not (Test-TestWriteBlocked $probe)); $env:SECRETARY_TEST = $old
} finally { if (Test-Path $probeDir) { Remove-Item $probeDir -Recurse -Force } }
"test_data_guard_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
