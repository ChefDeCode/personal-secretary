# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 边缘线和主窗口共用一个显示组件数据文件夹；主程序的浏览器进程重开时边缘线自己恢复（3 秒后重建，10 分钟最多 5 次；秘书已退出就收掉）
# 不启动真的显示组件：控件和窗体都用假的
. (Join-Path $PSScriptRoot 'lib_test_data.ps1'); $script:TestDataRoot = Use-TestDataFolder 'edge_share_test'
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$v2 = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
$edgeSrc = [IO.File]::ReadAllText("$v2\边缘线.ps1"); $mainSrc = [IO.File]::ReadAllText("$v2\秘书.ps1")
$mainUdf = @([regex]::Matches($mainSrc, "UserDataFolder = Join-Path \`$script:V2Data '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Check "edge line uses the same WebView2 data folder as the main window ($($mainUdf -join ',') )" ($mainUdf.Count -eq 1 -and $edgeSrc -match "EdgeUdf = Join-Path \`$dataV2 '$($mainUdf[0])'" -and $edgeSrc -notmatch 'webview2_edge')
Check 'edge line listens for its browser process failing' ($edgeSrc -match 'add_ProcessFailed' -and $edgeSrc -match 'Request-EdgeReset')
$ast = [Management.Automation.Language.Parser]::ParseInput($edgeSrc, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Request-EdgeReset', 'Reset-EdgeWebView' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
# 假的窗体和控件
$script:closed = 0; $script:made = 0
$form = [pscustomobject]@{ Controls = (New-Object System.Collections.ArrayList) }; $form | Add-Member ScriptMethod Close { $script:closed++ }
$form.Controls | Add-Member ScriptMethod Remove { param($c) [void]$this.Remove($c) } -Force -ErrorAction SilentlyContinue
function New-FakeView { $w = [pscustomobject]@{ Disposed = $false; Ensured = 0 }; $w | Add-Member ScriptMethod Dispose { $this.Disposed = $true }; $w | Add-Member ScriptMethod EnsureCoreWebView2Async { param($x) $this.Ensured++; $null }; $w }
function New-EdgeWebView { $script:made++; $w = New-FakeView; [void]$form.Controls.Add($w); $script:wv = $w; $w }
$ctl = [pscustomobject]@{ Web = 'old' }
$script:EdgeResets = New-Object System.Collections.Generic.List[datetime]; $script:EdgeResetTimer = $null
$OwnerPid = $PID; $wv = New-EdgeWebView; $first = $wv
Check 'other failure kinds do not rebuild' (-not (Request-EdgeReset 'Unknown') -and -not $script:EdgeResetTimer)
Check 'browser process exit schedules one rebuild after 3 s' ((Request-EdgeReset 'BrowserProcessExited') -and $script:EdgeResetTimer.Interval -eq 3000)
Check 'a second failure while one is pending does not stack another' (-not (Request-EdgeReset 'RenderProcessExited'))
$script:EdgeResetTimer.Stop(); $script:EdgeResetTimer.Dispose(); $script:EdgeResetTimer = $null
Reset-EdgeWebView
Check 'rebuild: old control removed and disposed, a new one created and started' ($first.Disposed -and -not $form.Controls.Contains($first) -and $script:wv -ne $first -and $script:wv.Ensured -eq 1 -and $script:made -eq 2)
foreach ($i in 1..4) { Reset-EdgeWebView }
Check "at most 5 rebuilds in 10 minutes ($($script:EdgeResets.Count) done, 6th refused)" (-not (Request-EdgeReset 'BrowserProcessExited') -and $script:EdgeResets.Count -eq 5)
$OwnerPid = 999999; $before = $script:made; $script:EdgeResets.Clear(); Reset-EdgeWebView
Check 'secretary already gone: the edge line closes instead of rebuilding' ($script:closed -eq 1 -and $script:made -eq $before)
"edge_share_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
