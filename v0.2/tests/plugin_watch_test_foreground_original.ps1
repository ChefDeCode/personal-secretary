# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 值守用商店插件读其它软件：仿微信窗口 + 临时装的插件（临时文件夹，不动你的真插件和真消息）
# 1) 读得出来 → 交给整理（这里只数条数）；2) 一直读空 → 第 3 次报坏；3) 秘书收到后停用插件、恢复自己适配的版面
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $root = Split-Path $v2 -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_通用识别.ps1"; . "$v2\lib_商店.ps1"
$T = Join-Path $env:TEMP 'secretary_plugin_watch'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\adapters" | Out-Null; $script:V2Data = $T
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$ast = [Management.Automation.Language.Parser]::ParseFile("$root\12_值守.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Watch-Plugins' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
function Get-Permission($p) { $true }; $stats = @{ 错误 = 0 }; $script:Saved = 0; function Save-Messages($c, $m, $b, $app) { $script:Saved += @($m).Count }
$script:PlugLast = @{}; $script:PlugFail = @{}; $script:PlugTxt = @{}
function Fake-Plugin([string]$id, $region) {
  $d = Join-Path "$T\adapters" $id; New-Item -ItemType Directory -Force $d | Out-Null
  [IO.File]::WriteAllText("$d\manifest.json", '{"id":"' + $id + '","app":{"process":"仿微信.exe","display":"测试软件"},"permissions":["app.observe","region.read:message_area"]}')
  [IO.File]::WriteAllText("$d\config.json", (@{ regions = @{ message_area = $region } } | ConvertTo-Json -Depth 4))
  [IO.File]::WriteAllText("$d\script.json", '{"actions":{"read_open_chat":[{"op":"find_window"},{"op":"read_region","region":"message_area","as":"text"},{"op":"emit","field":"text"}]}}')
  $bk = Join-Path $d 'local_backup'; New-Item -ItemType Directory -Force $bk | Out-Null; [IO.File]::WriteAllText("$bk\仿微信.json", '{"proc":"仿微信"}')
  [IO.File]::WriteAllText("$d\installed.json", (@{ id = $id; version = '1.0.0'; source = 'store'; app_process = '仿微信.exe'; app = '测试软件'; name = '测试'; permissions = @('app.observe', 'region.read:message_area'); enabled = $true; withdrawn = $false; backup = $bk } | ConvertTo-Json)) }
Add-Type 'using System; using System.Runtime.InteropServices; public static class TW9 { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); }'
$logF = Join-Path $env:TEMP 'fake_wechat_log.txt'
try {
  Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force
  $app = Start-Process "$PSScriptRoot\仿微信.exe" -ArgumentList $logF, '目标会话5', '-4000', '200', 5 -PassThru; Start-Sleep 2; $mh = [WinTools]::LargestVisibleWindow([uint32[]]@($app.Id)); [void][TW9]::SetWindowPos($mh, [IntPtr]::Zero, 200, 200, 0, 0, 0x15); Start-Sleep -Milliseconds 300
  Fake-Plugin 'p-good' @{ x = 0.0; y = 0.0; w = 1.0; h = 1.0 }
  "dbg: cmd=$([bool](Get-Command Invoke-PluginAction -ErrorAction SilentlyContinue)) perm=$(Get-Permission 'read_screen') inst=$(@(Get-InstalledPlugins).Count) en=$(@(Get-InstalledPlugins)[0].enabled) procs=$(@(Get-PluginProcs '仿微信.exe').Count) h=$([AppWin]::Largest([uint32[]]@(Get-PluginProcs '仿微信.exe').Id))"
  Watch-Plugins; Check "plugin reads the app (read-only) and hands $script:Saved lines to the organiser" ($script:Saved -gt 0 -and $stats.插件读取 -eq 1)
  $s0 = $script:Saved; $script:PlugLast = @{}; Watch-Plugins; Check 'same screen again -> nothing new handed over' ($script:Saved -eq $s0)
  Remove-Item "$T\adapters\p-good" -Recurse -Force
  Fake-Plugin 'p-blank' @{ x = 0.0; y = 0.0; w = 0.004; h = 0.004 }
  1..3 | ForEach-Object { $script:PlugLast = @{}; Watch-Plugins }
  Check "reads nothing 3 times -> reports it broken ($($stats.插件读空) empty reads)" (Test-Path "$T\adapters\p-blank\broken.json")
  $fx = Repair-PluginRead 'p-blank' 'watch'; $inf = Get-InstalledPlugins | Where-Object id -eq 'p-blank'
  Check 'secretary disables it and puts the self-adapted layout back' ((-not $inf.enabled) -and (Test-Path "$T\adapters\仿微信.json") -and $fx.restored -and -not (Test-Path "$T\adapters\p-blank\broken.json"))
  $script:PlugLast = @{}; $n0 = [int]$stats.插件读空; Watch-Plugins; Check 'disabled plugin is no longer used' ([int]$stats.插件读空 -eq $n0)
} finally { Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
"last error: $($stats.最后错误) errors=$($stats.错误)"; "plugin_watch_test: $pass pass, $fail fail"
