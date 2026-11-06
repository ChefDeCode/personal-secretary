# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_前台发送.ps1 — 「借用最前面不到 1 秒」发消息（你在确认卡上点了「发送」之后才会用）：
# 等你停手 2 秒 → 屏幕边上提示「马上替你发出」→ 记下剪贴板 → 把微信叫到你现在的桌面最前面（不切桌面）→
# 只用键盘找聊天（Ctrl+F、粘贴名字、回车）→ 本机核对聊天标题完全一样 → 看输入框是不是空的 → 粘贴要发的字 → 本机核对（骨架规则）→ 回车 →
# 核对聊天里出现了这条 → 把前台还给你原来的窗口、微信放回原样（最小化 / 托盘 / 桌面 2）→ 剪贴板还原。
# 你中途一碰键盘或鼠标就立刻停：删掉粘贴进去的字、关掉搜索、还前台、放回微信、还原剪贴板。核对不过绝不按回车。
# 依赖调用方已加载：lib_v2、lib_识别、lib_虚拟桌面、lib_找聊天、lib_打字
Add-Type -AssemblyName System.Windows.Forms
if (-not ('FgSend' -as [type])) { Add-Type @'
using System; using System.Runtime.InteropServices;
public static class FgSend {
  [StructLayout(LayoutKind.Sequential)] struct KI { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct MI { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] struct IN { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KI k; [FieldOffset(8)] public MI m; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, IN[] i, int size);
  static void K(ushort vk, bool up) { var a = new IN[1]; a[0].type = 1; a[0].k.vk = vk; a[0].k.flags = up ? 2u : 0u; SendInput(1, a, Marshal.SizeOf(typeof(IN))); }
  public delegate bool EP(IntPtr h, IntPtr l); [DllImport("user32.dll")] static extern bool EnumWindows(EP p, IntPtr l); [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RC { public int l, t, r, b; } [StructLayout(LayoutKind.Sequential)] struct WP { public int len, flags, show; public PT min, max; public RC normal; }
  [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WP p);
  // 可见的（含最小化的）大窗口；visibleOnly=false 时也返回隐藏的大窗口（没有可见的才用）
  public static IntPtr FindLarge(uint[] pids, bool visibleOnly) { IntPtr best = IntPtr.Zero; long score = 0;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (Array.IndexOf(pids, p) < 0) return true; var c = new System.Text.StringBuilder(128); GetClassName(h, c, 128); if (!c.ToString().EndsWith("QWindowIcon")) return true;
      var w = new WP(); w.len = Marshal.SizeOf(w); GetWindowPlacement(h, ref w); int ww = w.normal.r - w.normal.l, hh = w.normal.b - w.normal.t; if (ww < 600 || hh < 400) return true;
      bool vis = IsWindowVisible(h); if (visibleOnly && !vis) return true; long s = (long)ww * hh + (vis ? (1L << 40) : 0); if (s > score) { score = s; best = h; } return true; }, IntPtr.Zero); return best; }
  // 可见的小 Qt 窗口（宽高都小于 600x400，不是最小化的）：可能是登录 / 扫码窗口
  public static IntPtr[] SmallVisible(uint[] pids) { var list = new System.Collections.Generic.List<IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (Array.IndexOf(pids, p) < 0 || !IsWindowVisible(h) || IsIconic(h)) return true; var c = new System.Text.StringBuilder(128); GetClassName(h, c, 128); if (!c.ToString().EndsWith("QWindowIcon")) return true;
      var w = new WP(); w.len = Marshal.SizeOf(w); GetWindowPlacement(h, ref w); int ww = w.normal.r - w.normal.l, hh = w.normal.b - w.normal.t; if (ww >= 220 && ww < 600 && hh >= 300 && hh < 700) list.Add(h); return true; }, IntPtr.Zero); return list.ToArray(); }
  [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber(); public static uint ClipSeq() { return GetClipboardSequenceNumber(); }
  public static void Tap(int vk) { K((ushort)vk, false); K((ushort)vk, true); }
  public static void CtrlAlt(int vk) { K(0x11, false); K(0x12, false); K((ushort)vk, false); K((ushort)vk, true); K(0x12, true); K(0x11, true); }
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int x, y; } [DllImport("user32.dll")] static extern bool GetCursorPos(out PT p); [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  static void M(uint f) { var a = new IN[1]; a[0].type = 0; a[0].m.flags = f; SendInput(1, a, Marshal.SizeOf(typeof(IN))); }
  // 真点一下屏幕上的某一点，点完马上把鼠标放回原处（前后不到 50 毫秒）
  public static void ClickAt(int x, int y) { PT p; GetCursorPos(out p); SetCursorPos(x, y); M(2); M(4); System.Threading.Thread.Sleep(15); SetCursorPos(p.x, p.y); }
  public static void Ctrl(int vk) { K(0x11, false); K((ushort)vk, false); K((ushort)vk, true); K(0x11, true); }
  [StructLayout(LayoutKind.Sequential)] struct LI { public uint cb, t; } [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LI l);
  public static uint LastInput() { var l = new LI { cb = 8 }; GetLastInputInfo(ref l); return l.t; }
  public static uint IdleMs() { return (uint)Environment.TickCount - LastInput(); }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool on);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", EntryPoint = "PostMessageW")] public static extern bool Post(IntPtr h, uint m, IntPtr w, IntPtr l);
  // 设前台：先挂到当前前台窗口的输入线程上再设（Windows 允许「刚被用户点过的程序」这样做）；返回是否成功
  public static bool Front(IntPtr h) {
    IntPtr fg = GetForegroundWindow(); uint a = GetWindowThreadProcessId(fg, IntPtr.Zero), b = GetCurrentThreadId(); bool att = a != b && AttachThreadInput(b, a, true);
    BringWindowToTop(h); bool ok = SetForegroundWindow(h); if (att) AttachThreadInput(b, a, false);
    return ok || GetForegroundWindow() == h; }
}
'@ }

