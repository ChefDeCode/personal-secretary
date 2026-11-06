# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 添加软件选择器：像真实用户一样测（真实鼠标/键盘 SendInput，只点秘书自己的窗口和测试窗口）
# 搜索找到没打开的「记事本」→ 选它 → 开始适配（会替用户打开记事本）→ 用新的移除流程移除；浏览… 能打开；点一下窗口能选中测试窗口
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
$p0 = New-Object UI+P; [void][UI]::GetCursorPos([ref]$p0); $notepadBefore = @(Get-Process Notepad -ErrorAction SilentlyContinue | ForEach-Object Id); $tw = $null
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
  }  $add = Find '添加软件'; Assert $add "main window open; 添加软件 visible"
  $sw = [Diagnostics.Stopwatch]::StartNew(); ClickEl $add; $q = Find '搜索软件'; Assert $q "picker opened ($($sw.ElapsedMilliseconds) ms)"
  $run = Find '正在运行' 3000; $runCount = @((MainWin).FindAll($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)))).Count
  # 搜索：找没打开的记事本
  ClickEl $q; Send-TestText '记事本'; Start-Sleep -Milliseconds 800
  $np = Find '记事本' 8000 -Contains; $npRow = $null; foreach ($e in (MainWin).FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) { if ($e.Current.Name -like '*记事本*' -and $e.Current.ControlType -eq [Windows.Automation.ControlType]::ListItem) { $npRow = $e; break } }
  if (-not $npRow) { $npRow = $np }
  Assert ($npRow -and $npRow.Current.Name -match '没打开|商店应用|开着') "search 「记事本」 finds it under 电脑上的软件 (row: $(if ($npRow) { ($npRow.Current.Name -replace '\s+', ' ').Substring(0, [Math]::Min(30, ($npRow.Current.Name -replace '\s+', ' ').Length)) }))"
  ClickEl $npRow; $go = Find '开始适配'; Assert $go "picking it shows the confirm card"
  $sw.Restart(); ClickEl $go
  $newNp = $null; for ($i = 0; $i -lt 40 -and -not $newNp; $i++) { Start-Sleep -Milliseconds 300; $newNp = Get-Process Notepad -ErrorAction SilentlyContinue | Where-Object { $notepadBefore -notcontains $_.Id } | Select-Object -First 1 }
  Assert $newNp "开始适配 on a not-running app starts it ($($sw.ElapsedMilliseconds) ms)"
  # 等适配结果（最多 90 秒；只看状态，不看内容）
  $sf = "$v2\data\adapters\Notepad.status.json"; $st = $null; $sw.Restart(); while ($sw.Elapsed.TotalSeconds -lt 90) { if (Test-Path $sf) { $st = Get-Content $sf -Raw | ConvertFrom-Json; if ($st.state -in 'ready', 'failed') { break } }; Start-Sleep 2 }
  "   adaptation: state $($st.state), steps seen: $(@($st.steps).Count), $([int]$sw.Elapsed.TotalSeconds) s, self-check $(if ($st.check) { $st.check.ok } else { 'n/a' })"
  Assert ($st -and $st.state -in 'ready', 'failed') "adaptation finished with a result ($($st.state))"
  # 用新的移除流程移除：侧栏那一行右键 → 移除 → 确认
  $row = $null; foreach ($e in (MainWin).FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) { if ($e.Current.Name -like '记事本：*' -and $e.Current.ControlType -eq [Windows.Automation.ControlType]::ListItem) { $row = $e; break } }
  Assert $row "记事本 is in the sidebar list"
  if (-not $row) { throw 'sidebar row not found' }; ClickEl $row -Right; $mi = Find '移除' 3000; if (-not $mi) { throw 'menu not found' }; ClickEl $mi; $yes = $null; foreach ($e in (MainWin).FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) { if ($e.Current.Name -eq '移除' -and $e.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $e.Current.BoundingRectangle.Y -gt 200) { $yes = $e } }
  if (-not $yes) { throw 'confirm not found' }; ClickEl $yes; Start-Sleep 9
  Assert (-not (Test-Path "$v2\data\adapters\Notepad.json") -and -not ((Get-Content (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).apps | Where-Object { $_.proc -eq 'Notepad' })) "removed with the removal flow: off the list, adapter deleted"
  # 浏览…：能打开文件对话框（Esc 关掉）
  ClickEl (Find '添加软件'); ClickEl (Find '浏览…'); Start-Sleep -Milliseconds 1200
  $dlg = $AE::RootElement.FindFirst($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, '选择要添加的软件')))
  Assert $dlg "浏览… opens the file dialog"; if ($dlg) { Send-TestKey 0x1B; Start-Sleep -Milliseconds 600 }
  # 点一下窗口：选中我们自己的测试窗口
  $tw = Start-Process "$PSScriptRoot\秘书测试窗口.exe" -ArgumentList '200', '200' -PassThru; Start-Sleep 2
  ClickEl (Find '点一下窗口'); Start-Sleep -Milliseconds 700
  Register-TestWindow $tw.Id; ClickAt 500 400; Start-Sleep -Milliseconds 1200
  $card = Find '秘书测试窗口' 4000 -Contains; Assert $card "点一下窗口 picked our test window (confirm card shows it)"
  $no = $null; foreach ($e in (MainWin).FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) { if ($e.Current.Name -eq '先不加') { $no = $e } }; if ($no) { ClickEl $no }
} catch [TestAbort] { "  [ABORT] $($_.Exception.Message)" } finally {
  Restore-MovedWindows
  [void][UI]::SetCursorPos($p0.X, $p0.Y)
  if ($tw -and -not $tw.HasExited) { $tw.Kill() }
  if ($newNp) { Stop-Process -Id $newNp.Id -ErrorAction SilentlyContinue }   # 只关测试时替我们打开的那个（空白）记事本
}
"RESULT: $script:ok / $script:tot passed"
