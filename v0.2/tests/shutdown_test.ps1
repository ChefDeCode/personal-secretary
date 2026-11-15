# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# Windows 关机时：不拦关机、不重开显示组件、退出原因记「系统关机」；托盘菜单的显示组件没了也不报错；
# 页面藏起来时真的挂起（先设成不可见）、挂起出错只记一次、不再变成「没人接的后台异常」。全部用假的窗口和假的显示组件，不开任何窗口
. (Join-Path $PSScriptRoot 'lib_test_data.ps1'); $script:TestDataRoot = Use-TestDataFolder 'shutdown_test'
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$v2 = Split-Path $PSScriptRoot -Parent; $root = Split-Path $v2 -Parent
Add-Type -AssemblyName System.Windows.Forms
if (-not ('ExitLog' -as [type])) { Add-Type -Path (Join-Path $v2 'ExitLog.cs') -ReferencedAssemblies System.Windows.Forms }
$wvDll = Join-Path $root 'lib\webview2\Microsoft.Web.WebView2.Core.dll'; if (Test-Path $wvDll) { try { Add-Type -Path $wvDll } catch {} }
$T = $script:TestDataRoot; $script:V2Data = "$T\v0.2data"
[ExitLog]::LogPath = "$T\exit_log.jsonl"; [ExitLog]::StatePath = "$T\run_state.json"; [ExitLog]::Install()
function Kinds { if (Test-Path ([ExitLog]::LogPath)) { @(Get-Content -Encoding UTF8 ([ExitLog]::LogPath) | ForEach-Object { ($_ | ConvertFrom-Json).kind }) } else { @() } }
$src = [IO.File]::ReadAllText("$v2\秘书.ps1"); $ast = [Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Request-WvRestart', 'Show-TrayMenu', 'Set-PageVisibility', 'Test-SuspendTask' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
function Handler([string]$who) { $c = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.CommandExpressionAst] -or $a -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | Where-Object { $_ -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $_.Expression.Extent.Text -eq $who -and $_.Member.Extent.Text -eq 'add_FormClosing' })[0]; [scriptblock]::Create($c.Arguments[0].ScriptBlock.EndBlock.Extent.Text) }
$script:hidden = 0; $script:stopped = 0; $script:slid = 0
function Hide-Mini { $script:hidden++ }; function Stop-SecWorkers { $script:stopped++ }; function Slide-Out { $script:slid++ }; function Request-ReadSnapshot { }; function Update-Theme { }
function Ev([string]$reason) { [pscustomobject]@{ CloseReason = $reason; Cancel = $false } }
# 1) 小浮窗：点 × 只是收起；Windows 关机时不拦
$mini = Handler '$mini'; $script:quitting = $false
$e = Ev 'UserClosing'; & $mini $null $e; Check 'mini window: the × button still only hides it' ($e.Cancel -and $script:hidden -eq 1)
$e = Ev 'WindowsShutDown'; & $mini $null $e
Check "mini window does not block Windows shutdown, exit reason logged ($(@(Kinds) -join ','))" (-not $e.Cancel -and [ExitLog]::Ending -and (Kinds) -contains 'system-shutdown')
$st = Get-Content -Encoding UTF8 ([ExitLog]::StatePath) -Raw | ConvertFrom-Json
Check "run state says 系统关机 and clean ($($st.how))" ($st.how -eq '系统关机' -and $st.clean)
[ExitLog]::MarkEnding('again'); Check 'the shutdown is logged only once' (@(Kinds | Where-Object { $_ -eq 'system-shutdown' }).Count -eq 1)
# 2) 主窗口：关机时不拦、停后台
$form = Handler '$form'; $script:quitting = $false; $e = Ev 'WindowsShutDown'; & $form $null $e
Check 'main window does not block shutdown and stops background work' (-not $e.Cancel -and $script:quitting -and $script:stopped -eq 1)
# 3) 关机时浏览器进程被系统关掉：不重开显示组件
$script:WvRestartAt = $null; Request-WvRestart 'BrowserProcessExited'
Check 'during shutdown the browser-process exit does not schedule a restart' (-not $script:WvRestartAt -and -not (Test-Path (Join-Path $script:V2Data 'wv_restart.txt')))
# 4) 托盘菜单：显示组件没了不报错
$wvTm = [pscustomobject]@{ CoreWebView2 = $null }; $err = $null; try { Show-TrayMenu } catch { $err = $_ }
Check 'tray menu with a dead WebView2 does not throw' (-not $err)
# 5) 挂起：先设成不可见再挂起；出错只记一次；没有「没人接的后台异常」
function New-FakeWv([scriptblock]$suspend) { $c = [pscustomobject]@{ Resumed = 0; Posts = 0; MemoryUsageTargetLevel = $null; Suspends = 0 }
  $c | Add-Member ScriptMethod Resume { $this.Resumed++ }; $c | Add-Member ScriptMethod PostWebMessageAsJson { param($j) $this.Posts++ }
  $c | Add-Member ScriptMethod TrySuspendAsync $suspend; [pscustomobject]@{ Visible = $true; CoreWebView2 = $c } }
$faulted = { $this.Suspends++; $tcs = New-Object 'System.Threading.Tasks.TaskCompletionSource[bool]'; $tcs.SetException((New-Object InvalidOperationException 'still visible')); $tcs.Task }
$wv = New-FakeWv $faulted
Set-PageVisibility $false
Check 'hiding the page sets the WebView2 control invisible before suspending' (-not $wv.Visible -and $wv.CoreWebView2.Suspends -eq 1)
Check 'hidden page asks for low memory use' ([string]$wv.CoreWebView2.MemoryUsageTargetLevel -match 'Low' -or -not ('Microsoft.Web.WebView2.Core.CoreWebView2MemoryUsageTargetLevel' -as [type]))
Test-SuspendTask; Set-PageVisibility $true; $shownOk = $wv.Visible -and $wv.CoreWebView2.Resumed -ge 1 -and ([string]$wv.CoreWebView2.MemoryUsageTargetLevel -match 'Normal' -or -not ('Microsoft.Web.WebView2.Core.CoreWebView2MemoryUsageTargetLevel' -as [type])); Set-PageVisibility $false; Test-SuspendTask
Check "a failed suspend is logged once ($(@(Kinds | Where-Object { $_ -eq 'webview-suspend-failed' }).Count))" (@(Kinds | Where-Object { $_ -eq 'webview-suspend-failed' }).Count -eq 1)
Check 'showing the page again: control visible, page resumed, normal memory use' $shownOk
$wv = $null; $faulted = $null; [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect(); Start-Sleep -Milliseconds 200
Check "no unobserved background exception after the failed suspends ($(@(Kinds | Where-Object { $_ -eq 'unobserved-task' }).Count))" (@(Kinds | Where-Object { $_ -eq 'unobserved-task' }).Count -eq 0)
"shutdown_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
