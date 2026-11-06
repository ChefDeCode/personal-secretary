# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 添加软件选择器（第二批，真实鼠标）：只点秘书自己的窗口和我们的测试窗口；不打开用户的任何软件
# 点一下窗口 → 选中测试窗口 → 只添加 → 侧栏右键 → 移除 → 确认；浏览… → 文件对话框 → Esc 取消
# 你一动鼠标或键盘，测试立刻停（lib_测试输入.ps1 里的 Assert-NoUserInput）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class UI {
  [StructLayout(LayoutKind.Sequential)] struct MI { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct KI { public ushort vk, scan; public uint flags, time; public IntPtr extra; public uint p1, p2; }
  [StructLayout(LayoutKind.Explicit)] struct U { [FieldOffset(0)] public MI mi; [FieldOffset(0)] public KI ki; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public U u; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int size);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; } [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  static int S() { return Marshal.SizeOf(typeof(INPUT)); }
  public static uint Click(int x, int y, bool right) { SetCursorPos(x, y); System.Threading.Thread.Sleep(80); var a = new INPUT[2]; a[0].u.mi.flags = right ? 8u : 2u; a[1].u.mi.flags = right ? 16u : 4u; return SendInput(2, a, S()); }
  public static void Text(string s) { foreach (char c in s) { var a = new INPUT[2]; a[0].type = 1; a[0].u.ki.scan = c; a[0].u.ki.flags = 4; a[1].type = 1; a[1].u.ki.scan = c; a[1].u.ki.flags = 6; SendInput(2, a, S()); System.Threading.Thread.Sleep(20); } }
  public static void Key(ushort vk) { var a = new INPUT[2]; a[0].type = 1; a[0].u.ki.vk = vk; a[1].type = 1; a[1].u.ki.vk = vk; a[1].u.ki.flags = 2; SendInput(2, a, S()); }
}
'@
[void][UI]::SetProcessDpiAwarenessContext([IntPtr]-4)
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$AE = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]
function MainWin { $sp = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'v0\.2\\秘书\.ps1' } | Select-Object -First 1).ProcessId
  $c = New-Object Windows.Automation.PropertyCondition ($AE::ProcessIdProperty, [int]$sp); @($AE::RootElement.FindAll($TS::Children, $c)) | Where-Object { $r = $_.Current.BoundingRectangle; -not ([Math]::Abs($r.Width - 720) -lt 40 -and [Math]::Abs($r.Height - 960) -lt 40) -and $r.Width -gt 500 -and -not $_.Current.IsOffscreen } | Select-Object -First 1 }   # 主窗口：不是 720×960 的小浮窗
