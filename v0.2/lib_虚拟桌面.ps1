# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_虚拟桌面.ps1 — 窗口和侧栏软件列表的小工具（文件名是历史名字：「桌面 2」那一套已经挪到 旧东西\桌面2和后台发送，不再挪窗口到别的虚拟桌面）
# WxWin：找微信主窗口、显示 / 前台；AppWin：找某个软件最大的正常窗口；软件列表：点一下叫到眼前，再点一下最小化
Add-Type @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class WxWin {
  delegate bool CB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr h, IntPtr r, IntPtr rgn, uint f);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int n);
  // 同一桌面上 Z 序紧挨着的下一个“正常”窗口（可见、没被隐藏到别的桌面、不是工具窗口、不是 owner 窗口）
  public static IntPtr NextNormal(IntPtr h) {
    for (IntPtr w = GetWindow(h, 2); w != IntPtr.Zero; w = GetWindow(w, 2)) {   // GW_HWNDNEXT
      if (!IsWindowVisible(w) || IsIconic(w)) continue;
      int ex = GetWindowLong(w, -20); if ((ex & 0x80) != 0 || (ex & 0x08000000) != 0) continue;   // 工具窗口 / 不激活
      if (GetWindow(w, 4) != IntPtr.Zero) continue;                                                 // 有 owner
      int cl; DwmGetWindowAttribute(w, 14, out cl, 4); if (cl != 0) continue;                       // 隐藏在别的桌面
      RECT r; GetWindowRect(w, out r); if (r.R - r.L < 50 || r.B - r.T < 50) continue;
      return w; }
    return IntPtr.Zero; }
  // 挪过来以后让它马上重画（在桌面 2 时渲染被系统节流过）
  public static void Kick(IntPtr h) { RedrawWindow(h, IntPtr.Zero, IntPtr.Zero, 0x1 | 0x80 | 0x100 | 0x400); SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x1 | 0x2 | 0x4 | 0x10 | 0x20); }
  // 微信主窗口（包括关在托盘里的隐藏窗口）：微信进程里面积最大的 Qt 主窗口类窗口
  public static IntPtr FindMain(uint[] pids) {
    IntPtr best = IntPtr.Zero; long area = 0;
    EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid); if (Array.IndexOf(pids, pid) < 0) return true;
      var sb = new StringBuilder(128); GetClassName(h, sb, 128); if (!sb.ToString().EndsWith("QWindowIcon")) return true;
      RECT r; GetWindowRect(h, out r); long a = (long)(r.R - r.L) * (r.B - r.T); if (IsWindowVisible(h)) a += (long)1 << 40; if (a > area) { area = a; best = h; } return true; }, IntPtr.Zero);   // 可见的（包括最小化的，最小化时窗口尺寸很小）优先于隐藏的同类窗口
    return best; }
}
'@

# 窗口在不在你现在这个桌面上（被系统藏到别的虚拟桌面的窗口会被「隐藏」标记）
function Test-OnOtherDesktop([IntPtr]$h) { try { [Rec]::Cloaked($h) -ne 0 } catch { $false } }
# 把微信叫到眼前（不挪桌面）：最小化的还原、托盘里的显示出来、放到前台；微信在别的桌面上就不去动它，告诉你
function Move-WeChatHere {
  $p = Get-Process Weixin -ErrorAction SilentlyContinue; if (-not $p) { return @{ ok = $false; text = '微信没有在运行' } }
  $h = [WxWin]::FindMain([uint32[]]$p.Id); if ($h -eq [IntPtr]::Zero) { return @{ ok = $false; text = '没找到微信窗口' } }
  if ([WxWin]::IsWindowVisible($h) -and (Test-OnOtherDesktop $h)) { return @{ ok = $false; text = '微信在别的桌面上：切到那个桌面用它，或者按 Win+Tab 把它拖到这个桌面' } }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  if (-not [WxWin]::IsWindowVisible($h)) { [void][WxWin]::ShowWindow($h, 5) }   # 关在托盘里：显示出来
  if ([WxWin]::IsIconic($h)) { [void][WxWin]::ShowWindow($h, 9) }   # 最小化：还原
  [void][WxWin]::SetForegroundWindow($h)
  @{ ok = $true; text = "微信已经到你这边了（$($sw.ElapsedMilliseconds) 毫秒）"; ms = $sw.ElapsedMilliseconds }
}
# 快捷键：微信不在眼前 → 叫过来；已经在最前面 → 最小化
function Invoke-WeChatToggle {
  $p = Get-Process Weixin -ErrorAction SilentlyContinue; if (-not $p) { return @{ ok = $false; text = '微信没有在运行' } }
  $h = [WxWin]::FindMain([uint32[]]$p.Id)
  if ($h -ne [IntPtr]::Zero -and [WxWin]::GetForegroundWindow() -eq $h -and -not [WxWin]::IsIconic($h)) { [void][WxWin]::ShowWindow($h, 6); return @{ ok = $true; text = '微信已最小化' } }
  Move-WeChatHere }