# 剪贴板：记下（文字 / 图片 / 文件列表），用完原样放回；别的格式放不回去时如实说
function Save-Clip {
  $s = @{ kind = 'empty'; partial = $false }
  try { $d = [Windows.Forms.Clipboard]::GetDataObject()
    if ($d) { $fmts = @($d.GetFormats())
      if ([Windows.Forms.Clipboard]::ContainsFileDropList()) { $s.kind = 'files'; $s.files = [Windows.Forms.Clipboard]::GetFileDropList() }
      elseif ([Windows.Forms.Clipboard]::ContainsImage()) { $s.kind = 'image'; $s.image = [Windows.Forms.Clipboard]::GetImage() }
      elseif ([Windows.Forms.Clipboard]::ContainsText()) { $s.kind = 'text'; $s.text = [Windows.Forms.Clipboard]::GetText() }
      elseif ($fmts.Count) { $s.kind = 'other'; $s.partial = $true } } } catch { $s.partial = $true }
  $s }
function Restore-Clip($s) {
  try { switch ($s.kind) { 'text' { [Windows.Forms.Clipboard]::SetText($s.text) } 'image' { [Windows.Forms.Clipboard]::SetImage($s.image) } 'files' { [Windows.Forms.Clipboard]::SetFileDropList($s.files) } default { [Windows.Forms.Clipboard]::Clear() } }; -not $s.partial } catch { $false } }
function Get-ClipText { for ($i = 0; $i -lt 10; $i++) { try { return [Windows.Forms.Clipboard]::GetText() } catch { Start-Sleep -Milliseconds 30 } }; $null }
function Set-ClipExact([string]$t, [int]$maxMs = 1500) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $maxMs) { try { [Windows.Forms.Clipboard]::SetDataObject($t, $true, 2, 40); if ([Windows.Forms.Clipboard]::GetText() -ceq $t) { return $true } } catch {}; Start-Sleep -Milliseconds 30 }; $false }   # 剪贴板被别的程序占着时最多等 1.5 秒（.NET 自己每次会重试 1 秒，以前叠起来能等十几秒）   # 设好以后读回来核对，一个字不差才算
function Set-ClipText([string]$t) { for ($i = 0; $i -lt 5; $i++) { try { [Windows.Forms.Clipboard]::SetText($t); return $true } catch { Start-Sleep -Milliseconds 50 } }; $false }

