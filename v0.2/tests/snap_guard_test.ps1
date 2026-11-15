# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 透明读的保护：微信被放出来读时自己抢了前台、没还回去 → 一天第 1 次停 60 分钟，第 2 次停到下次启动；新的一天从 0 算；暂停期间的余波不重复记；屏幕上直接读不受影响
# 只在后台跑：从 12_值守.ps1 取出这几个函数，事件和时钟都是假的；不放出任何窗口、不碰微信
. "$PSScriptRoot\lib_synthetic_test.ps1"
Import-TestFunctions "$productRoot\12_值守.ps1" @('Get-SnapGuard', 'Test-SnapAllowed', 'Register-SnapFgEvent', 'Update-SnapGuard')
function Write-Quality($rec) { $script:QRows.Add($rec) }
function Reset { $script:SnapGuard = $null; $script:stats = [ordered]@{ 错误 = 0 }; $script:QRows = New-Object System.Collections.Generic.List[object] }
$stole = @{ fg_changed = $true; fg_who = 'ours'; fg_restored = $false }
$t0 = [datetime]'2026-11-20T14:00:00'
Reset
Check 'nothing happened yet -> reads allowed' ((-not (Update-SnapGuard $t0 $null 7)) -and (Test-SnapAllowed $t0))
Check 'a fail count already there at start is not an event' ((Get-SnapGuard).seenFail -eq 7 -and [int]$stats.透明读抢前台 -eq 0)
# 1) 第一次：快照读后前台被微信抢走、没还回去 → 停 60 分钟
Check 'first event of the day is registered' (Update-SnapGuard $t0 $stole 7)
Check 'paused for 60 minutes' (-not (Test-SnapAllowed $t0.AddMinutes(59)) -and (Test-SnapAllowed $t0.AddMinutes(60)))
Check 'counted in stats (1 event, 1 sixty-minute pause)' ([int]$stats.透明读抢前台 -eq 1 -and [int]$stats.透明读暂停60分钟 -eq 1 -and -not $stats.透明读停到重启)
Check 'one numbers-only line in the read log' ($QRows.Count -eq 1 -and $QRows[0].ev -eq 'snap_guard' -and $QRows[0].events_today -eq 1 -and $QRows[0].paused_min -eq 60 -and -not $QRows[0].until_restart)
# 同一回的余波（放回去后又弹出来、前台没还回去）在暂停期间出现 → 不重复记
Check 'aftershock during the pause is not counted again' (-not (Update-SnapGuard $t0.AddSeconds(3) $null 8) -and [int]$stats.透明读抢前台 -eq 1 -and (Get-SnapGuard).seenFail -eq 8)
# 2) 恢复以后同一天第二次（这回是「又弹出来、没还回去」）→ 停到下次启动
Check 'reads resume after the hour' (Test-SnapAllowed $t0.AddMinutes(61))
Check 'second event the same day (re-pop not handed back) is registered' (Update-SnapGuard $t0.AddMinutes(90) $null 9)
Check 'paused until the secretary next starts (even hours later)' (-not (Test-SnapAllowed $t0.AddHours(8)) -and -not (Test-SnapAllowed $t0.AddDays(2)))
Check 'counted: 2 events, 1 stop-until-restart' ([int]$stats.透明读抢前台 -eq 2 -and [int]$stats.透明读停到重启 -eq 1 -and $QRows[-1].until_restart -and $QRows[-1].paused_min -eq -1)
# 下次启动 = 新的状态：又可以读
Reset; Check 'a fresh start allows reads again' (Test-SnapAllowed $t0)
# 3) 新的一天从 0 算
Reset; [void](Update-SnapGuard ([datetime]'2026-11-20T23:30:00') $null 0); [void](Update-SnapGuard ([datetime]'2026-11-20T23:30:00') $stole 0)
[void](Update-SnapGuard ([datetime]'2026-11-21T01:00:00') $stole 0)
Check 'an event on the next day counts as the first of that day (60-minute pause, not until restart)' ((Get-SnapGuard).events -eq 1 -and -not (Get-SnapGuard).off -and (Test-SnapAllowed ([datetime]'2026-11-21T02:00:00')))
# 4) 不算的情况
Reset; [void](Update-SnapGuard $t0 $null 0)
Check 'foreground changed by another program -> not an event' (-not (Update-SnapGuard $t0 @{ fg_changed = $true; fg_who = 'other'; fg_restored = $false } 0))
Check 'foreground taken but handed back -> not an event' (-not (Update-SnapGuard $t0 @{ fg_changed = $true; fg_who = 'ours'; fg_restored = $true } 0))
Check 'no foreground change -> not an event' (-not (Update-SnapGuard $t0 @{ fg_changed = $false; fg_who = ''; fg_restored = $false } 0) -and (Test-SnapAllowed $t0))
# 5) 只管透明读：屏幕上直接读不受影响；每次快照读都记下锁住前台成功没有
$w = [IO.File]::ReadAllText("$productRoot\12_值守.ps1")
Check 'the guard sits only on the hidden/minimized (NeedsGhost) branch' ($w -match '\[Ghost2\]::NeedsGhost\(\$h\) -and \(Test-SnapAllowed \(Get-Date\)\) -and \[Ghost2\]::IdleMs\(\) -ge 5000')
Check 'Test-SnapAllowed is used only there and in the hint text' (([regex]::Matches($w, 'Test-SnapAllowed \(Get-Date\)')).Count -eq 2)
Check 'snapshot, long transparent read and the per-round check all feed the guard' (([regex]::Matches($w, 'Update-SnapGuard \(Get-Date\)')).Count -eq 3)
$g = [IO.File]::ReadAllText("$v2\lib_原地读.ps1")
Check 'each snapshot record carries whether the foreground lock succeeded' ($g -match 'lock = \[bool\]\[Ghost2\]::LockOk \}')
Check 'a re-pop that could not hand the foreground back is counted' ($g -match 'if \(!fgOk\) RepopFgFail\+\+' -and $g -match 'public static int RepopFgFail')
Done-Test
