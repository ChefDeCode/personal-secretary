# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 借用前台的硬上限（5 秒）：剪贴板被占着 / 窗口不理 Ctrl+F / 叫到前面又被抢走 / 某一步太慢 —— 每种都要在约 5 秒内放弃、什么都没发、前台还回去。
# 会抢前台，等你 2 分钟没动电脑才开始；你一回来就停。结果写到 data\fg_cap_test.txt
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_找聊天.ps1"; . "$v2\lib_打字.ps1"; . "$v2\lib_前台发送.ps1"
Add-Type 'using System; using System.Runtime.InteropServices; public static class TC { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); }'
$out = Join-Path $script:V2Data 'fg_cap_test.txt'; Remove-Item $out -ErrorAction SilentlyContinue; function W($s) { Add-Content $out $s -Encoding UTF8 }
$idleNeed = $(if ($env:CAP_TEST_NOW) { 3000 } else { 120000 })
W 'waiting for 2 minutes of idle'; $dl = (Get-Date).AddMinutes(60); while ([FgSend]::IdleMs() -lt $idleNeed) { if ((Get-Date) -gt $dl) { W 'gave up waiting'; exit }; Start-Sleep 5 }
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; W "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
function Same($x, $y) { $x = $x -replace '\s', ''; $y = $y -replace '\s', ''; [bool]($x -and $x -eq $y) }
$script:StartFg = [FgSend]::GetForegroundWindow(); $userClip = Save-Clip; $logF = Join-Path $env:TEMP 'fake_wechat_log.txt'; $procs = @()
function Start-Fake([string]$mode = 'normal') { Remove-Item $logF -ErrorAction SilentlyContinue; Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force
  $a = Start-Process "$PSScriptRoot\仿微信.exe" -ArgumentList $logF, '目标会话5', '-4000', '200', 5, $mode -PassThru; Start-Sleep 2; $hh = [WinTools]::LargestVisibleWindow([uint32[]]@($a.Id)); [void][TC]::SetWindowPos($hh, [IntPtr]::Zero, 200, 200, 0, 0, 0x15); [void][FgSend]::Front($script:StartFg); Start-Sleep -Milliseconds 300; $hh }   # 新开的窗口自己会到前台：先把前台还回去
function Opts($hh, $extra = @{}) { $script:MH = $hh; $o = @{ proc = '仿微信'; findMain = { param($ids) $script:MH }; summon = { param($x) }; trayHide = { param($x) }; pill = $null; same = ${function:Same} }; foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }; $o }
function Sent { [bool](Get-Content $logF -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -like 'SENT *' }) }
function Report($name, $r, [string[]]$okMsgs) { $sec = [Math]::Round($r.front_ms / 1000.0, 1)
  Check "$name -> stopped ($($r.msg)), in front $sec s, nothing sent, foreground given back" (-not $r.ok -and $r.msg -in $okMsgs -and $r.front_ms -le 5800 -and -not (Sent) -and $r.fg_back)
  W "     steps_ms=$(($r.t | ConvertTo-Json -Compress)) capped=$([bool]$r.capped)" }
try {
  # 1) 剪贴板被别的程序一直占着（8 秒）
  $h = Start-Fake; $holder = Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', 'Add-Type ''using System; using System.Runtime.InteropServices; public static class CH { [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h); [DllImport("user32.dll")] public static extern bool CloseClipboard(); }''; [void][CH]::OpenClipboard([IntPtr]::Zero); Start-Sleep 8; [void][CH]::CloseClipboard()' -PassThru; $procs += $holder; Start-Sleep 2
  $r = Invoke-FgSend (Opts $h) '目标会话5' '【秘书测试】上限测试'; $sec = [Math]::Round($r.front_ms / 1000.0, 1); Check "clipboard held by another program -> within the cap either way ($($r.msg), in front $sec s)" ($r.front_ms -le 5800 -and $r.fg_back -and ($r.ok -or $r.msg -in '剪贴板不可用', '微信没及时响应')); W "     steps_ms=$(($r.t | ConvertTo-Json -Compress))"; Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue; Start-Sleep 1
  # 2) 窗口不理 Ctrl+F（一个普通的空窗口当微信）
  Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force
  $dumb = Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-STA', '-Command', 'Add-Type -AssemblyName PresentationFramework; $w = New-Object Windows.Window; $w.Title = ''不理键盘的窗口''; $w.Width = 900; $w.Height = 600; $w.Left = 200; $w.Top = 200; $w.WindowStartupLocation = ''Manual''; [void]$w.ShowDialog()' -PassThru; $procs += $dumb; Start-Sleep 4
  $hd = [WinTools]::LargestVisibleWindow([uint32[]]@($dumb.Id)); Remove-Item $logF -ErrorAction SilentlyContinue; [void][FgSend]::Front($script:StartFg); Start-Sleep -Milliseconds 300   # 新开的窗口自己会到前台：先把前台还给原来的窗口
  $r = Invoke-FgSend (Opts $hd @{ proc = 'powershell' }) '目标会话5' '【秘书测试】上限测试'; Report 'window ignores Ctrl+F' $r @('微信没反应', '微信没及时响应'); Stop-Process -Id $dumb.Id -Force -ErrorAction SilentlyContinue
  # 3) 叫到前面以后马上被别的窗口抢走（前台始终不是它）
  $h = Start-Fake; $other = [FgSend]::GetForegroundWindow()
  $r = Invoke-FgSend (Opts $h @{ afterFront = { [void][TC]::SetForegroundWindow($other); Start-Sleep -Milliseconds 100 } }) '目标会话5' '【秘书测试】上限测试'; Report 'foreground never really arrives' $r @('微信叫不出来', '用户输入', '微信没及时响应')
  # 4) 某一步太慢：叫到前面以后卡了 5.5 秒
  $h = Start-Fake
  $r = Invoke-FgSend (Opts $h @{ afterFront = { Start-Sleep -Milliseconds 5500 } }) '目标会话5' '【秘书测试】上限测试'; $sec = [Math]::Round($r.front_ms / 1000.0, 1); Check "a step takes too long -> stopped at the next check after 5 s ($($r.msg), in front $sec s, stuck step 5.5 s)" (-not $r.ok -and $r.capped -and $r.front_ms -le 6800 -and -not (Sent) -and $r.fg_back)   # 卡住的那一步本身打断不了，下一步之前就停
  # 5) 正常的还是能发
  $h = Start-Fake; $r = Invoke-FgSend (Opts $h) '目标会话5' '【秘书测试】上限测试'; Check "normal window still sends ($($r.msg), in front $([Math]::Round($r.front_ms / 1000.0, 1)) s)" ($r.ok -and (Sent))
} finally { foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }; Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force; W "your clipboard restored: $(Restore-Clip $userClip)" }
W "fg_cap_test: $pass pass, $fail fail"
