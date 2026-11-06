# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 边框是否「一直亮着、不一闪一闪」：给测试窗口套上边框，模拟一次多步操作（中间有短空隙），
# 每 ~2 毫秒取一次屏幕上边框那一点的颜色（只取我们边框所在的像素，不截任何别的内容），数「亮着期间暗下去」的次数。
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $root = Split-Path $v2 -Parent
. "$root\lib_窗口工具.ps1"
Add-Type @'
using System; using System.Threading; using System.Runtime.InteropServices;
public static class Px {
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h); [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y); [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc); [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h); [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o); [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr d, int x, int y, int w, int h, IntPtr s, int sx, int sy, uint op); [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc); [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
  static IntPtr mdc, bmp; static uint Cap(IntPtr sdc, int x, int y) { if (mdc == IntPtr.Zero) { mdc = CreateCompatibleDC(sdc); bmp = CreateCompatibleBitmap(sdc, 1, 1); SelectObject(mdc, bmp); } BitBlt(mdc, 0, 0, 1, 1, sdc, x, y, 0x00CC0020 | 0x40000000); return GetPixel(mdc, 0, 0); } [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint p);
  [StructLayout(LayoutKind.Sequential)] public struct RC { public int l, t, r, b; } [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
  [StructLayout(LayoutKind.Sequential)] struct LI { public uint cb, t; } [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LI l);
  static uint LastIn() { var l = new LI { cb = 8 }; GetLastInputInfo(ref l); return l.t; }
  static volatile bool run; static Thread th; public static System.Collections.Generic.List<long> T = new System.Collections.Generic.List<long>(); public static System.Collections.Generic.List<int> D = new System.Collections.Generic.List<int>(); public static bool UserInput;
  public static void Start(int x, int y, uint bg) { timeBeginPeriod(1); run = true; T.Clear(); D.Clear(); uint i0 = LastIn(); var sw = System.Diagnostics.Stopwatch.StartNew();
    th = new Thread(() => { IntPtr dc = GetDC(IntPtr.Zero); while (run) { uint c = Cap(dc, x, y); int d = Math.Abs((int)(c & 255) - (int)(bg & 255)) + Math.Abs((int)((c >> 8) & 255) - (int)((bg >> 8) & 255)) + Math.Abs((int)((c >> 16) & 255) - (int)((bg >> 16) & 255));
      lock (T) { T.Add(sw.ElapsedMilliseconds); D.Add(d); } if (LastIn() != i0) UserInput = true; Thread.Sleep(1); } ReleaseDC(IntPtr.Zero, dc); }); th.IsBackground = true; th.Start(); }
  public static uint Read(int x, int y) { IntPtr dc = GetDC(IntPtr.Zero); uint c = Cap(dc, x, y); ReleaseDC(IntPtr.Zero, dc); return c; }
  public static void Stop() { run = false; th.Join(); }
}
'@
$exe = "$PSScriptRoot\秘书测试窗口.exe"; $proc = [IO.Path]::GetFileNameWithoutExtension($exe)
Get-Process $proc -ErrorAction SilentlyContinue | Stop-Process -Force
$app = Start-Process $exe -ArgumentList '300', '300' -PassThru; Start-Sleep 2; $h = $app.MainWindowHandle
$r = New-Object Px+RC; [void][Px]::GetWindowRect($h, [ref]$r); $dpi = [WinTools]::Dpi($h)
$state = Join-Path $env:TEMP 'border_test_state.json'; Set-Lit $state -10
$x = [int](($r.l + $r.r) / 2); $y = $r.t   # 这个测试窗口不感知 DPI：边框的描边正好落在它的上沿（扫描测得）   # 边框的描边在窗口外 ~7 像素
$bg = [Px]::Read($x, $y)
Set-Lit $state 3
$bp = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$root\07_AI边框特效.ps1", '-Process', $proc, '-StateFile', $state)
[Px]::Start($x, $y, $bg); $sw = [Diagnostics.Stopwatch]::StartNew(); $marks = @{}
# 模拟一次操作：0~3 秒亮着；3 秒时「这一步做完」熄灭；4.2 秒下一步又亮（中间 1.2 秒空隙）；一直到 8 秒做完熄灭
while ($sw.ElapsedMilliseconds -lt 3000) { Set-Lit $state 3; Start-Sleep -Milliseconds 400 }
"debug bg={0:X6} now={1:X6} at x=$x y=$y" -f $bg, [Px]::Read($x, $y); Set-Lit $state 1; $marks.gap = $sw.ElapsedMilliseconds; Start-Sleep -Milliseconds 1200
while ($sw.ElapsedMilliseconds -lt 8000) { Set-Lit $state 3; Start-Sleep -Milliseconds 400 }
Set-Lit $state -10; $marks.end = $sw.ElapsedMilliseconds; Start-Sleep -Milliseconds 3500
[Px]::Stop(); Stop-Process -Id $bp.Id -ErrorAction SilentlyContinue; Stop-Process -Id $app.Id -ErrorAction SilentlyContinue
$T = [Px]::T.ToArray(); $D = [Px]::D.ToArray(); $thr = 25
$first = -1; for ($i = 0; $i -lt $D.Count; $i++) { if ($D[$i] -gt $thr) { $first = $i; break } }
$fullAt = -1; $peak = ($D | Measure-Object -Maximum).Maximum; for ($i = [Math]::Max(0,$first); $i -lt $D.Count; $i++) { if ($D[$i] -ge $peak * 0.8) { $fullAt = $i; break } }
$endIdx = 0; for ($i = 0; $i -lt $T.Count; $i++) { if ($T[$i] -le $marks.end) { $endIdx = $i } }
$drops = 0; $prevLow = $false; $min = 9999; $gaps = @(); for ($i = 1; $i -lt $T.Count; $i++) { $gaps += ($T[$i] - $T[$i-1]) }
for ($i = $fullAt; $i -le $endIdx -and $fullAt -ge 0; $i++) { $low = $D[$i] -lt $peak * 0.6; if ($low -and -not $prevLow) { $drops++ }; $prevLow = $low; if ($D[$i] -lt $min) { $min = $D[$i] } }
$offAt = -1; for ($i = $endIdx; $i -lt $D.Count; $i++) { if ($D[$i] -le $thr) { $offAt = $i; break } }
$maxGap = ($gaps | Measure-Object -Maximum).Maximum; $p16 = @($gaps | Where-Object { $_ -gt 16 }).Count
"samples=$($T.Count) max_sample_gap_ms=$maxGap gaps_over_16ms=$p16"
"lit_first_ms=$($T[$first]) full_ms=$($T[$fullAt]) (fade-in $($T[$fullAt]-$T[$first]) ms)"
"while lit (until operation end at $($marks.end) ms, including the 1.2 s gap between steps at $($marks.gap) ms): drops=$drops; min/peak=$min/$peak"
"after end: off at $(if ($offAt -ge 0) { $T[$offAt] - $marks.end } else { 'never' }) ms after the operation ended"
"user_input_during_test=$([Px]::UserInput)"
