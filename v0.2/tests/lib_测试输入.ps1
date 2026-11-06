# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_测试输入.ps1 — 所有自动化测试里「真实鼠标 / 键盘」的唯一入口，带硬性保护：
#   1) 每一下点击、每一个按键之前：取目标位置最上面的窗口 → 根窗口 → 所属进程，必须是秘书自己（秘书.ps1 / 边缘线.ps1）或登记过的测试窗口；否则整轮测试立即中止
#   2) 有别的软件的窗口挡在目标上：先把它挪开（最小化），再重新检查；绝不「穿过」别人的窗口去点
#   3) 没有任何兜底坐标：要点的元素找不到、不可见，一律中止
#   4) 按键只发给前台是秘书自己 / 测试窗口的时候
# 用法：. lib_测试输入.ps1；Register-TestWindow $pid；Invoke-TestClick x y [-Right]；Invoke-TestClickElement $uiaElement；Send-TestKey vk；Send-TestText '文字'
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class TIn {
  [StructLayout(LayoutKind.Sequential)] struct MI { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct KI { public ushort vk, scan; public uint flags, time; public IntPtr extra; public uint p1, p2; }
  [StructLayout(LayoutKind.Explicit)] struct U { [FieldOffset(0)] public MI mi; [FieldOffset(0)] public KI ki; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public U u; }   // x64 下正好 40 字节；尺寸不对 SendInput 会直接失败
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int size);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(P p);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  public static string ClassOf(IntPtr h) { var s = new System.Text.StringBuilder(128); GetClassName(h, s, 128); return s.ToString(); }
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  public static int Sent;   // 本轮实际发出的输入事件数（单元测试用）
  [StructLayout(LayoutKind.Sequential)] struct LII { public uint cb, t; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII l);
  public static uint LastInput() { var l = new LII { cb = 8 }; GetLastInputInfo(ref l); return l.t; }
  public static uint OurLast;   // 我们自己最后一次发输入的时刻（TickCount）；之后系统又记到输入 = 用户动了
  static void Mark() { OurLast = (uint)Environment.TickCount; }
  public static IntPtr RootAt(int x, int y) { return GetAncestor(WindowFromPoint(new P { X = x, Y = y }), 2); }
  public static uint PidOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  static int S() { return Marshal.SizeOf(typeof(INPUT)); }
  public static void RawClick(int x, int y, bool right) { SetCursorPos(x, y); System.Threading.Thread.Sleep(80); var a = new INPUT[2]; a[0].u.mi.flags = right ? 8u : 2u; a[1].u.mi.flags = right ? 16u : 4u; Sent += (int)SendInput(2, a, S()); Mark(); }
  public static void RawKey(ushort vk) { var a = new INPUT[2]; a[0].type = 1; a[0].u.ki.vk = vk; a[1].type = 1; a[1].u.ki.vk = vk; a[1].u.ki.flags = 2; Sent += (int)SendInput(2, a, S()); Mark(); }
  public static void RawText(string s) { foreach (char c in s) { var a = new INPUT[2]; a[0].type = 1; a[0].u.ki.scan = c; a[0].u.ki.flags = 4; a[1].type = 1; a[1].u.ki.scan = c; a[1].u.ki.flags = 6; Sent += (int)SendInput(2, a, S()); Mark(); System.Threading.Thread.Sleep(15); } }
}
'@
[void][TIn]::SetProcessDpiAwarenessContext([IntPtr]-4)
$script:TestWindowPids = New-Object System.Collections.Generic.List[int]
function Register-TestWindow([int]$pid1) { $script:TestWindowPids.Add($pid1) }
function Get-OurPids { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'v0\.2\\(秘书|边缘线)\.ps1' } | ForEach-Object { [int]$_.ProcessId }) + @($script:TestWindowPids) }
class TestAbort : Exception { TestAbort([string]$m) : base($m) {} }
# 目标位置上是不是我们的窗口；不是时，只把挡着的「普通应用窗口」最小化挪开（记下来，测完恢复）再看一次；
# 桌面、任务栏这些系统外壳窗口绝不去动——点到它们说明目标根本不在那里，直接中止
$script:ShellClasses = 'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'NotifyIconOverflowWindow', 'Windows.UI.Core.CoreWindow'
$script:MovedWindows = New-Object System.Collections.Generic.List[IntPtr]
# 用户一动鼠标或键盘就停：开始时记下时刻和光标位置；每次点击 / 按键前检查系统最后一次输入是不是我们发的、光标是不是还在我们放的位置
$script:WatchOn = $false; $script:LastPos = $null
function Start-InputWatch { [TIn]::OurLast = [uint32][Environment]::TickCount; $p = New-Object TIn+P; [void][TIn]::GetCursorPos([ref]$p); $script:LastPos = $p; $script:WatchOn = $true }
function Assert-NoUserInput {
  if (-not $script:WatchOn) { return }
  $gap = [long][TIn]::LastInput() - [long][TIn]::OurLast; if ($gap -gt 400) { throw [TestAbort]::new("安全中止：检测到你动了鼠标或键盘，测试立刻停下") }
  $p = New-Object TIn+P; [void][TIn]::GetCursorPos([ref]$p); if ($script:LastPos -and ([Math]::Abs($p.X - $script:LastPos.X) -gt 2 -or [Math]::Abs($p.Y - $script:LastPos.Y) -gt 2)) { throw [TestAbort]::new("安全中止：光标被移动过（不是测试移动的），测试立刻停下（距离 $([Math]::Abs($p.X - $script:LastPos.X) + [Math]::Abs($p.Y - $script:LastPos.Y)) 像素）") }
}
function Assert-OursAt([int]$x, [int]$y) {
  $ours = Get-OurPids
  for ($i = 0; $i -lt 3; $i++) {
    $h = [TIn]::RootAt($x, $y); $p = [int][TIn]::PidOf($h)
    if ($ours -contains $p) { return }
    if ($script:TestNoMove -or $script:ShellClasses -contains [TIn]::ClassOf($h)) { break }
    [void][TIn]::ShowWindow($h, 6); $script:MovedWindows.Add($h); Start-Sleep -Milliseconds 400   # 挡在前面的别人的窗口：先挪开
  }
  throw [TestAbort]::new("安全中止：($x,$y) 最上面的窗口不是秘书或测试窗口（进程 $p），一下都不点")
}
# 测完把挪开的窗口恢复（SW_SHOWNOACTIVATE：还原但不抢焦点）
function Restore-MovedWindows { foreach ($h in $script:MovedWindows) { [void][TIn]::ShowWindow($h, 4) }; $script:MovedWindows.Clear() }function Invoke-TestClick([int]$x, [int]$y, [switch]$Right) { Assert-NoUserInput; Assert-OursAt $x $y; [TIn]::RawClick($x, $y, [bool]$Right); $p = New-Object TIn+P; $p.X = $x; $p.Y = $y; $script:LastPos = $p; Start-Sleep -Milliseconds 350 }
function Invoke-TestClickElement($e, [switch]$Right) {
  if (-not $e) { throw [TestAbort]::new('安全中止：要点的元素没找到（不用任何兜底坐标）') }
  $r = $e.Current.BoundingRectangle; if ($r.Width -le 0 -or $e.Current.IsOffscreen) { throw [TestAbort]::new('安全中止：要点的元素不可见') }
  Invoke-TestClick ([int]($r.X + $r.Width / 2)) ([int]($r.Y + $r.Height / 2)) -Right:$Right
}
function Assert-OursForeground { $p = [int][TIn]::PidOf([TIn]::GetForegroundWindow()); if ((Get-OurPids) -notcontains $p) { throw [TestAbort]::new("安全中止：前台窗口不是秘书或测试窗口（进程 $p），不发按键") } }
function Send-TestKey([uint16]$vk) { Assert-NoUserInput; Assert-OursForeground; [TIn]::RawKey($vk) }
function Send-TestText([string]$s) { Assert-NoUserInput; Assert-OursForeground; [TIn]::RawText($s) }