# 只认「真的」键盘鼠标：低层钩子看 Windows 给每个输入打的标记，程序模拟出来的（我们自己按的键、别的软件模拟的）不算你在动。只在发送这几秒开着
if (-not ('RealInput' -as [type])) { Add-Type @"
using System; using System.Runtime.InteropServices; using System.Threading;
public static class RealInput {
  delegate IntPtr HookProc(int n, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc p, IntPtr h, uint t);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
  [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint a, uint b);
  [DllImport("user32.dll")] static extern bool PostThreadMessage(uint t, uint m, IntPtr w, IntPtr l);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string n);
  [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint m; public IntPtr w, l; public uint t; public int x, y; }
  static HookProc kp, mp; static IntPtr kh, mh; static uint tid; static Thread th;
  public static volatile int LastReal; public static volatile bool On; public static volatile int Injected;
  static IntPtr K(int n, IntPtr w, IntPtr l) { if (n >= 0) { int fl = Marshal.ReadInt32(l, 8); if ((fl & 0x10) == 0) LastReal = Environment.TickCount; else Injected++; } return CallNextHookEx(IntPtr.Zero, n, w, l); }
  static IntPtr M(int n, IntPtr w, IntPtr l) { if (n >= 0) { int fl = Marshal.ReadInt32(l, 12); if ((fl & 0x1) == 0) LastReal = Environment.TickCount; else Injected++; } return CallNextHookEx(IntPtr.Zero, n, w, l); }
  public static bool Start(int idleMs) {
    if (On) return true; LastReal = Environment.TickCount - idleMs; var ready = new ManualResetEvent(false);
    th = new Thread(() => { tid = GetCurrentThreadId(); kp = K; mp = M; IntPtr mod = GetModuleHandle(null); kh = SetWindowsHookEx(13, kp, mod, 0); mh = SetWindowsHookEx(14, mp, mod, 0);
      On = kh != IntPtr.Zero && mh != IntPtr.Zero; ready.Set(); if (!On) { if (kh != IntPtr.Zero) UnhookWindowsHookEx(kh); if (mh != IntPtr.Zero) UnhookWindowsHookEx(mh); return; }
      MSG m; while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { } UnhookWindowsHookEx(kh); UnhookWindowsHookEx(mh); On = false; });
    th.IsBackground = true; th.Start(); ready.WaitOne(2000); return On; }
  public static void Stop() { if (th != null && On) PostThreadMessage(tid, 0x0012, IntPtr.Zero, IntPtr.Zero); }
  public static int IdleMs() { return Environment.TickCount - LastReal; }
}
"@ }function Get-FgLayout([IntPtr]$h) {
  $rr = [WinTools]::Rect($h); $w = $rr.R - $rr.L; $ht = $rr.B - $rr.T; $full = [Rec]::Window($h, $w, $ht); $lay = [Rec]::Layout($full); $dpi = [WinTools]::Dpi($h) / 96.0
  $cl = [int]($w * $lay[0]); $ct = [int]($ht * $lay[1]); $cb = [int]($ht * $lay[2])
  if ($lay[2] -gt 0.9 -or $lay[2] -lt 0.5) { $cb = [int]($ht * 0.78) }   # 真微信（深色）上算出来的输入区上沿常常贴到窗口最底下（0.99），那样点不到输入框：按微信的常见布局，输入区占下面约 22%
  @{ full = $full; title = (New-Object Drawing.Rectangle $cl, ([int][Math]::Max(0, $ct - 56 * $dpi)), ([int](($w - $cl) * 0.6)), ([int][Math]::Max(1, [Math]::Min($ct, 56 * $dpi))))
     input = (New-Object Drawing.Rectangle $cl, ([int]($cb + 4)), ([int](($w - $cl) * 0.85)), ([int](($ht - $cb) * 0.55)))
     wide = (New-Object Drawing.Rectangle $cl, ([int]($ht * 0.55)), ([int]($w - $cl - 2)), ([int]($ht * 0.45 - 2))); cbf = [Math]::Round($lay[2], 3) } }
function Get-Thumb([IntPtr]$h) { $rr = [WinTools]::Rect($h); $full = [Rec]::Window($h, $rr.R - $rr.L, $rr.B - $rr.T); $t = New-Object Drawing.Bitmap 200, 120; $g = [Drawing.Graphics]::FromImage($t); $g.DrawImage($full, 0, 0, 200, 120); $g.Dispose(); $full.Dispose(); $t }
# 快速核对标题：只认标题那一条（不对再换几种方式认，认出完全一样才算）
function Test-TitleFast($L, [string]$conv, [scriptblock]$same) {
  $tb = Crop $L.full $L.title; $lines = @(Get-Lines (Invoke-Ocr $tb)); $first = $lines | Sort-Object y | Select-Object -First 1
  $ok = $first -and (& $same (([string]$first.文本) -replace '\s*[（(]\d+[)）]\s*$', '') $conv)
  if (-not $ok) { $ok = [bool](@(Read-Zoomed $tb (New-Object Drawing.Rectangle 0, 0, $tb.Width, $tb.Height)) | Where-Object { & $same ($_ -replace '\s*[（(]\d+[)）]\s*$', '') $conv }) }
  $tb.Dispose(); $ok }
