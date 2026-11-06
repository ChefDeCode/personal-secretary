# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 两个开关：「永远不借用鼠标」（只有真点击才放得进的窗口 → 不发、什么都不留）；「等我离开电脑 1 分钟」+「立即发」（点了立即发就不再等）。
# 会抢前台，等你 2 分钟没动电脑才开始。结果写到 data\fg_options_test.txt
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_找聊天.ps1"; . "$v2\lib_打字.ps1"; . "$v2\lib_前台发送.ps1"
Add-Type 'using System; using System.Runtime.InteropServices; public static class TA2 { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); [DllImport("user32.dll", EntryPoint = "PostMessageW")] public static extern bool Post(IntPtr h, uint m, IntPtr w, IntPtr l); }'
$out = Join-Path $script:V2Data 'fg_options_test.txt'; Remove-Item $out -ErrorAction SilentlyContinue; function W($s) { Add-Content $out $s -Encoding UTF8 }
function Same($x, $y) { $x = $x -replace '\s', ''; $y = $y -replace '\s', ''; [bool]($x -and $x -eq $y) }
W 'waiting for 2 minutes of idle'; $dl = (Get-Date).AddMinutes(40); while ([FgSend]::IdleMs() -lt 120000) { if ((Get-Date) -gt $dl) { W 'gave up waiting'; exit }; Start-Sleep 5 }
$userClip = Save-Clip; $logF = Join-Path $env:TEMP 'fake_wechat_log.txt'; $res = @()
function Run($mode, $o2, $name) {
  Remove-Item $logF -ErrorAction SilentlyContinue; Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force
  $app = Start-Process "$PSScriptRoot\仿微信.exe" -ArgumentList $logF, '目标会话5', '-4000', '200', 5, $mode -PassThru; Start-Sleep 2
  $script:MH = [WinTools]::LargestVisibleWindow([uint32[]]@($app.Id)); [void][TA2]::SetWindowPos($script:MH, [IntPtr]::Zero, 200, 200, 0, 0, 0x15)
  $o = @{ proc = '仿微信'; findMain = { param($ids) $script:MH }; summon = { param($hh) [void][FgSend]::ShowWindow($script:MH, 5) }; trayHide = { param($hh) [void][FgSend]::ShowWindow($script:MH, 0) }; pill = $null; same = ${function:Same} }
  foreach ($k in $o2.Keys) { $o[$k] = $o2[$k] }
  $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Invoke-FgSend $o '目标会话5' '【秘书测试】开关测试'; $ms = $sw.ElapsedMilliseconds
  [void][TA2]::Post($script:MH, 0x0401, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 300
  $lines = @(Get-Content $logF -Encoding UTF8 -ErrorAction SilentlyContinue); $inputLeft = (@($lines | Where-Object { $_ -like 'INPUT *' }) | Select-Object -Last 1)
  [pscustomobject]@{ case = $name; ok = $r.ok; msg = $r.msg; sent = [bool]($lines | Where-Object { $_ -like 'SENT *' }); input_left_empty = ($inputLeft -eq 'INPUT '); mouse_used = [bool]$r.clicked; total_s = [Math]::Round($ms / 1000.0, 1); clip_ok = $r.clip_ok }
}
try {
  $res += Run 'notab' @{ noMouse = $true } 'never-borrow-mouse ON, only a real click would work -> no send, nothing left'
  $res += Run 'normal' @{ noMouse = $true } 'never-borrow-mouse ON, normal window -> sends without mouse'
  $flag = Join-Path $env:TEMP 'send_now_test.flag'; Remove-Item $flag -ErrorAction SilentlyContinue
  $job = Start-Job -ScriptBlock { param($p) Start-Sleep 3; [IO.File]::WriteAllText($p, '1') } -ArgumentList $flag
  $res += Run 'normal' @{ idleMs = 600000; maxWaitSec = 30; nowFlag = $flag } 'wait-for-away mode, user clicks 立即发 after 3 s -> sends'
  Remove-Job $job -Force -ErrorAction SilentlyContinue
} finally { Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force; W "your clipboard restored: $(Restore-Clip $userClip)" }
W ($res | Format-Table -AutoSize | Out-String -Width 220)
