# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 主窗口记住上次的样子：改过大小 / 最大化后重开还是那样；屏幕不在了或位置跑到外面 → 放回主屏幕；第一次用才是默认大小
# 只用秘书.ps1 里的两个函数和假的窗口对象，不开真窗口、不抢前台；记录写在临时文件夹
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$v2 = Split-Path $PSScriptRoot -Parent; $pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Resolve-WindowBounds', 'Save-WindowBounds' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$T = Join-Path $env:TEMP 'secretary_winstate'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null
$winFile = "$T\window.json"; $scale = 2.0
function New-Rect($x, $y, $w, $h) { New-Object Drawing.Rectangle $x, $y, $w, $h }
$primary = New-Rect 0 0 1440 860; $areas = @($primary); $default = New-Rect 960 0 480 860
function Reopen { $s = Get-Content $winFile -Raw | ConvertFrom-Json; Resolve-WindowBounds $s $areas $default }
# 第一次用：默认
$r = Resolve-WindowBounds $null $areas $default; Check 'first run -> default size (right third)' ($r.rect -eq $default -and -not $r.max)
# 改过大小 → 存 → 重开一样
$form = [pscustomobject]@{ WindowState = 'Normal'; Visible = $true; Bounds = (New-Rect 200 100 790 700); RestoreBounds = (New-Rect 200 100 790 700) }
Save-WindowBounds; $r = Reopen; Check "after resizing to 790x700 -> reopens the same ($($r.rect.Width)x$($r.rect.Height) at $($r.rect.X),$($r.rect.Y))" ($r.rect -eq (New-Rect 200 100 790 700) -and -not $r.max)
# 最大化 → 存 → 重开是最大化，还原时回到原来的大小
$form.WindowState = 'Maximized'; $form.Bounds = New-Rect -7 -7 1454 874; Save-WindowBounds; $r = Reopen
Check 'after maximizing -> reopens maximized, and restore goes back to 790x700' ($r.max -and $r.rect -eq (New-Rect 200 100 790 700))
$j = Get-Content $winFile -Raw | ConvertFrom-Json; Check "monitor and DPI are stored too ($($j.screen), $($j.dpi))" ($j.screen -and $j.dpi -eq 192)
# 最小化 / 隐藏时不覆盖
$form.WindowState = 'Minimized'; $before = Get-Content $winFile -Raw; Save-WindowBounds; Check 'minimized -> last good state kept' ((Get-Content $winFile -Raw) -eq $before)
# 屏幕不在了：位置在一个已经拔掉的副屏上 → 放回主屏幕
[IO.File]::WriteAllText($winFile, '{"x":2200,"y":100,"w":900,"h":700,"max":false}'); $r = Reopen
Check "window on an unplugged monitor -> moved back onto the main screen ($($r.rect.X),$($r.rect.Y) $($r.rect.Width)x$($r.rect.Height))" ($primary.Contains($r.rect))
[IO.File]::WriteAllText($winFile, '{"x":-5000,"y":-5000,"w":3000,"h":2000,"max":true}'); $r = Reopen
Check 'too big and far off-screen -> clamped to the main screen work area, still maximized' ($primary.Contains($r.rect) -and $r.max)
# 一半在屏幕外但抓得到：照旧
[IO.File]::WriteAllText($winFile, '{"x":1200,"y":200,"w":600,"h":500,"max":false}'); $r = Reopen; Check 'partly off the edge but still grabbable -> kept where you left it' ($r.rect -eq (New-Rect 1200 200 600 500))
# 坏文件 → 默认
[IO.File]::WriteAllText($winFile, 'xx'); $s = $null; try { $s = Get-Content $winFile -Raw | ConvertFrom-Json } catch {}; $r = Resolve-WindowBounds $s $areas $default; Check 'broken file -> default size, no error' ($r.rect -eq $default)
Check 'no temp file left behind (written in one piece)' (-not (Test-Path "$winFile.tmp"))
"window_state_test: $pass pass, $fail fail"