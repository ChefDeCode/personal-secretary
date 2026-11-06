# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 点击保护的单元测试：别人的窗口挡在目标上时，一下都不点（不发任何真实输入）
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib_测试输入.ps1"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$exe = "$PSScriptRoot\秘书测试窗口.exe"
$a = Start-Process $exe -ArgumentList '300', '300' -PassThru; Start-Sleep 2      # 「我们的」测试窗口
$b = Start-Process $exe -ArgumentList '350', '350' -PassThru; Start-Sleep 2      # 当作「别的软件」：不登记，盖在上面
Register-TestWindow $a.Id
try {
  $ra = New-Object TIn+R; $rb = New-Object TIn+R; [void][TIn]::GetWindowRect($a.MainWindowHandle, [ref]$ra); [void][TIn]::GetWindowRect($b.MainWindowHandle, [ref]$rb)
  $x = [int](([Math]::Max($ra.L, $rb.L) + [Math]::Min($ra.Rt, $rb.Rt)) / 2); $y = [int](([Math]::Max($ra.T, $rb.T) + [Math]::Min($ra.B, $rb.B)) / 2)   # 两个窗口重叠区域的中心（按真实窗口矩形算）
  if ([int][TIn]::PidOf([TIn]::RootAt($x, $y)) -ne $b.Id) { throw "测试布置不对：重叠处最上面不是 B" }
  [TIn]::Sent = 0
  $script:TestNoMove = $true
  $threw = $false; try { Invoke-TestClick $x $y } catch [TestAbort] { $threw = $true; $msg = $_.Exception.Message }
  Assert ($threw -and [TIn]::Sent -eq 0) "foreign window covering the target → aborted, $([TIn]::Sent) input events sent"
  $threw = $false; try { Invoke-TestClickElement $null } catch [TestAbort] { $threw = $true }
  Assert ($threw -and [TIn]::Sent -eq 0) "missing element → aborted, no fallback coordinates, $([TIn]::Sent) events"
  $threw = $false; try { Send-TestKey 0x1B } catch [TestAbort] { $threw = $true }
  $fgOurs = (Get-OurPids) -contains [int][TIn]::PidOf([TIn]::GetForegroundWindow())
  Assert ((($threw -and -not $fgOurs) -or ((-not $threw) -and $fgOurs))) "key press only when the foreground window is ours (foreground ours: $fgOurs, aborted: $threw)"
  # 允许挪窗口时：先把挡着的（B）最小化，再确认目标处是我们的窗口——这里只检查，不点
  $script:TestNoMove = $false; $before = [TIn]::Sent
  $ok2 = $true; try { Assert-OursAt $x $y } catch { $ok2 = $false }; $movedB = @($script:MovedWindows) -contains $b.MainWindowHandle
  Assert ($ok2 -and $movedB -and $script:MovedWindows.Count -eq 1 -and [TIn]::Sent -eq $before) "with moving allowed: the covering window was minimized first, then the target is ours (still no click sent)"
} finally { Restore-MovedWindows; foreach ($p in $a, $b) { if (-not $p.HasExited) { $p.Kill() } } }
"RESULT: $script:ok / $script:tot passed"
