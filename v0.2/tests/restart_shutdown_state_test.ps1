# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 重启秘书.ps1：上次是系统关机 / 更新换版退出的（也是「干净退出」），-StartOnly 可以打开；只有你自己点了「退出秘书」才挡住；崩溃照旧可以打开
# 只在后台跑：从脚本里取出函数，状态文件写在临时文件夹，进程列表是假的；不真的启动或停止任何东西
. "$PSScriptRoot\lib_synthetic_test.ps1"
$restart = Join-Path $v2 'tools\重启秘书.ps1'
$ra = [Management.Automation.Language.Parser]::ParseFile($restart, [ref]$null, [ref]$null)
foreach ($fn in $ra.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$tmp = Join-Path $env:TEMP ('secretary_restart_state_' + [guid]::NewGuid().ToString('n').Substring(0, 6)); [void][IO.Directory]::CreateDirectory($tmp)
function State([string]$json) { $f = Join-Path $tmp 'run_state.json'; [IO.File]::WriteAllText($f, $json, (New-Object Text.UTF8Encoding $false)); Get-Content -Encoding UTF8 -LiteralPath $f -Raw | ConvertFrom-Json }
$root = 'C:\Synthetic\Secretary\v0.2'
function Plan($st, [bool]$startOnly = $true) { Get-SecretaryRestartPlan @() $st $root $false $startOnly 99 }
try {
  $p = Plan (State '{"pid":160836,"clean":true,"how":"系统关机","ts":"2026-11-08T03:04:06"}'); Check "system shutdown (系统关机) -> -StartOnly may open it ($($p.reason))" ($p.allowed)
  $p = Plan (State '{"pid":5,"clean":true,"how":"system-shutdown"}'); Check 'system-shutdown (English reason) -> allowed' ($p.allowed)
  $p = Plan (State '{"pid":5,"clean":true,"how":"update"}'); Check 'clean exit for an update -> allowed' ($p.allowed)
  $p = Plan (State '{"pid":5,"clean":true,"how":"user-quit"}'); Check "you quit it yourself -> blocked ($($p.reason))" (-not $p.allowed -and $p.reason -eq 'user_closed')
  $p = Plan (State '{"pid":5,"clean":true}'); Check 'old state file with no reason -> treated as your own quit (blocked)' (-not $p.allowed -and $p.reason -eq 'user_closed')
  $p = Plan (State '{"pid":5,"clean":false,"started":"2026-11-08T00:00:00"}'); Check 'crash (not clean) -> allowed as before' ($p.allowed)
  $p = Plan (State '{"pid":0,"clean":true,"how":"系统关机"}'); Check 'no recorded process id -> not opened' (-not $p.allowed)
  $p = Plan (State '{"pid":5,"clean":true,"how":"系统关机"}') $false; Check 'without -StartOnly it still does not open a stopped secretary' (-not $p.allowed -and $p.reason -eq 'not_running')
  $src = [IO.File]::ReadAllText($restart)
  Check 'both last-moment rechecks use the same rule' (([regex]::Matches($src, 'if \(Test-UserQuitState \$current\)')).Count -eq 2 -and $src -notmatch 'if \(\$current\.clean\)')
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Done-Test