# 输入框那块有没有笔画（只看像素，很快）
function Test-BoxBlank([Drawing.Bitmap]$ib) { $n = 0; $s = 0.0; $s2 = 0.0; for ($y = 2; $y -lt $ib.Height - 2; $y += 3) { for ($x = 2; $x -lt $ib.Width - 2; $x += 3) { $p = $ib.GetPixel($x, $y); $l = ($p.R + $p.G + $p.B) / 3.0; $n++; $s += $l; $s2 += $l * $l } }; if (-not $n) { return $true }; $m = $s / $n; ($s2 / $n - $m * $m) -lt 60 }
# $o = @{ proc; findMain = { param($ids) 主窗口 }; summon = { param($h) 托盘里的窗口叫出来 }; trayHide = { param($h) 放回托盘 }; pill = 提示文件; same = 名字比较 }
# 返回 @{ ok = $true / $false / $null（可能已发出）; msg; steps; visible_ms; fg_back; clip_ok; draft }
function Test-NewSentText($before, $after, [string]$text, [string]$conv, [scriptblock]$same) {
  if (-not $before -or -not $after -or -not (& $same ([string]$after.会话) $conv)) { return $false }
  $bm = @($before.消息 | Where-Object { $_.发送方 -eq '我' }); $am = @($after.消息 | Where-Object { $_.发送方 -eq '我' })
  if (-not $am.Count -or [string]$am[-1].文本 -cne $text) { return $false }
  $last = if ($bm.Count) { [string]$bm[-1].文本 } else { '' }
  [bool]($last -cne $text -or $am.Count -gt $bm.Count)
}
function Invoke-FgSend($o, [string]$conv, [string]$text, [switch]$Replace) {
  $cleanup = $null; $realOn = $false
  try {
  $steps = New-Object System.Collections.ArrayList; function S([string]$t, [bool]$ok = $true) { [void]$steps.Add(@{ ok = $ok; text = $t }) }
  $r = @{ ok = $false; msg = ''; steps = $steps; visible_ms = 0; fg_back = $null; clip_ok = $null; draft = '' }
  # 1) 等你停手 2 秒（最多等 60 秒）
  # 等你：默认停手 2 秒（最多等 1 分钟）；设成「等我离开电脑 1 分钟」时最多等 2 小时，期间你在卡片上点「立即发」就不再等
  $needIdle = $(if ($o.idleMs) { [int]$o.idleMs } else { 2000 }); $maxWait = $(if ($o.maxWaitSec) { [int]$o.maxWaitSec } else { 60 }); $nowNow = $false
  $sw = [Diagnostics.Stopwatch]::StartNew(); $realOn = $false; try { $realOn = [RealInput]::Start([int][FgSend]::IdleMs()) } catch {}   # 只认真的键盘鼠标（别的程序模拟的不算）
  $idleNow = { if ($realOn) { [RealInput]::IdleMs() } else { [FgSend]::IdleMs() } }
  while ((& $idleNow) -lt $needIdle) {
    if ($o.nowFlag -and (Test-Path $o.nowFlag)) { Remove-Item $o.nowFlag -ErrorAction SilentlyContinue; $nowNow = $true; break }   # 你点了「立即发」
    if ($sw.Elapsed.TotalSeconds -gt $maxWait) { S $(if ($needIdle -ge 60000) { '等你离开电脑再发：等了 2 小时你一直在用电脑，没有发送' } else { '等你停手再发：这 1 分钟里你一直在用电脑，没有发送' }) $false; $r.msg = '等你停手'; return $r }
    Start-Sleep -Milliseconds 200 }
  if ($nowNow) { $sw2 = [Diagnostics.Stopwatch]::StartNew(); while ([FgSend]::IdleMs() -lt 1000 -and $sw2.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 } }   # 点完「立即发」等你的手离开鼠标 1 秒
  if ($o.border) { try { Set-Lit $o.border 30 } catch {} }   # 微信外的边框：只在借用前台这段亮
  if ($o.pill) { try { [IO.File]::WriteAllText($o.pill, (@{ ts = (Get-Date).ToString('o'); text = '马上替你发出' } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false)) } catch {} }
  Start-Sleep -Milliseconds 300
  if (-not $nowNow -and (& $idleNow) -lt 300) { S '你刚好又开始用电脑了，没有发送（等你停手再点重试）' $false; $r.msg = '用户在用'; return $r }
  # 2) 记下现场
  $prev = [FgSend]::GetForegroundWindow(); $clip = Save-Clip
  $p = @(Get-Process $o.proc -ErrorAction SilentlyContinue); if (-not $p.Count) { S '微信没有在运行' $false; $r.msg = '微信不可用'; return $r }
  $h = & $o.findMain ([uint32[]]$p.Id); $trayed = ($h -eq [IntPtr]::Zero)   # 没有可见的主窗口：在托盘里
  if ($prev -eq $h) { S '你正在用微信，没有替你操作' $false; $r.msg = '用户在用微信'; return $r }
  $onOther = { param($w) try { [Rec]::Cloaked($w) -ne 0 } catch { $false } }   # 窗口被系统藏在别的虚拟桌面上
  $was = if ($trayed -or -not [FgSend]::IsWindowVisible($h)) { 'tray' } elseif ([FgSend]::IsIconic($h)) { 'min' } elseif (& $onOther $h) { 'other' } else { 'here' }
  if ($was -eq 'other') { S '微信在别的桌面上，没有发送（不替你切桌面）；把微信拖回这个桌面再点「重试」' $false; $r.msg = '微信在别的桌面'; $r.clip_ok = $true; return $r }
  $small0 = @([FgSend]::SmallVisible([uint32[]]$p.Id))
  $vis = [Diagnostics.Stopwatch]::StartNew(); $pasted = $false; $searching = $false; $script:FgEarly = $false; $script:FgEarlyOk = $false; $r.front_ms = 0
  $our = { $script:FgOurTick = [FgSend]::LastInput(); $script:FgOurReal = [RealInput]::LastReal }
  $userMoved = { if ($realOn) { [RealInput]::LastReal -ne $script:FgOurReal } else { [FgSend]::LastInput() -ne $script:FgOurTick } }   # 钩子开着：只有你真的动了才算
  $capMs = $(if ($o.capMs) { [int]$o.capMs } else { 5000 }); $script:FgFrontAt = -1   # 微信在你面前最多停 5 秒（到最后按回车为止），超过就放弃、全部还原
  $stop = { if (& $userMoved) { $r.userInterrupted = $true; S '你碰了键盘或鼠标，马上停了，没有发送' $false; return '用户输入' }
    if ($script:FgFrontAt -ge 0 -and ($vis.ElapsedMilliseconds - $script:FgFrontAt) -gt $capMs) { S $(if ($pasted) { '这次没发成（微信没及时响应），粘进去的字已经删掉，没有发送' } else { '这次没发成（微信没及时响应），没打字也没发' }) $false; $r.capped = $true; return '微信没及时响应' }
    $null }
  # 收尾：不管成败都走这里（删掉粘进去的字、关掉搜索、还前台、放回微信、还原剪贴板）
  $cleanup = {
    if ($realOn) { try { [RealInput]::Stop() } catch {} }
    if ($o.border) { try { Set-Lit $o.border 1 } catch {} }
    if ($pasted -and $r.ok -ne $true -and $null -ne $r.ok -and -not $r.userInterrupted -and [FgSend]::GetForegroundWindow() -eq $h) { [FgSend]::Ctrl(0x41); [FgSend]::Tap(0x2E); Start-Sleep -Milliseconds 150; S '粘进输入框的字已经删掉了' }
    if ($searching -and -not $r.userInterrupted -and [FgSend]::GetForegroundWindow() -eq $h) { [FgSend]::Tap(0x1B) }
    $fb = $false; if ($r.userInterrupted) { $fb = $true } elseif ($script:FgEarly) { $fb = $script:FgEarlyOk -or ([FgSend]::GetForegroundWindow() -eq $prev) } elseif ($prev -ne [IntPtr]::Zero) { $fb = [FgSend]::Front($prev); Start-Sleep -Milliseconds 80; $fb = $fb -and ([FgSend]::GetForegroundWindow() -eq $prev); $r.front_ms = $vis.ElapsedMilliseconds }

    switch ($was) { 'tray' { & $o.trayHide $h } 'min' { [void][FgSend]::ShowWindow($h, 7) } }   # 原来在托盘里 / 最小化的，放回去
    $vis.Stop(); $r.visible_ms = $vis.ElapsedMilliseconds; $r.fg_back = $fb; $r.clip_ok = Restore-Clip $clip
    S ("微信在最前面停了 {0:N1} 秒" -f ($r.front_ms / 1000.0)) $true
    if (-not $fb) { S '没能把前台还给你原来的窗口（Windows 不允许），点一下你要用的窗口就好' $false }
    if (-not $r.clip_ok) { S $(if ($clip.partial) { '你剪贴板里原来的东西是特殊格式，没能原样放回去' } else { '没能把剪贴板原样放回去' }) $false }
  }
  $finish = { param($ok, [string]$msg) $r.ok = $ok; $r.msg = $msg; $r }
  # 3) 叫到你现在的桌面最前面（不切桌面）
  if ($was -eq 'tray') { & $o.summon $h; $h2 = [IntPtr]::Zero
    for ($i = 0; $i -lt 12 -and $h2 -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 60; $p = @(Get-Process $o.proc -ErrorAction SilentlyContinue); $h2 = & $o.findMain ([uint32[]]$p.Id) }
    if ($h2 -eq [IntPtr]::Zero) {   # 没出来主窗口：要是冒出了登录 / 扫码这类小窗口，马上藏回去
      $new = @([FgSend]::SmallVisible([uint32[]]$p.Id) | Where-Object { $small0 -notcontains $_ }); foreach ($w in $new) { [void][FgSend]::ShowWindow($w, 0) }
      S $(if ($new.Count) { '微信打开的是登录窗口，没有发送（已经把它藏回去了）' } else { '微信没出来：可能你改过微信的「显示微信」快捷键（默认是 Ctrl+Alt+W），没有发送' }) $false; $r.ok = $false; $r.msg = '微信叫不出来'; $r.clip_ok = Restore-Clip $clip; return $r }
    $h = $h2 }
  if ([FgSend]::IsIconic($h)) { [void][FgSend]::ShowWindow($h, 9) }

  $front = [FgSend]::Front($h); $script:FgFrontAt = $vis.ElapsedMilliseconds; Start-Sleep -Milliseconds 150; & $our; $r.t = [ordered]@{}; $r.t.restore = $vis.ElapsedMilliseconds; if ($o.afterFront) { & $o.afterFront }   # 测试用的钩子（真发送不设）
  $r.t.front_ok = $vis.ElapsedMilliseconds   # 5 秒从叫到前面那一刻算起
  if (-not $front -or [FgSend]::GetForegroundWindow() -ne $h) { S '没能把微信叫到最前面，没有发送' $false; return (& $finish $false '微信叫不出来') }
  if ((Get-Command Test-SessionLocked -ErrorAction SilentlyContinue) -and (Test-SessionLocked)) { S '电脑锁着，没有按任何键' $false; return (& $finish $false '电脑锁着') }
  # 4) 只用键盘找聊天：Ctrl+F → 粘贴名字 → 回车（打开第一个结果）→ 本机核对标题完全一样
  if ($why = & $stop) { return (& $finish $false $why) }   # 每次按键之前先看你有没有动
  if (-not (Set-ClipExact $conv)) { S '剪贴板被别的程序占着，没有发送' $false; return (& $finish $false '剪贴板不可用') }; $r.t.clip = $vis.ElapsedMilliseconds
  if ($why = & $stop) { return (& $finish $false $why) }   # 剪贴板拿得太慢也算在 5 秒里
  $th0 = Get-Thumb $h; $r.t.thumb0 = $vis.ElapsedMilliseconds; $r.fg_at_keys = ([FgSend]::GetForegroundWindow() -eq $h); [FgSend]::Ctrl(0x46); $searching = $true; Start-Sleep -Milliseconds 100; [FgSend]::Ctrl(0x56); & $our; Start-Sleep -Milliseconds 350; $th1 = Get-Thumb $h; $r.t.keys = $vis.ElapsedMilliseconds; $r.keys_effect = [Math]::Round((Get-PixDiff $th0 $th1), 4); $th0.Dispose(); $th1.Dispose()
  if ($r.keys_effect -lt 0.0005) { S '微信没有反应（按 Ctrl+F 搜索框没出来），没有发送' $false; return (& $finish $false '微信没反应') }   # 键没进微信：别再往下按回车   # 按 Ctrl+F、粘名字以后微信窗口变了多少（0 = 完全没反应）
  if ($why = & $stop) { return (& $finish $false $why) }
  [FgSend]::Tap(0x0D); $searching = $false; & $our; Start-Sleep -Milliseconds 200; $r.t.search = $vis.ElapsedMilliseconds
  $L = Get-FgLayout $h; $tok = Test-TitleFast $L $conv $o.same; if (-not $tok) { $L.full.Dispose(); Start-Sleep -Milliseconds 300; $L = Get-FgLayout $h; $tok = Test-TitleFast $L $conv $o.same }
  if (-not $tok) { $L.full.Dispose(); [FgSend]::Tap(0x1B); S "搜到的聊天名字对不上（要的是「$conv」），没有粘贴，也没有发送" $false; return (& $finish $false '会话名不符') }
  S "核对过会话名：$conv"; $r.t.title = $vis.ElapsedMilliseconds
  if ($why = & $stop) { return (& $finish $false $why) }
  # 5) 输入框：只粘一次。核对两条路：复制回来逐字比（等剪贴板真的变了再读，最多 0.4 秒）；复制不出来就用截图认字的骨架规则。
  #    认对了才按发送；字明明进去了却确认不了，就把字留在框里、不按发送，让你自己看一眼按回车；只有确定是错的才删。
  $inRect = $L.input; $wide = $L.wide; $r.cbf = $L.cbf; $L.full.Dispose()
  $icx = [int]($inRect.X + $inRect.Width * 0.5); $icy = [int]($inRect.Y + $inRect.Height * 0.4)
  # 读输入框：剪贴板放记号 → Ctrl+A、Ctrl+C → 剪贴板序号变了才读（微信可能晚一点才放进去）；没变 = 复制不出来（框是空的，或者微信不让复制）
  $readBox = { $mark = '§秘书记号' + [guid]::NewGuid().ToString('N'); if (-not (Set-ClipExact $mark)) { return @{ state = 'busy' } }
    $seq = [FgSend]::ClipSeq(); [FgSend]::Ctrl(0x41); [FgSend]::Ctrl(0x43); & $our
    $chg = $false; for ($i = 0; $i -lt 16 -and -not $chg; $i++) { Start-Sleep -Milliseconds 25; $chg = [FgSend]::ClipSeq() -ne $seq }
    [FgSend]::Ctrl(0x23); & $our
    if (-not $chg) { return @{ state = 'unknown' } }
    Start-Sleep -Milliseconds 20; $c = Get-ClipText; if ($null -eq $c) { return @{ state = 'busy' } }; if ($c -ceq $mark -or $c -eq '') { @{ state = 'empty' } } else { @{ state = 'text'; text = $c } } }
  $diag = @(); $focusTries = $(if ($o.noMouse) { @('posted-click', 'tab') } else { @('posted-click', 'tab', 'real-click') });   # 「永远不借用鼠标」：不用真点击
  $fi = 0; $done = $false
  while (-not $done -and $fi -lt $focusTries.Count) {
    $m = $focusTries[$fi]; $fi++
    if ($why = & $stop) { return (& $finish $false $why) }
    if ($m -eq 'posted-click') { [Rec]::Click($h, $icx, $icy) } elseif ($m -eq 'tab') { [FgSend]::Tap(0x09) } else { $wr = [WinTools]::Rect($h); [FgSend]::ClickAt($wr.L + $icx, $wr.T + $icy); $r.clicked = $true; S '这次为了点输入框，鼠标被借用了一下（点完马上放回了原处）' }
    Start-Sleep -Milliseconds 120; & $our
    # 粘之前：输入框是不是空的
    $preI = Get-InputShot $h $wide; $rb = & $readBox
    if ($rb.state -eq 'busy') { $preI.Dispose(); S '剪贴板被别的程序占着，没有发送' $false; return (& $finish $false '剪贴板不可用') }
    if ($rb.state -eq 'text' -and (($rb.text -replace '\s', '') -ceq ($conv -replace '\s', ''))) { $diag += "${m}:focus-in-search"; $preI.Dispose(); continue }   # 复制到的就是聊天名字：焦点还在搜索框
    if ($rb.state -eq 'text') {   # 复制到了别的字：输入框里本来就有字（你的草稿）
      $draftText = $rb.text
      if (-not $Replace) { $preI.Dispose(); $r.draft = $draftText; $r.diag = ($diag + "${m}:draft") -join ' '; S '微信输入框里已经有字，没动它' $false; return (& $finish $false '输入框有草稿') }
      [FgSend]::Ctrl(0x41); [FgSend]::Tap(0x2E); & $our; Start-Sleep -Milliseconds 150; $preI.Dispose(); $preI = Get-InputShot $h $wide
      if ((& $readBox).state -eq 'text') { $preI.Dispose(); S '按你说的去清空输入框，但没能清干净，没有发送；框里原来的字可能已经删掉了一部分' $false; return (& $finish $false '清空输入框失败') }
      S '按你说的，已经把输入框里原来的字删掉了' }
    # 只粘一次
    if ($why = & $stop) { $preI.Dispose(); return (& $finish $false $why) }
    if (-not (Set-ClipExact $text)) { $preI.Dispose(); S '剪贴板被别的程序占着，没有发送' $false; return (& $finish $false '剪贴板不可用') }
    [FgSend]::Ctrl(0x56); & $our; Start-Sleep -Milliseconds 200
    $ibw = Get-InputShot $h $wide; $px = (Get-PixDiff $preI $ibw) -gt 0.0005; $preI.Dispose(); $ibw.Dispose(); $ib = Get-InputShot $h $inRect
    $rb2 = & $readBox
    $cat = switch ($rb2.state) { 'text' { if ($rb2.text -ceq $text) { 'exact' } else { "diff(len $($rb2.text.Length)/$($text.Length))" } } default { $rb2.state } }
    if ($rb2.state -eq 'unknown' -or $rb2.state -eq 'empty') { $cands = @(Get-TypeNorm ((@(Get-Lines (Invoke-Ocr $ib)) | Where-Object { $_.文本 -notmatch '^\s*(发送|Send)\s*$' } | ForEach-Object 文本) -join '')); $ocrOk = Test-TypedMatch $cands $text $px; if (-not $ocrOk -and $px) { $cands = @(Read-InputCandidates $ib); $ocrOk = Test-TypedMatch $cands $text $px } } else { $ocrOk = $false }
    $ib.Dispose(); $diag += "${m}:copy=$cat" + $(if ($px) { '+box-changed' } else { '+box-same' }) + $(if ($rb2.state -ne 'text') { "+ocr=$(if ($ocrOk) { 'match' } else { 'no' })" })
    if ($px -and ($cat -eq 'exact' -or $ocrOk)) { $r.focus = $m; $r.verify = $(if ($cat -eq 'exact') { 'copy' } else { 'ocr' }); $pasted = $true; $done = $true; break }   # 输入框变了，而且（复制回来一字不差 或 认字对上）：放对了
    if ($px -and $rb2.state -eq 'text') { [FgSend]::Ctrl(0x41); [FgSend]::Tap(0x2E); & $our; $r.diag = $diag -join ' '; S '粘进去的字和要发的不一致，已删掉，没有发送' $false; return (& $finish $false '输入核对失败') }   # 确定是错的才删
    if ($px) { $r.diag = $diag -join ' '; S '字已经放进输入框，但我没能确认无误，所以没按发送；你看一眼没问题可以自己按回车' $false; return (& $finish $false '未能确认') }   # 进去了但确认不了：留着，不删、不发
    if ($rb2.state -eq 'text') { [FgSend]::Ctrl(0x41); [FgSend]::Tap(0x2E); & $our; Start-Sleep -Milliseconds 80; $diag += "${m}:landed-elsewhere-removed" }   # 输入框没变、却复制到了字：粘到别处了，在那里删掉
  }
  $r.diag = $diag -join ' '
  if (-not $done) { S $(if ($o.noMouse) { '不动鼠标没能把字放进微信的输入框（你设置了「永远不借用鼠标」），没有发送，微信里什么都没留下' } else { '没能把字放进微信的输入框，没有发送' }) $false; return (& $finish $false '输入核对失败') }
  S $(if ($r.verify -eq 'copy') { '输入框里的字复制回来逐字对过，和要发的一模一样' } else { '输入框里的字（按截图认的）和要发的对上了' }); $r.t.check = $vis.ElapsedMilliseconds
  # 6) Write intent durably BEFORE the irreversible key; verify a new outgoing bubble.
  if ($why = & $stop) { return (& $finish $false $why) }
  $beforeSend = $null
  try { $rr = [WinTools]::Rect($h); $bb = [Rec]::Window($h, $rr.R-$rr.L, $rr.B-$rr.T); try { $beforeSend = Read-WeChat $h $bb } finally { $bb.Dispose() } } catch {}
  if ($why = & $stop) { return (& $finish $false $why) }
  if ($o.actionId) { Set-ActionPhase $o.actionId 'send_intent' }
  [FgSend]::Tap(0x0D); $r.ok = $null; $pasted = $false
  if ($o.actionId) { Set-ActionPhase $o.actionId 'send_pressed' }
  & $our; Start-Sleep -Milliseconds 250
  $afterSend = $null
  try { $rr = [WinTools]::Rect($h); $bb = [Rec]::Window($h, $rr.R-$rr.L, $rr.B-$rr.T); try { $afterSend = Read-WeChat $h $bb } finally { $bb.Dispose() } } catch {}
  $emptyAfter = Test-NewSentText $beforeSend $afterSend $text $conv $o.same
  $script:FgEarly = $true; if ($prev -ne [IntPtr]::Zero) { $script:FgEarlyOk = [FgSend]::Front($prev) -and ([FgSend]::GetForegroundWindow() -eq $prev) }; $r.front_ms = $vis.ElapsedMilliseconds; $r.t.enter_giveback = $r.front_ms
  if ($emptyAfter) { if ($o.actionId) { Set-ActionPhase $o.actionId 'verified' }; S '已核对：聊天里出现了这条新消息'; return (& $finish $true '已发出') }
  S '已按发送，但没能核对到新消息，请去微信看一眼；不会自动重发' $false
  & $finish $null '结果不明'
  } finally {
    if ($cleanup) { & $cleanup | Out-Null }
    elseif ($realOn) { try { [RealInput]::Stop() } catch {} }
  }
}