# 微信是不是就在你眼前（看得见、没最小化、在这个桌面上）
function Test-WeChatHere {
  $p = Get-Process Weixin -ErrorAction SilentlyContinue; if (-not $p) { return $false }
  $h = [WxWin]::FindMain([uint32[]]$p.Id); $h -ne [IntPtr]::Zero -and [WxWin]::IsWindowVisible($h) -and -not [WxWin]::IsIconic($h) -and -not (Test-OnOtherDesktop $h)
}
# ———————————— 软件列表（侧栏“对话”下面）：叫到眼前 / 最小化；微信和 Edge 自带，其余是用户自己加的 ————————————
Add-Type @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class AppWin {
  delegate bool CB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  struct RECT { public int L, T, R, B; }
  static bool Normal(IntPtr h) {
    if (!IsWindowVisible(h) || GetWindowTextLength(h) == 0 || GetWindow(h, 4) != IntPtr.Zero) return false;
    int ex = GetWindowLong(h, -20); if ((ex & 0x80) != 0 || (ex & 0x08000000) != 0) return false;
    RECT r; GetWindowRect(h, out r); return (r.R - r.L) >= 200 && (r.B - r.T) >= 150; }
  // 这些进程里面积最大的“正常”顶层窗口（在别的桌面上的也算）
  public static IntPtr Largest(uint[] pids) {
    IntPtr best = IntPtr.Zero; long area = 0;
    EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid); if (Array.IndexOf(pids, pid) < 0 || !Normal(h)) return true;
      RECT r; GetWindowRect(h, out r); long a = (long)(r.R - r.L) * (r.B - r.T); if (IsWindowVisible(h)) a += (long)1 << 40; if (a > area) { area = a; best = h; } return true; }, IntPtr.Zero);   // 可见的（包括最小化的，最小化时窗口尺寸很小）优先于隐藏的同类窗口
    return best; }
  // 所有有正常窗口的进程 id（给“添加软件”列清单用）
  public static uint[] Pids() { var s = new HashSet<uint>(); EnumWindows((h, l) => { if (Normal(h)) { uint p; GetWindowThreadProcessId(h, out p); s.Add(p); } return true; }, IntPtr.Zero); var a = new uint[s.Count]; s.CopyTo(a); return a; }
}
'@
$script:BuiltinApps = @(
  [ordered]@{ id = 'wechat'; name = '微信'; proc = 'Weixin'; exe = ''; adapted = $true; builtin = $true }
  [ordered]@{ id = 'edge'; name = 'Edge'; proc = 'msedge'; exe = 'msedge'; adapted = $false; builtin = $true }
)
function Get-AppList {
  # 内置的（微信、Edge）也可以移除：记在 config.removed_builtins 里；从「添加软件」加回来时去掉
  $gone = @((Read-Config).removed_builtins); $list = New-Object System.Collections.ArrayList; foreach ($a in $script:BuiltinApps) { if ($gone -notcontains $a.id) { [void]$list.Add($a) } }
  foreach ($a in @((Read-Config).apps)) { if ($a -and $a.proc) { [void]$list.Add([ordered]@{ id = [string]$a.id; name = [string]$a.name; proc = [string]$a.proc; exe = [string]$a.exe; adapted = $false; builtin = $false; readMode = [string]$a.readMode }) } }
  $list
}
function Get-AppWindow($app) {
  $p = @(Get-Process $app.proc -ErrorAction SilentlyContinue); if (-not $p.Count) { return $null }
  $h = if ($app.id -eq 'wechat') { [WxWin]::FindMain([uint32[]]$p.Id) } else { [AppWin]::Largest([uint32[]]$p.Id) }
  if ($h -eq [IntPtr]::Zero) { return $null }; $h
}
# 自动适配的进度（适配.ps1 写的状态文件）：adapting / ready / failed；partial = 只适配了会话列表（还没打开过会话）
function Get-AdaptStatus([string]$proc) {
  $f = Join-Path $script:V2Data "adapters\$proc.status.json"
  if (-not (Test-Path $f)) { return @{ state = ''; partial = $false; step = '' } }
  try { $s = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    # 适配进程如果中途没了，状态还停在 adapting 超过 3 分钟，就当失败
    $st = [string]$s.state; if ($st -eq 'adapting' -and ((Get-Date) - [datetime]$s.ts).TotalMinutes -gt 3) { $st = 'failed' }
    @{ state = $st; partial = [bool]$s.check.partial; step = [string]$s.step; reason = [string]$s.reason; usd = $s.usd } } catch { @{ state = ''; partial = $false; step = '' } }
}
# 启动自动适配（后台单独进程，不卡界面）；必须在用户点了确认卡之后才调用
function Start-Adapt([string]$proc, [string]$name) {
  if ((Get-AdaptStatus $proc).state -eq 'adapting') { return '已经在适配了' }
  if (-not (Get-Permission 'cloud_images')) { return '没有打开「图片交给 Claude」，不能自动适配；可以在 设置 → AI 与隐私 里打开' }
  $f = Join-Path $script:V2Data "adapters\$proc.status.json"; New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null
  [IO.File]::WriteAllText($f, (@{ proc = $proc; name = $name; state = 'adapting'; step = '准备'; ts = (Get-Date).ToString('o') } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
  Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot '适配.ps1'), '-Proc', $proc, '-Name', $name)
  ''
}
# 每个软件：有没有在运行、是否就在用户眼前（当前桌面、可见、没最小化）、读取有没有适配好
function Get-AppsState {
  foreach ($a in Get-AppList) {
    $h = Get-AppWindow $a
    $here = [bool]($h -and [WxWin]::IsWindowVisible($h) -and -not [WxWin]::IsIconic($h) -and -not (Test-OnOtherDesktop $h))
    $ad = Get-AdaptStatus $a.proc
    [ordered]@{ id = $a.id; name = $a.name; proc = $a.proc; running = [bool](Get-Process $a.proc -ErrorAction SilentlyContinue); here = $here; adapted = [bool]$a.adapted; builtin = [bool]$a.builtin; readMode = [string]$a.readMode
                adapt = $ad.state; adaptPartial = $ad.partial; adaptStep = $ad.step }
  }
}
# 点一下：没在你眼前 → 叫到眼前（还原、放到前台）；已经在你眼前的最前面 → 最小化；没打开 → 正常打开
function Invoke-AppToggle([string]$id) {
  $a = Get-AppList | Where-Object { $_.id -eq $id } | Select-Object -First 1; if (-not $a) { return @{ ok = $false; text = '列表里没有这个软件' } }
  if (-not (Get-Process $a.proc -ErrorAction SilentlyContinue)) {
    if ($a.exe) { try { Start-Process $a.exe; return @{ ok = $true; text = "正在打开$($a.name)" } } catch { return @{ ok = $false; text = "打不开$($a.name)：$(if (Get-Command Format-UserError -ErrorAction SilentlyContinue) { Format-UserError $_.Exception.Message } else { '这一步出错了' })" } } }
    return @{ ok = $false; text = "$($a.name)没有打开" }
  }
  $h = Get-AppWindow $a; if (-not $h) { return @{ ok = $false; text = "没找到$($a.name)的窗口" } }
  if ([WxWin]::IsWindowVisible($h) -and (Test-OnOtherDesktop $h)) { return @{ ok = $false; text = "$($a.name)在别的桌面上：切到那个桌面用它，或者按 Win+Tab 把它拖到这个桌面" } }
  if ([WxWin]::GetForegroundWindow() -eq $h -and -not [WxWin]::IsIconic($h)) { [void][WxWin]::ShowWindow($h, 6); return @{ ok = $true; text = "$($a.name)已最小化" } }   # SW_MINIMIZE
  if (-not [WxWin]::IsWindowVisible($h)) { [void][WxWin]::ShowWindow($h, 5) }
  if ([WxWin]::IsIconic($h)) { [void][WxWin]::ShowWindow($h, 9) }
  [void][WxWin]::SetForegroundWindow($h)
  @{ ok = $true; text = "$($a.name)已经到你这边了" }
}
# “添加软件”：列出现在开着窗口的软件（按进程去重，用软件自己的名字，不显示窗口标题以免带出聊天/文件名）

