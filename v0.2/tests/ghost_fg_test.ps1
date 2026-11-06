# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 透明读时前台变了：只有「我们放出来的那个软件自己抢的、你也没动」才把前台还回去；你自己切的窗口、别的软件换的前台，一律不改回来（不碰屏幕的规则测试）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; . "$v2\lib_原地读.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$other = (Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).Id
Check 'the window we brought out took it -> "ours"' ((Get-FgChangeWho 1234 1234) -eq 'ours')
Check 'the secretary''s own window -> "secretary"' ((Get-FgChangeWho 1234 $PID) -eq 'secretary')
Check 'another app (explorer) -> "other"' ((Get-FgChangeWho 1234 ([uint32]$other)) -eq 'other')
Check 'ours + you did not touch anything -> put the old foreground back' (Test-GhostRestoreFg 'ours' $false)
Check 'ours but you were typing / clicking -> leave it (your action wins)' (-not (Test-GhostRestoreFg 'ours' $true))
Check 'you switched to another app mid-read -> never switched back' (-not (Test-GhostRestoreFg 'other' $true))
Check 'another app grabbed focus by itself -> not ours to undo' (-not (Test-GhostRestoreFg 'other' $false))
Check 'the secretary''s own window -> left as is' (-not (Test-GhostRestoreFg 'secretary' $false))
$src = [IO.File]::ReadAllText("$v2\lib_原地读.ps1"); $w = [IO.File]::ReadAllText((Join-Path (Split-Path $v2 -Parent) '12_值守.ps1'))
Check 'both places that bring windows out use this rule (shared reader and the WeChat watcher)' ($src -match 'Resolve-GhostFgChange \$h \$fg' -and $w -match 'Resolve-GhostFgChange \$h \$fgB' -and $w -notmatch 'Hide\(\); \[void\]\[IdleNow\]::Back\(\$fgB\)')
Check 'each change is logged with time offset, lock state, who and whether you moved' ($src -match 'offset_ms' -and $src -match 'lock = ' -and $src -match 'user_input')
$ad = [IO.File]::ReadAllText("$v2\适配.ps1")
Check 'adding an app works on a minimized or tray-hidden window too (captures through the same invisible read, no 「桌面 2」 message)' ($ad -match 'Invoke-GhostSnap \$h' -and $ad -match 'HiddenMain' -and $ad -notmatch '可以在桌面 2')
$lib = [IO.File]::ReadAllText("$v2\lib_原地读.ps1"); $wt = [IO.File]::ReadAllText((Join-Path (Split-Path $v2 -Parent) '12_值守.ps1'))
Check 'snap: the capture runs on its own thread with a 300 ms limit; past the limit the window goes back and that frame is dropped' ($lib -match 'CaptureWithin' -and $lib -match '\[int\]\$CapMs = 300' -and $lib -match 'overCap = \$true' -and $lib -match '截图太慢，已放回')
Check 'snap: each read logs show / capture / put-back times, who took the foreground, and any pop-backs' ($lib -match 'show_ms' -and $lib -match 'capture_ms' -and $lib -match 'hide_ms' -and $lib -match 'fg_who' -and $lib -match 'repops_since_last')
Check 'watcher: a too-slow capture makes the next try wait longer (40 s, 80 s ... up to 5 min)' ($wt -match '\$sn\.slow' -and $wt -match 'Math\]::Min\(300, 20 \* \[Math\]::Pow\(2')
"ghost_fg_test: $pass pass, $fail fail"