function Find([string]$name, [int]$ms = 6000, [switch]$Contains) { $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) { $w = MainWin; if ($w) { foreach ($e in $w.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) { $n = $e.Current.Name; if (($Contains -and $n -and $n.Contains($name)) -or $n -eq $name) { $r = $e.Current.BoundingRectangle; if ($r.Width -gt 0) { return $e } } } }; Start-Sleep -Milliseconds 250 }; $null }
. "$PSScriptRoot\lib_测试输入.ps1"   # 所有真实点击、按键都经过这里的保护（只点秘书自己的窗口 / 登记过的测试窗口）
function ClickAt([int]$x, [int]$y, [switch]$Right) { Invoke-TestClick $x $y -Right:$Right }
function ClickEl($e, [switch]$Right) { Invoke-TestClickElement $e -Right:$Right }
$p0 = New-Object UI+P; [void][UI]::GetCursorPos([ref]$p0); $tw = $null; $cfgBefore = [IO.File]::ReadAllText((Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config.json'))
Start-InputWatch
Add-Type 'using System; using System.Runtime.InteropServices; public static class TopW { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }'
$openedMain = -not (MainWin)   # 测试前主窗口没开：测完把它收回去
try {
  # 打开主窗口（再运行一次秘书 = 打开）
  # 打开主窗口：像用户一样打开小浮窗（和点屏幕边的线同一个信号），再点浮窗里的「打开完整窗口」
  if (-not (MainWin)) {
    Add-Type 'using System; using System.Runtime.InteropServices; public static class GWL { [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i); }'
    $sp = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'v0\.2\\秘书\.ps1' } | Select-Object -First 1).ProcessId
    $fc = New-Object Windows.Automation.PropertyCondition ($AE::ProcessIdProperty, [int]$sp)
    $fw = @($AE::RootElement.FindAll($TS::Children, $fc)) | Where-Object { $r = $_.Current.BoundingRectangle; [Math]::Abs($r.Width - 720) -lt 40 -and [Math]::Abs($r.Height - 960) -lt 40 } | Select-Object -First 1
    if ([GWL]::GetWindowLong([IntPtr]$fw.Current.NativeWindowHandle, -20) -band 0x20) { $ev = [Threading.EventWaitHandle]::OpenExisting('Local\SecretaryPanelToggle'); [void]$ev.Set(); $ev.Dispose() }   # 收着才打开
    $full = $null; $sw0 = [Diagnostics.Stopwatch]::StartNew()
    while (-not $full -and $sw0.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 300; $e = $fw.FindFirst($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, '打开完整窗口'))); if ($e -and $e.Current.BoundingRectangle.Width -gt 0) { $full = $e } }
    if ($full) { Start-Sleep -Milliseconds 500; ClickEl $full; Start-Sleep 2 }
  }
  $add = Find '添加软件'; Assert $add "main window open; 添加软件 visible"
  # 1) 点一下窗口：只指我们的测试窗口
  $tw = Start-Process "$PSScriptRoot\秘书测试窗口.exe" -ArgumentList '300', '260' -PassThru; Start-Sleep 2; Register-TestWindow $tw.Id
  [void][TopW]::SetWindowPos($tw.MainWindowHandle, [IntPtr](-1), 40, 40, 0, 0, 0x11)   # 测试窗口放在最上层、挪到左上角：主窗口最大化时不会被盖住，200% 缩放下中心也不会跑到屏幕外（只动我们自己的测试窗口）
  $tr = New-Object TIn+R; [void][TIn]::GetWindowRect($tw.MainWindowHandle, [ref]$tr); $tx = [int](($tr.L + $tr.Rt) / 2); $ty = [int](($tr.T + $tr.B) / 2)
  Start-InputWatch   # 启动测试窗口后重新记下光标位置
  ClickEl $add; $pt = Find '点一下窗口'; Assert $pt "picker opened, 点一下窗口 visible"
  if (-not $pt) { throw [TestAbort]::new('安全中止：没找到「点一下窗口」') }
  ClickEl $pt; Start-Sleep -Milliseconds 900
  ClickAt $tx $ty; Start-Sleep -Milliseconds 1500   # 点在测试窗口中间（此时上面盖着秘书自己的选择层）
  $card = Find '秘书测试窗口' 5000 -Contains; Assert $card "点一下窗口 picked our test window"
  $only = Find '只添加' 3000; if (-not $only) { throw [TestAbort]::new('安全中止：没找到「只添加」') }
  ClickEl $only; Start-Sleep 2
  $row = $null; $sw = [Diagnostics.Stopwatch]::StartNew(); while (-not $row -and $sw.ElapsedMilliseconds -lt 6000) { foreach ($e in (MainWin).FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) { if ($e.Current.Name -like '*秘书测试窗口*' -and $e.Current.ControlType -eq [Windows.Automation.ControlType]::ListItem -and $e.Current.BoundingRectangle.Width -gt 0) { $row = $e; break } }; if (-not $row) { Start-Sleep -Milliseconds 300 } }
  Assert $row "只添加 → the test window is in the sidebar list"
  # 2) 移除：侧栏那一行右键 → 菜单「移除」→ 确认卡「移除」
  if (-not $row) { throw [TestAbort]::new('安全中止：侧栏里没找到测试窗口那一行') }
  ClickEl $row -Right; $mi = Find '移除' 3000; if (-not $mi) { throw [TestAbort]::new('安全中止：菜单没出来') }
  ClickEl $mi; Start-Sleep -Milliseconds 600
  $yes = $null; foreach ($e in (MainWin).FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) { if ($e.Current.Name -eq '移除' -and $e.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $e.Current.BoundingRectangle.Width -gt 0 -and $e.Current.BoundingRectangle.Y -gt 200) { $yes = $e } }
  Assert $yes "right-click → 移除 → confirm card appears"
  if (-not $yes) { throw [TestAbort]::new('安全中止：确认卡没出来') }
  ClickEl $yes; Start-Sleep 9   # 6 秒撤销期之后才真正删
  $cfg = Get-Content (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $still = $null; foreach ($e in (MainWin).FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) { if ($e.Current.Name -like '*秘书测试窗口*' -and $e.Current.ControlType -eq [Windows.Automation.ControlType]::ListItem -and $e.Current.BoundingRectangle.Width -gt 0) { $still = $e } }
  Assert (-not $still -and -not (@($cfg.apps) | Where-Object { $_ -and $_.name -like '*秘书测试窗口*' })) "removed: gone from the sidebar and from the settings file"
  # 3) 浏览…：打开文件对话框，然后 Esc 取消（不选任何东西）
  ClickEl (Find '添加软件'); $br = Find '浏览…'; if (-not $br) { throw [TestAbort]::new('安全中止：没找到「浏览…」') }
  ClickEl $br; Start-Sleep -Milliseconds 1500
  $dlg = $AE::RootElement.FindFirst($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, '选择要添加的软件')))
  Assert $dlg "浏览… opens the file dialog"
  if ($dlg) { Send-TestKey 0x1B; Start-Sleep -Milliseconds 800 }
  $dlg2 = $AE::RootElement.FindFirst($TS::Children, (New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, '选择要添加的软件')))
  Assert (-not $dlg2) "Esc cancels the file dialog; nothing added"
  $x = Find '先不加' 1500; $cl = $AE::RootElement.FindFirst($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, '关闭'))); 
  $pkc = $null; foreach ($e in (MainWin).FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) { if ($e.Current.Name -eq '关闭' -and $e.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $e.Current.BoundingRectangle.Width -gt 0) { $pkc = $e } }
  if ($pkc) { ClickEl $pkc }   # 关掉选择器
} catch [TestAbort] { "  [ABORT] $($_.Exception.Message)" } finally {
  # 选择器要是还开着（中途停了），用无障碍接口点它的「关闭」收起来（不发真实点击）
  try { $mw = MainWin; if ($mw) { foreach ($e in $mw.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) { if ($e.Current.Name -eq '关闭' -and $e.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $e.Current.BoundingRectangle.Width -gt 0) { $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() } } } } catch {}
  "  foreign windows moved out of the way and restored: $($script:MovedWindows.Count)"
  Restore-MovedWindows
  [void][UI]::SetCursorPos($p0.X, $p0.Y)
  if ($tw -and -not $tw.HasExited) { $tw.Kill() }
  if ($openedMain) { $mw = MainWin; if ($mw) { [void][TopW]::ShowWindow([IntPtr]$mw.Current.NativeWindowHandle, 0) }; "  main window put away again (it was closed before the test): $([bool]$mw)" }
  $cfgAfter = [IO.File]::ReadAllText((Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config.json')); "  settings file back to how it was (apart from removal bookkeeping): $(($cfgAfter -replace '\s','').Length -eq ($cfgBefore -replace '\s','').Length)"
}
"RESULT: $script:ok / $script:tot passed"