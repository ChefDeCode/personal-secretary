# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 测试用：像微信 4 一样「被放出来以后约 0.38 秒自己抢前台」的窗口（虚构内容）。给 ghost_snap_test.ps1 用
# 参数：延迟毫秒（默认 380）
param([int]$DelayMs = 380)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$f = New-Object Windows.Forms.Form; $f.Text = '自己抢前台的测试窗口'; $f.Width = 900; $f.Height = 640; $f.StartPosition = 'Manual'; $f.Left = 150; $f.Top = 120; $f.BackColor = [Drawing.Color]::FromArgb(245, 245, 245)
foreach ($i in 0..8) { $l = New-Object Windows.Forms.Label; $l.Text = "示例会话 $i  · 虚构内容"; $l.Font = New-Object Drawing.Font 'Microsoft YaHei', 14; $l.AutoSize = $true; $l.Left = 20; $l.Top = 20 + $i * 50; $l.BackColor = $(if ($i % 2) { [Drawing.Color]::FromArgb(149, 236, 105) } else { [Drawing.Color]::White }); $f.Controls.Add($l) }
$timer = New-Object Windows.Forms.Timer; $timer.Interval = $DelayMs
$script:self = $false
$timer.add_Tick({ $timer.Stop(); $script:self = $true; if ($f.WindowState -eq 'Minimized') { $f.WindowState = 'Normal' }; if (-not $f.Visible) { $f.Show() }; $f.Activate(); $script:self = $false })   # 自己抢前台（就像微信：一次放出来只抢一次，自己弹出来不会再排下一次）
$script:prevMin = $false
$f.add_Resize({ if ($script:prevMin -and $f.WindowState -ne 'Minimized' -and -not $script:self) { $timer.Stop(); $timer.Start() }; $script:prevMin = ($f.WindowState -eq 'Minimized') })
$f.add_VisibleChanged({ if ($f.Visible -and -not $script:self) { $timer.Stop(); $timer.Start() } })
[Windows.Forms.Application]::Run($f)