function Add-App([string]$proc, [string]$name, [string]$exe) {
  $cfg = Read-Config; $apps = @($cfg.apps | Where-Object { $_ })
  $bi = $script:BuiltinApps | Where-Object { $_.proc -eq $proc } | Select-Object -First 1
  if ($bi) { $cfg | Add-Member -NotePropertyName removed_builtins -NotePropertyValue @(@($cfg.removed_builtins) | Where-Object { $_ -and $_ -ne $bi.id }) -Force; Save-Config $cfg; return }   # 内置的：加回来即可
  if ($apps | Where-Object { $_.proc -eq $proc }) { return }
  $apps += [pscustomobject]@{ id = 'app_' + $proc.ToLower(); name = $name.Substring(0, [Math]::Min(40, $name.Length)); proc = $proc; exe = $exe }
  $cfg | Add-Member -NotePropertyName apps -NotePropertyValue @($apps) -Force; Save-Config $cfg
}
# 现在开着的软件（还没在列表里的）：「添加软件」和按名字找软件用
function Get-OpenApps {
  $have = @(Get-AppList | ForEach-Object { $_.proc.ToLower() })
  $skip = @('explorer', 'powershell', 'pwsh', 'applicationframehost', 'textinputhost', 'shellexperiencehost', 'searchhost', 'startmenuexperiencehost', 'systemsettings', 'lockapp')
  $seen = @{}
  foreach ($pid1 in [AppWin]::Pids()) {
    $p = Get-Process -Id $pid1 -ErrorAction SilentlyContinue; if (-not $p) { continue }
    $n = $p.ProcessName.ToLower(); if ($seen[$n] -or $have -contains $n -or $skip -contains $n) { continue }; $seen[$n] = $true
    $path = try { $p.Path } catch { '' }
    $desc = try { (Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo.FileDescription } catch { '' }
    [ordered]@{ proc = $p.ProcessName; name = $(if ($desc) { $desc.Trim() } else { $p.ProcessName }); exe = [string]$path }
  }
}
# 对话里说「打开 X」：只叫到眼前 / 打开，已经在眼前就不最小化
function Invoke-AppToggleByProc([string]$proc) {
  $a = Get-AppList | Where-Object { $_.proc -eq $proc } | Select-Object -First 1; if (-not $a) { return @{ ok = $false; text = '列表里没有这个软件' } }
  $h = Get-AppWindow $a
  if ($h -and [WxWin]::IsWindowVisible($h) -and -not [WxWin]::IsIconic($h) -and -not (Test-OnOtherDesktop $h)) { [void][WxWin]::SetForegroundWindow($h); return @{ ok = $true; text = "$($a.name)已经在你眼前了" } }
  Invoke-AppToggle $a.id
}# 按名字找软件：先找列表里的，再找开着的，再找开始菜单里的快捷方式（对话里说“打开 X / 连接 X”时用）
function Find-AppByName([string]$q) {
  $q = $q.Trim(); if (-not $q) { return $null }
  $hit = Get-AppList | Where-Object { $_.name -like "*$q*" -or $_.proc -eq $q -or $q -like "*$($_.name)*" } | Select-Object -First 1
  if ($hit) { return [ordered]@{ name = $hit.name; proc = $hit.proc; exe = $hit.exe; inList = $true; id = $hit.id } }
  $o = Get-OpenApps | Where-Object { $_.name -like "*$q*" -or $_.proc -like "*$q*" } | Select-Object -First 1
  if ($o) { return [ordered]@{ name = $o.name; proc = $o.proc; exe = $o.exe; inList = $false } }
  # 按窗口标题找（只在本机匹配用户说的名字，不显示、不记录标题）；名字就用用户说的
  $w = Get-Process | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -like "*$q*" -and $_.ProcessName -notin 'powershell', 'pwsh', 'explorer' } | Select-Object -First 1
  if ($w) { $path = try { $w.Path } catch { '' }; return [ordered]@{ name = $q; proc = $w.ProcessName; exe = [string]$path; inList = $false } }
  $sh = New-Object -ComObject WScript.Shell
  foreach ($dir in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs") {
    $l = Get-ChildItem $dir -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -like "*$q*" -and $_.BaseName -notmatch '卸载|uninstall' } | Select-Object -First 1
    if ($l) { $t = $sh.CreateShortcut($l.FullName).TargetPath; if ($t -and $t -like '*.exe') { return [ordered]@{ name = $l.BaseName; proc = [IO.Path]::GetFileNameWithoutExtension($t); exe = $t; inList = $false } } }
  }
  $null
}
# 适配第一步（自动）：看这个软件的窗口能不能用系统无障碍接口读到文字。只数元素，不读内容
function Test-AppReadMode([string]$proc) {
  try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $p = @(Get-Process $proc -ErrorAction SilentlyContinue); if (-not $p.Count) { return 'unknown' }
    $h = [AppWin]::Largest([uint32[]]$p.Id); if ($h -eq [IntPtr]::Zero) { return 'unknown' }
    $root = [Windows.Automation.AutomationElement]::FromHandle($h); $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
    $sw = [Diagnostics.Stopwatch]::StartNew(); $n = 0; $texty = 0; $q = New-Object System.Collections.Queue; $q.Enqueue($root)
    while ($q.Count -and $n -lt 400 -and $sw.ElapsedMilliseconds -lt 1500) {
      $e = $q.Dequeue(); $c = $walker.GetFirstChild($e)
      while ($c) { $n++; $ct = $c.Current.ControlType; if ($ct -eq [Windows.Automation.ControlType]::Text -or $ct -eq [Windows.Automation.ControlType]::Document -or $ct -eq [Windows.Automation.ControlType]::Edit -or $ct -eq [Windows.Automation.ControlType]::ListItem) { $texty++ }; $q.Enqueue($c); $c = $walker.GetNextSibling($c) }
    }
    if ($texty -ge 5) { 'uia' } else { 'ocr' }
  } catch { 'unknown' }
}
function Set-AppField([string]$proc, [string]$key, $value) {
  $cfg = Read-Config; foreach ($a in @($cfg.apps)) { if ($a -and $a.proc -eq $proc) { $a | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force } }; Save-Config $cfg
}
# “连接 X”：加进侧栏列表，并自动做适配第一步（判断读法）；读取本身还没做好时如实说明
function Connect-App([string]$q, [switch]$Open) {
  # 和「添加软件」用同一个清单：列表里的、开着的（所有桌面）、电脑上装了的；有好几个像的，就弹出已筛好的选择器让用户挑
  $c = @(Find-AppCandidates $q)
  if (-not $c.Count) { return "没找到叫「$q」的软件（列表里、开着的、电脑上装了的都没有）。请用户说出软件的准确名字，或在侧栏点「添加软件」自己选。" }
  $exact = @($c | Where-Object { ([string]$_.name).ToLower() -eq $q.Trim().ToLower() })
  if ($c.Count -gt 1 -and $exact.Count -ne 1) { $script:PickerAsk = $q.Trim(); return "像「$q」的软件有 $($c.Count) 个，已在界面弹出选择列表（按名字筛好了），请用户点一个。不要替用户选。" }
  $a = if ($exact.Count -eq 1) { $exact[0] } else { $c[0] }
  if (-not $a.inList -and -not $a.proc) { $pp = Start-PickedApp $a; if (-not $pp) { return "没能打开「$($a.name)」，请用户自己打开后再说一次" }; $a.proc = $pp }   # 商店应用：打开后才知道进程名
  if (-not $a.inList -and $a.state -eq 'installed' -and $Open) { $pp = Start-PickedApp $a; if ($pp) { $a.proc = $pp } }
  if (-not $a.inList) { Add-App $a.proc $a.name $a.exe }
  $msg = @()
  if ($Open) { $r = Invoke-AppToggleByProc $a.proc; $msg += $r.text }
  elseif (-not $a.inList) { $msg += "已把「$($a.name)」加进侧栏软件列表" }
  if ($a.proc -ne 'Weixin') {
    if (-not (Get-Process $a.proc -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 1500 }
    $mode = Test-AppReadMode $a.proc; Set-AppField $a.proc 'readMode' $mode
    $msg += switch ($mode) { 'uia' { '已自动检测：这个软件可以用系统接口直接读到文字（适配起来比较快），读取功能还在做，做好之前不会假装在看' }
                             'ocr' { '已自动检测：这个软件读不到文字结构，需要像微信一样截图识别，读取功能还在做，做好之前不会假装在看' }
                             default { '还没能检测读法（软件没打开或窗口还没出来），打开后再说一次“连接”即可' } }
  }
  ($msg -join '；')
}

function Remove-App([string]$id) { $cfg = Read-Config; $cfg | Add-Member -NotePropertyName apps -NotePropertyValue @(@($cfg.apps) | Where-Object { $_ -and $_.id -ne $id }) -Force; Save-Config $cfg }
. (Join-Path $PSScriptRoot 'lib_软件清单.ps1')   # 添加软件的软件清单
