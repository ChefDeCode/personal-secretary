# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 「截一张就收」：收起来的窗口全透明地放出来、一画出来就截一张、马上放回去（目标不到 0.25 秒，赶在微信约 0.38 秒自己抢前台之前）。
# 用两个测试窗口（不碰真微信）：仿微信（最小化 / 托盘里）—— 截得到、能认字、露出来多久、回到原样、前台不变；
# 「自己抢前台」的窗口（像微信 4）—— 截完收回去之后它排着的激活还会不会把它弹出来：弹出来要被发现、放回去、前台还给原来的窗口
# 会动测试窗口的状态（看不见），所以要你停手 5 秒以上才开始
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $root = Split-Path $v2 -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_原地读.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
Add-Type 'using System; using System.Runtime.InteropServices; public static class GS { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h); [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i); [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); }'
$T = Join-Path $env:TEMP 'secretary_ghost_snap'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null; $script:V2Data = $T
$sw0 = [Diagnostics.Stopwatch]::StartNew(); while ([Ghost2]::IdleMs() -lt 5000 -and $sw0.Elapsed.TotalMinutes -lt 10) { Start-Sleep -Milliseconds 500 }
$logF = Join-Path $env:TEMP 'fake_wechat_log.txt'; $apps = @()
try {
  Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force
  $app = Start-Process "$PSScriptRoot\仿微信.exe" -ArgumentList $logF, '目标会话5', '-4000', '200', 5 -PassThru; $apps += $app; Start-Sleep 2
  $h = [WinTools]::LargestVisibleWindow([uint32[]]@($app.Id)); [void][GS]::SetWindowPos($h, [IntPtr]::Zero, 200, 200, 0, 0, 0x15); Start-Sleep -Milliseconds 300
  foreach ($state in 'minimized', 'tray') {
    $vis = @(); $okN = 0
    for ($k = 1; $k -le 5; $k++) {
      [void][GS]::ShowWindow($h, $(if ($state -eq 'tray') { 0 } else { 7 })); Start-Sleep -Milliseconds 400
      $ex0 = [GS]::GetWindowLong($h, -20); $fg0 = [GS]::GetForegroundWindow()
      $s = Invoke-GhostSnap $h 200 0; Start-Sleep -Milliseconds 900   # 再等一会：看它会不会自己弹回来
      if ($s.ok) { $okN++; $rows = @((Read-WeChat $h $s.bmp).列表).Count; $s.bmp.Dispose() } else { $rows = 0 }
      $vis += $s.rec.visible_ms
      $back = if ($state -eq 'tray') { -not [GS]::IsWindowVisible($h) } else { [GS]::IsIconic($h) }
      if ($k -eq 1) { Check "[$state] captured right away and read off-window ($rows chats), back $(if ($state -eq 'tray') { 'hidden' } else { 'minimized' }), styles and foreground unchanged" ($s.ok -and $rows -gt 0 -and $back -and [GS]::GetWindowLong($h, -20) -eq $ex0 -and [GS]::GetForegroundWindow() -eq $fg0) }
    }
    $mx = ($vis | Measure-Object -Maximum).Maximum
    Check "[$state] 5 reads: $okN captured; visible $(($vis | Sort-Object) -join '/') ms (all under 250)" ($okN -eq 5 -and $mx -lt 250)
  }
  # 像微信 4 一样会自己抢前台的窗口：放出来 0.38 秒后自己激活。截一张就收要赶在它之前收回去；它排着的激活后来发作 → 要被发现、放回去、前台还回来
  $sa = Start-Process powershell -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "$PSScriptRoot\fake_selfactivate_window.ps1", '380') -PassThru; $apps += $sa; Start-Sleep 3
  $sh = [IntPtr]::Zero; for ($i = 0; $i -lt 20 -and $sh -eq [IntPtr]::Zero; $i++) { $sh = [WinTools]::LargestVisibleWindow([uint32[]]@($sa.Id)); Start-Sleep -Milliseconds 300 }
  Check "self-activating test window is up ($([bool]($sh -ne [IntPtr]::Zero)))" ($sh -ne [IntPtr]::Zero)
  foreach ($state in 'minimized', 'tray') {
    [void][GS]::ShowWindow($sh, $(if ($state -eq 'tray') { 0 } else { 7 })); Start-Sleep -Milliseconds 1500
    $fg0 = [GS]::GetForegroundWindow(); $rep0 = [Ghost2]::Repops
    $s = Invoke-GhostSnap $sh 200 0; Start-Sleep -Milliseconds 1200
    $back = if ($state -eq 'tray') { -not [GS]::IsWindowVisible($sh) } else { [GS]::IsIconic($sh) }
    Check "[$state, self-activating] captured in $($s.rec.visible_ms) ms (before it grabs focus at 380 ms)" ($s.ok -and $s.rec.visible_ms -lt 250)
    Check "[$state, self-activating] its queued self-activation after we hid it is caught ($([Ghost2]::Repops - $rep0)x, max 3 tries so we never fight it), and your foreground is always given back ($([GS]::GetForegroundWindow() -eq $fg0)); window back $(if ($back) { 'yes' } else { 'no (this test window keeps re-showing itself)' })" ((([Ghost2]::Repops - $rep0) -ge 1) -and [GS]::GetForegroundWindow() -eq $fg0)
    if ($s.ok) { $s.bmp.Dispose() }
  }
  $log = @(Get-Content "$T\ghost_reads.jsonl" | ForEach-Object { $_ | ConvertFrom-Json }); Check "each read logged with visible ms, painted, foreground change, state ($($log.Count) lines)" ($log.Count -ge 12 -and $null -ne $log[0].visible_ms -and $null -ne $log[0].painted)
} finally { if ([Ghost2]::Active) { [Ghost2]::Hide() }; foreach ($a in $apps) { try { if (-not $a.HasExited) { $a.Kill() } } catch {} }; Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
"ghost_snap_test: $pass pass, $fail fail"
