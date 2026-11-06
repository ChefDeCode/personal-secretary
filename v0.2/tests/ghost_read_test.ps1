# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 最小化窗口「全透明 + 点不着」地还原来读：截得到吗、抢不抢前台、你一碰鼠标多久放回最小化、样子有没有恢复原样。仿微信测试窗口，5 轮。
# 会动窗口状态，所以等你 2 分钟没动电脑才开始。结果写到 data\ghost_read_test.txt
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_原地读.ps1"
Add-Type 'using System; using System.Runtime.InteropServices; public static class T9 { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h); [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i); [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e); public static void Nudge() { mouse_event(1, 1, 0, 0, UIntPtr.Zero); mouse_event(1, -1, 0, 0, UIntPtr.Zero); } [StructLayout(LayoutKind.Sequential)] struct LI { public uint cb, t; } [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LI l); public static uint Idle() { var l = new LI { cb = 8 }; GetLastInputInfo(ref l); return (uint)Environment.TickCount - l.t; } }'
$out = Join-Path $script:V2Data 'ghost_read_test.txt'; Remove-Item $out -ErrorAction SilentlyContinue; function W($s) { Add-Content $out $s -Encoding UTF8 }
W 'waiting for 2 minutes of idle'; $dl = (Get-Date).AddMinutes(40); while ([T9]::Idle() -lt 120000) { if ((Get-Date) -gt $dl) { W 'gave up waiting'; exit }; Start-Sleep 5 }
$logF = Join-Path $env:TEMP 'fake_wechat_log.txt'; $res = @()
try {
  Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force
  $app = Start-Process "$PSScriptRoot\仿微信.exe" -ArgumentList $logF, '目标会话5', '-4000', '200', 5 -PassThru; Start-Sleep 2
  $h = [WinTools]::LargestVisibleWindow([uint32[]]@($app.Id)); [void][T9]::SetWindowPos($h, [IntPtr]::Zero, 200, 200, 0, 0, 0x15)
  for ($k = 1; $k -le 5; $k++) {
    [void][T9]::ShowWindow($h, 7); Start-Sleep -Milliseconds 500; $ex0 = [T9]::GetWindowLong($h, -20); $fg0 = [T9]::GetForegroundWindow()
    [void][Ghost]::Show($h); Start-Sleep -Milliseconds 400
    $fgChanged = [T9]::GetForegroundWindow() -ne $fg0
    $r = [WinTools]::Rect($h); $b = [Rec]::Window($h, $r.R - $r.L, $r.B - $r.T); $n = 0; $dark = 0; for ($y = 0; $y -lt $b.Height; $y += 12) { for ($x = 0; $x -lt $b.Width; $x += 12) { $c = $b.GetPixel($x, $y); $n++; if ((($c.R + $c.G + $c.B) / 3) -lt 6) { $dark++ } } }
    $rd = Read-WeChat $h $b; $b.Dispose()
    $sw = [Diagnostics.Stopwatch]::StartNew(); [T9]::Nudge(); while ([Ghost]::Active -and $sw.ElapsedMilliseconds -lt 2000) { Start-Sleep -Milliseconds 5 }; $backMs = $sw.ElapsedMilliseconds; Start-Sleep -Milliseconds 100
    $res += [pscustomobject]@{ round = $k; captured_not_black = ($dark / $n -lt 0.5); list_rows = @($rd.列表).Count; took_foreground = $fgChanged; back_to_minimized_ms = $backMs; minimized_again = [T9]::IsIconic($h); style_restored = ([T9]::GetWindowLong($h, -20) -eq $ex0); user_touch_seen = [Ghost]::UserTouched }
  }
} finally { if ([Ghost]::Active) { [Ghost]::Hide() }; Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force }
W ($res | Format-Table -AutoSize | Out-String -Width 200)
