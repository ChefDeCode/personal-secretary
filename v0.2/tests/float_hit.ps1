# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 浮窗点击诊断：不动鼠标；打开浮窗后看几个点下面是哪个窗口（WindowFromPoint），以及浮窗的扩展样式
param([switch]$KeepOpen)
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class FH {
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(P p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, int f);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int p);
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP f, IntPtr l);
  public static List<IntPtr> Of(int pid) { var r = new List<IntPtr>(); EnumWindows((h, l) => { int p; GetWindowThreadProcessId(h, out p); if (p == pid) r.Add(h); return true; }, IntPtr.Zero); return r; }
}
'@
[void][FH]::SetProcessDpiAwarenessContext([IntPtr]-4)
$sp = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'v0\.2\\秘书\.ps1' } | Select-Object -First 1).ProcessId
function MiniH { foreach ($h in [FH]::Of($sp)) { $r = New-Object FH+R; [void][FH]::GetWindowRect($h, [ref]$r); if ([Math]::Abs(($r.Rt - $r.L) - 720) -lt 40 -and [Math]::Abs(($r.B - $r.T) - 960) -lt 40) { return $h } }; [IntPtr]::Zero }
$ev = [Threading.EventWaitHandle]::OpenExisting('Local\SecretaryPanelToggle'); [void]$ev.Set(); Start-Sleep -Milliseconds 1500
$h = MiniH; $r = New-Object FH+R; [void][FH]::GetWindowRect($h, [ref]$r)
"float exstyle 0x$('{0:X8}' -f [FH]::GetWindowLong($h, -20)) rect $($r.L),$($r.T)-$($r.Rt),$($r.B)"
foreach ($q in @(@(0.5, 0.12), @(0.3, 0.25), @(0.5, 0.5), @(0.8, 0.95))) {
  $p = New-Object FH+P; $p.X = [int]($r.L + ($r.Rt - $r.L) * $q[0]); $p.Y = [int]($r.T + ($r.B - $r.T) * $q[1])
  $w = [FH]::WindowFromPoint($p); $root = [FH]::GetAncestor($w, 2); $sb = New-Object Text.StringBuilder 128; [void][FH]::GetClassName($root, $sb, 128); $sbc = New-Object Text.StringBuilder 128; [void][FH]::GetClassName($w, $sbc, 128)
  $pid2 = 0; [void][FH]::GetWindowThreadProcessId($root, [ref]$pid2); $cl = ((Get-CimInstance Win32_Process -Filter "ProcessId=$pid2").CommandLine -replace '.*\\', '' -replace '"', '')
  "point $($q -join ','): root is float=$($root -eq $h); child class $sbc; root class $sb; process $pid2 $cl; root exstyle 0x$('{0:X8}' -f [FH]::GetWindowLong($root, -20))"
}
if (-not $KeepOpen) { [void]$ev.Set() }; $ev.Dispose()
