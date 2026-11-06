# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_软件清单.ps1 — 「添加软件」的软件清单：所有桌面上开着的（包括最小化的、只在托盘里的、商店应用）+ 电脑上装了的
# 以前只列「当前可见、尺寸 ≥200×150」的窗口：最小化的窗口尺寸很小（例如 157×25）、商店应用在 ApplicationFrameHost 里、没开着的装了也看不到，所以清单很短
# 由 lib_虚拟桌面.ps1 引入（用到它的 Get-AppList）
Add-Type @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class AppEnum {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP f, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EP f, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] struct WP { public int len, flags, show; public int mx, my, xx, xy; public RECT normal; }
  [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WP p);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
  public class Win { public IntPtr H; public uint Pid; public string Title, Cls; public bool Visible, Min; }
  static string Cls(IntPtr h) { var s = new StringBuilder(128); GetClassName(h, s, 128); return s.ToString(); }
  // 商店应用：外框属于 ApplicationFrameHost，里面的 CoreWindow 才是真正的应用进程
  public static uint RealPid(IntPtr h, uint pid) {
    if (Cls(h) != "ApplicationFrameWindow") return pid;
    uint real = pid; EnumChildWindows(h, (c, l) => { uint p; GetWindowThreadProcessId(c, out p); if (p != pid) { real = p; return false; } return true; }, IntPtr.Zero); return real;
  }
  // 顶层窗口：有标题、不是被拥有的、不是工具窗口；尺寸按「还原后」的大小算（最小化的也算），别的桌面上的也算
  public static List<Win> List() {
    var r = new List<Win>();
    EnumWindows((h, l) => {
      int len = GetWindowTextLength(h); if (len == 0 || GetWindow(h, 4) != IntPtr.Zero) return true;
      int ex = GetWindowLong(h, -20); if ((ex & 0x80) != 0) return true;
      var wp = new WP(); wp.len = Marshal.SizeOf(typeof(WP)); GetWindowPlacement(h, ref wp);
      if ((wp.normal.R - wp.normal.L) < 200 || (wp.normal.B - wp.normal.T) < 120) return true;
      uint pid; GetWindowThreadProcessId(h, out pid); var sb = new StringBuilder(len + 1); GetWindowText(h, sb, sb.Capacity);
      r.Add(new Win { H = h, Pid = RealPid(h, pid), Title = sb.ToString(), Cls = Cls(h), Visible = IsWindowVisible(h), Min = IsIconic(h) });
      return true; }, IntPtr.Zero);
    return r;
  }
  public static uint PidAt(int x, int y) { var p = new POINT { X = x, Y = y }; IntPtr h = GetAncestor(WindowFromPoint(p), 2); uint pid; GetWindowThreadProcessId(h, out pid); return RealPid(h, pid); }
}
'@
# 不列出来的：系统外壳、后台小部件，以及秘书自己（PowerShell）
$script:CatalogSkip = @('explorer', 'applicationframehost', 'textinputhost', 'shellexperiencehost', 'searchhost', 'searchapp', 'startmenuexperiencehost', 'lockapp', 'dwm', 'csrss', 'ctfmon', 'runtimebroker', 'sihost', 'taskhostw', 'securityhealthsystray', 'widgets', 'widgetservice', 'msedgewebview2', 'powershell', 'pwsh', 'conhost', 'gamebar', 'gamebarftserver', 'systemsettingsbroker', 'shellhost', 'useroobebroker', '秘书')
function Get-ExeName([string]$path, [string]$fallback) {
  if ($path) { try { $vi = (Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo; foreach ($n in $vi.FileDescription, $vi.ProductName) { if ($n -and $n.Trim().Length -ge 2 -and $n -notmatch '^(Microsoft®? Windows®? Operating System|Windows)$') { return $n.Trim() } } } catch {} }
  $fallback
}
function Get-AddedKeys { $s = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($a in Get-AppList) { [void]$s.Add(([string]$a.proc).ToLower()); [void]$s.Add(([string]$a.name).ToLower()) }; $s }
# 正在运行：每个软件一行；在别的桌面 / 最小化 / 只在托盘里都标出来
function Get-RunningApps {
  $have = Get-AddedKeys; $byPid = @{}
  foreach ($w in [AppEnum]::List()) { $k = [int]$w.Pid; if (-not $byPid[$k]) { $byPid[$k] = New-Object System.Collections.ArrayList }; [void]$byPid[$k].Add($w) }
  $seen = @{}; $out = New-Object System.Collections.Generic.List[object]
  foreach ($k in @($byPid.Keys)) {
    if ($k -eq $PID) { continue }
    $p = Get-Process -Id $k -ErrorAction SilentlyContinue; if (-not $p) { continue }
    $n = $p.ProcessName; $ln = $n.ToLower(); if ($script:CatalogSkip -contains $ln -or $seen[$ln]) { continue }
    $ws = @($byPid[$k]); $vis = @($ws | Where-Object { $_.Visible })
    $path = try { $p.Path } catch { '' }
    if (-not $vis.Count -and ($path -like "$env:windir\*" -or -not $path)) { continue }   # 系统后台进程的隐藏窗口不算
    $seen[$ln] = $true
    $state = if (-not $vis.Count) { 'tray' } elseif (@($vis | Where-Object { -not $_.Min }).Count) { 'running' } else { 'minimized' }
    $out.Add([ordered]@{ key = "p:$ln"; name = (Get-ExeName $path $n); proc = $n; exe = [string]$path; aumid = ''; state = $state; added = $have.Contains($ln) })
  }
  @($out | Sort-Object { $_.name })
}
# 电脑上装了的：开始菜单快捷方式（两个位置）+ 商店应用；跳过卸载、帮助、说明之类；缓存 10 分钟
$script:InstalledCache = $null; $script:InstalledAt = [datetime]::MinValue
function Get-InstalledApps([switch]$Fresh) {
  if (-not $Fresh -and $script:InstalledCache -and ((Get-Date) - $script:InstalledAt).TotalMinutes -lt 10) { $list = $script:InstalledCache }
  else {
    $sh = New-Object -ComObject WScript.Shell; $byExe = @{}; $list = New-Object System.Collections.Generic.List[object]
    $bad = '卸载|uninstall|unins|帮助|help|readme|说明|手册|manual|文档|document|website|官网|网站|license|许可|support|支持|release notes|更新日志|修复|repair|安全模式|safe mode'
    foreach ($dir in "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs") {
      foreach ($l in Get-ChildItem $dir -Recurse -Filter *.lnk -ErrorAction SilentlyContinue) {
        if ($l.BaseName -match $bad) { continue }
        $t = try { $sh.CreateShortcut($l.FullName).TargetPath } catch { '' }
        if (-not $t -or $t -notlike '*.exe' -or $t -match $bad -or $byExe[$t.ToLower()]) { continue }
        $byExe[$t.ToLower()] = 1; $list.Add([ordered]@{ key = "x:$($t.ToLower())"; name = $l.BaseName; proc = [IO.Path]::GetFileNameWithoutExtension($t); exe = $t; aumid = '' })
      }
    }
    $names = @{}; foreach ($x in $list) { $names[$x.name.ToLower()] = 1 }
    try { foreach ($a in Get-StartApps) { if ($a.AppID -notmatch '!' -or $names[$a.Name.ToLower()] -or $a.Name -match $bad) { continue }; $names[$a.Name.ToLower()] = 1; $list.Add([ordered]@{ key = "s:$($a.AppID)"; name = $a.Name; proc = ''; exe = ''; aumid = $a.AppID }) } } catch {}
    $script:InstalledCache = $list; $script:InstalledAt = Get-Date
  }
  $have = Get-AddedKeys; $run = @{}; foreach ($p in Get-Process) { $run[$p.ProcessName.ToLower()] = 1 }
  @($list | Sort-Object { $_.name } | ForEach-Object { $x = [ordered]@{}; foreach ($k in $_.Keys) { $x[$k] = $_[$k] }
    $x.added = ($x.proc -and $have.Contains($x.proc.ToLower())) -or $have.Contains($x.name.ToLower()); $x.state = $(if ($x.proc -and $run[$x.proc.ToLower()]) { 'running' } else { 'installed' }); $x })
}
# 选了一个没开着的软件：用户选的，就把它打开；返回打开后的进程名（商店应用打开前不知道进程名，看新出现的窗口）
function Start-PickedApp($a) {
  $before = @{}; foreach ($p in Get-Process) { $before[$p.Id] = 1 }
  if ($a.exe -and (Test-Path -LiteralPath $a.exe)) { Start-Process -FilePath $a.exe } elseif ($a.aumid) { Start-Process "shell:AppsFolder\$($a.aumid)" } else { return $null }
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if ($a.proc -and (Get-Process $a.proc -ErrorAction SilentlyContinue)) { return $a.proc }
    $new = [AppEnum]::List() | Where-Object { $_.Visible -and -not $before[[int]$_.Pid] } | Select-Object -First 1
    if ($new) { return (Get-Process -Id ([int]$new.Pid)).ProcessName }
  }
  $null
}
# 「点一下窗口」：按点到的位置找软件（秘书自己的窗口不算）
function Get-AppAtPoint([int]$x, [int]$y) {
  $pid1 = [int][AppEnum]::PidAt($x, $y); if (-not $pid1 -or $pid1 -eq $PID) { return $null }
  $p = Get-Process -Id $pid1 -ErrorAction SilentlyContinue; if (-not $p -or $script:CatalogSkip -contains $p.ProcessName.ToLower()) { return $null }
  $path = try { $p.Path } catch { '' }
  [ordered]@{ key = "p:$($p.ProcessName.ToLower())"; name = (Get-ExeName $path $p.ProcessName); proc = $p.ProcessName; exe = [string]$path; aumid = ''; state = 'running'; added = (Get-AddedKeys).Contains($p.ProcessName.ToLower()) }
}
# 按名字找（对话里说「连接 X」）：列表里的 → 开着的 → 装了的；有多个时全部返回，界面弹出已经筛好的选择器
function Find-AppCandidates([string]$q) {
  $q = $q.Trim(); if (-not $q) { return @() }; $ql = $q.ToLower()
  $m = { param($a) $n = ([string]$a.name).ToLower(); $n.Contains($ql) -or ([string]$a.proc).ToLower().Contains($ql) -or ($n.Length -ge 2 -and $ql.Contains($n)) }
  $inList = @(Get-AppList | Where-Object { & $m $_ }); if ($inList.Count -eq 1) { return @([ordered]@{ name = $inList[0].name; proc = $inList[0].proc; exe = $inList[0].exe; aumid = ''; inList = $true; id = $inList[0].id; state = 'added' }) }
  $seen = @{}
  @(@(Get-RunningApps) + @(Get-InstalledApps) | Where-Object { & $m $_ } | Where-Object { $k = if ($_.proc) { $_.proc.ToLower() } else { $_.key }; if ($seen[$k]) { $false } else { $seen[$k] = 1; $true } })
}
