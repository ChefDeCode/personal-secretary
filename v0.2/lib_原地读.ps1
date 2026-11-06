# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_原地读.ps1 — 读最小化 / 关在托盘里（隐藏）的软件窗口：全透明 + 点不着（鼠标穿过去）、不激活地放出来，读完马上恢复原样（最小化的回到最小化，隐藏的回到隐藏）；
# 放出来期间锁住「抢前台」，还有一个小线程每 30 毫秒看一次你有没有碰鼠标键盘，一碰就立刻放回去、恢复原来的样子（你看不到、也点不进这个透明的窗口）
# 所有读取来源（微信原地读、适配过的软件、商店插件、Outlook、Edge）都用这一个包装：Invoke-GhostRead
if (-not ('Ghost7' -as [type])) { Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Threading; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Drawing;
public static class Ghost7 {
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte a, uint f);
  [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte a, out uint f);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool LockSetForegroundWindow(uint u);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  delegate bool EnumProc(IntPtr h, IntPtr l); [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct WP { public int len, flags, show; public int mx, my, xx, xy; public int l, t, r, b; } [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WP p); [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] struct LI { public uint cb, t; } [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LI l);
  static uint LastIn() { var l = new LI { cb = 8 }; GetLastInputInfo(ref l); return l.t; }
  public static uint IdleMs() { return (uint)Environment.TickCount - LastIn(); }
  public static IntPtr Fg() { return GetForegroundWindow(); }
  public static bool Back(IntPtr h) { return SetForegroundWindow(h); }
  public static uint PidOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static volatile bool LockOk; public static int ShownAt;
  static readonly object lk = new object(); static IntPtr hw; static int ex0; static bool hadLayer, wasHidden, wasIconic; static uint k0, f0; static byte a0; static Thread th;
  public static volatile bool Active; public static volatile bool UserTouched;
  public static bool NeedsGhost(IntPtr h) { return h != IntPtr.Zero && (IsIconic(h) || !IsWindowVisible(h)); }
  // 关在托盘里的软件：主窗口还在，只是隐藏了 → 找这个进程最大的隐藏顶层窗口（太小的、工具窗口不算）
  public static IntPtr HiddenMain(uint[] pids, int minW, int minH) {
    IntPtr best = IntPtr.Zero; long area = 0; var set = new HashSet<uint>(pids);
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (!set.Contains(p) || IsWindowVisible(h)) return true;
      if ((GetWindowLong(h, -20) & 0x80) != 0) return true; RECT r; GetWindowRect(h, out r); int w = r.R - r.L, ht = r.B - r.T;
      if (IsIconic(h)) { WP wp = new WP(); wp.len = 44; if (GetWindowPlacement(h, ref wp)) { w = wp.r - wp.l; ht = wp.b - wp.t; } }
      if (w >= minW && ht >= minH && (long)w * ht > area) { area = (long)w * ht; best = h; } return true; }, IntPtr.Zero);
    return best; }
  static readonly Semaphore one = new Semaphore(1, 1, "Local\\SecretaryGhostRead");   // 秘书和值守是两个进程：同一时间只放出一个窗口
  public static bool Show(IntPtr h) { lock (lk) { if (Active) return false; if (!one.WaitOne(0)) return false; Gen++; hw = h; ex0 = GetWindowLong(h, -20); hadLayer = (ex0 & 0x80000) != 0; wasHidden = !IsWindowVisible(h); wasIconic = IsIconic(h); if (hadLayer) GetLayeredWindowAttributes(h, out k0, out a0, out f0);
      LockOk = LockSetForegroundWindow(1); ShownAt = Environment.TickCount;   // 放出来期间谁都不能抢前台（记下锁住没有、什么时候放出来的）
      SetWindowLong(h, -20, ex0 | 0x80000 | 0x20); SetLayeredWindowAttributes(h, 0, 0, 2);   // 先全透明、点不着，再放出来
      if (wasHidden && wasIconic) { ShowWindow(h, 8); ShowWindow(h, 4); } else { ShowWindow(h, wasHidden ? 8 : 4); } Active = true; UserTouched = false; }   // 托盘里又是最小化的：先不激活地显示（还是最小化），再不激活地还原   // 8 = SW_SHOWNA（隐藏的），4 = SW_SHOWNOACTIVATE（最小化的）：都不激活
    uint base0 = LastIn(); th = new Thread(() => { while (Active) { if (LastIn() != base0) { UserTouched = true; Hide(); break; } Thread.Sleep(30); } }); th.IsBackground = true; th.Start(); return true; }
  public static void Hide() { lock (lk) { if (!Active) return; if (wasHidden && wasIconic) { ShowWindow(hw, 7); ShowWindow(hw, 0); } else { ShowWindow(hw, wasHidden ? 0 : 7); } if (hadLayer) SetLayeredWindowAttributes(hw, k0, a0, f0); SetWindowLong(hw, -20, ex0); LockSetForegroundWindow(2); Active = false; one.Release(); } }   // 隐藏的放回隐藏，最小化的放回最小化（7 = 不激活地最小化）
  public static bool WasHidden { get { return wasHidden; } }
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  public static volatile int LastCaptureMs;
  // 在另一个线程里截一张（PrintWindow 2 = 连同硬件加速的内容），最多等 ms 毫秒；没截完就返回 null（那个线程截完的图会自己扔掉）
  public static Bitmap CaptureWithin(IntPtr h, int w, int ht, int ms) {
    if (w < 1 || ht < 1) return null; Bitmap bmp = null; bool done = false; int t0 = Environment.TickCount;
    var th2 = new Thread(() => { try { var b = new Bitmap(w, ht); using (var g = Graphics.FromImage(b)) { var hdc = g.GetHdc(); PrintWindow(h, hdc, 2); g.ReleaseHdc(hdc); } lock (lk) { if (done) b.Dispose(); else { bmp = b; done = true; } } } catch { } });
    th2.IsBackground = true; th2.Start(); th2.Join(Math.Max(1, ms));
    lock (lk) { LastCaptureMs = Environment.TickCount - t0; if (!done) { done = true; return null; } return bmp; } }
  // 放回去以后又弹出来的记录：每次几毫秒后发现、前台还回去没有（下一次读的时候写进日志）
  public static readonly System.Collections.Concurrent.ConcurrentQueue<string> RepopLog = new System.Collections.Concurrent.ConcurrentQueue<string>();
  // 放回去以后再盯 0.8 秒：微信放出来时自己排了一个「激活」，可能在我们放回去之后才发作，把它又弹出来。弹出来了（而且你没动）就再放回去，记一次
  public static volatile int Repops; public static volatile int LastHideTick; public static volatile int Gen;
  public static void WatchRepop(IntPtr h, bool hidden, int ms) { WatchRepop(h, hidden, ms, IntPtr.Zero); }
  public static void WatchRepop(IntPtr h, bool hidden, int ms, IntPtr prevFg) {
    uint base0 = LastIn(); LastHideTick = Environment.TickCount; int gen = Gen;
    var t = new Thread(() => { int end = Environment.TickCount + ms; int n = 0; while (Environment.TickCount < end && Gen == gen && n < 3) {
      bool up = hidden ? IsWindowVisible(h) : !IsIconic(h); bool fg = GetForegroundWindow() == h;
      if ((up || fg) && !Active && Gen == gen) { if (LastIn() != base0) break; ShowWindow(h, hidden ? 0 : 7); if (hidden) ShowWindow(h, 0); bool fgOk = true; if (prevFg != IntPtr.Zero && GetForegroundWindow() != prevFg) fgOk = SetForegroundWindow(prevFg); Repops++; n++; RepopLog.Enqueue((Environment.TickCount - LastHideTick) + "ms:" + (fgOk ? "fg-ok" : "fg-not-restored")); Thread.Sleep(40); continue; }   // 你没动：放回去，前台也还给你原来的窗口；它要是又弹，再放（最多 3 次）。你动了就不管（那是你的操作）
      Thread.Sleep(15); } }); t.IsBackground = true; t.Start(); }
}
// 旧名字（值守和测试里用的 [Ghost]）指向同一个实现
public static class Ghost { public static bool Active { get { return Ghost7.Active; } } public static bool UserTouched { get { return Ghost7.UserTouched; } } public static bool Show(IntPtr h) { return Ghost7.Show(h); } public static void Hide() { Ghost7.Hide(); } }
public static class Ghost2 { public static bool Active { get { return Ghost7.Active; } } public static bool UserTouched { get { return Ghost7.UserTouched; } } public static bool LockOk { get { return Ghost7.LockOk; } } public static int ShownAt { get { return Ghost7.ShownAt; } } public static bool WasHidden { get { return Ghost7.WasHidden; } } public static int Repops { get { return Ghost7.Repops; } }
  public static bool Show(IntPtr h) { return Ghost7.Show(h); } public static void Hide() { Ghost7.Hide(); } public static uint IdleMs() { return Ghost7.IdleMs(); } public static IntPtr Fg() { return Ghost7.Fg(); } public static bool Back(IntPtr h) { return Ghost7.Back(h); } public static uint PidOf(IntPtr h) { return Ghost7.PidOf(h); }
  public static bool NeedsGhost(IntPtr h) { return Ghost7.NeedsGhost(h); } public static IntPtr HiddenMain(uint[] p, int w, int h) { return Ghost7.HiddenMain(p, w, h); } public static bool IsIconic(IntPtr h) { return Ghost7.IsIconic(h); } public static bool IsWindowVisible(IntPtr h) { return Ghost7.IsWindowVisible(h); } public static void WatchRepop(IntPtr h, bool hidden, int ms) { Ghost7.WatchRepop(h, hidden, ms); } public static void WatchRepop(IntPtr h, bool hidden, int ms, IntPtr prevFg) { Ghost7.WatchRepop(h, hidden, ms, prevFg); } }
'@ }

# 谁换了前台：ours = 我们放出来的那个软件；secretary = 秘书自己的窗口；other = 别的软件
function Get-FgChangeWho([uint32]$ghostPid, [uint32]$newPid) {
  if ($newPid -eq $ghostPid) { 'ours' } elseif ($newPid -eq $PID -or (@(Get-Process -Id $newPid -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in '秘书', 'powershell', 'msedgewebview2' }).Count)) { 'secretary' } else { 'other' } }
# 要不要把前台还回去：只有「我们放出来的软件自己抢的、你也没动」才还；你的操作和别的软件一律不动
function Test-GhostRestoreFg([string]$who, [bool]$userInput) { $who -eq 'ours' -and -not $userInput }# 放出来的时候前台变了：先把我们放出来的窗口收回去，再看是谁换的前台——
#   是我们放出来的那个软件自己（同一个程序）抢的、而且你没动 → 把原来的前台还回去
#   你自己动了（切窗口、点了别处），或者是别的软件 → 不去改回来，那是你的操作
# 每次记一行（只有时间差、锁住没有、哪一类程序、你动没动），在 v0.2\data\ghost_fg.jsonl
function Resolve-GhostFgChange([IntPtr]$ghostWin, [IntPtr]$fgBefore) {
  $fgNow = [Ghost2]::Fg(); $offset = [int]([Environment]::TickCount - [Ghost2]::ShownAt); $lock = [bool][Ghost2]::LockOk
  $user = [bool]([Ghost2]::UserTouched -or [Ghost2]::IdleMs() -lt [Math]::Max(0, $offset))
  [Ghost2]::Hide()
  $gp = [Ghost2]::PidOf($ghostWin); $np = [Ghost2]::PidOf($fgNow)
  $who = Get-FgChangeWho $gp $np; $restore = Test-GhostRestoreFg $who $user
  if ($restore -and $fgBefore -ne [IntPtr]::Zero) { [void][Ghost2]::Back($fgBefore) }
  $rec = [ordered]@{ ts = (Get-Date).ToString('s'); offset_ms = $offset; lock = $lock; who = $who; user_input = $user; restored = $restore }
  try { $lf = Join-Path $(if ($script:V2Data) { $script:V2Data } else { Join-Path $PSScriptRoot 'data' }) 'ghost_fg.jsonl'; [IO.File]::AppendAllLines($lf, [string[]]@(($rec | ConvertTo-Json -Compress))) } catch {}
  $rec
}# 读一个窗口：看得见 → 直接读；最小化 / 隐藏 → 透明地放出来读，读完放回原样。
# 你在用电脑（$MinIdleMs 内动过）就先不放出来；放出来时前台变了、或者你一碰鼠标键盘 → 马上放回，这一次不算
# 返回 @{ ok; value; ghost; why }
function Invoke-GhostRead([IntPtr]$h, [scriptblock]$Read, [int]$MinIdleMs = 5000) {
  if ($h -eq [IntPtr]::Zero) { return @{ ok = $false; why = '没找到窗口' } }
  if (-not [Ghost2]::NeedsGhost($h)) { return @{ ok = $true; ghost = $false; value = (& $Read) } }
  if ([Ghost2]::Active) { return @{ ok = $false; why = '正在读别的窗口' } }
  if ([Ghost2]::IdleMs() -lt $MinIdleMs) { return @{ ok = $false; why = '你在用电脑，等你停手再读' } }
  $fg = [Ghost2]::Fg(); if (-not [Ghost2]::Show($h)) { return @{ ok = $false; why = '正在读别的窗口' } }
  try {
    Start-Sleep -Milliseconds 120   # 系统接口读（Outlook、Edge）不用等画面，短一点
    if ([Ghost2]::Fg() -ne $fg) { $k = Resolve-GhostFgChange $h $fg; return @{ ok = $false; why = $(if ($k.restored) { '放出来时前台被它抢了，已放回' } else { '前台换了（不是我们弄的），保持不动' }); fg = $k } }
    if (-not [Ghost2]::Active) { return @{ ok = $false; why = '你动了电脑，已放回' } }
    $v = & $Read
    if ([Ghost2]::UserTouched) { return @{ ok = $false; why = '你动了电脑，已放回' } }
    @{ ok = $true; ghost = $true; value = $v }
  } finally { $was = [Ghost2]::WasHidden; [Ghost2]::Hide(); [Ghost2]::WatchRepop($h, $was, 800, $fg) }
}

# 截一张就收：要截图的读法（微信、插件、适配过的软件、适配本身）用这个。全透明、不激活地放出来 → 一画出来就截一张 → 马上放回原样 → 认字都在截好的图上做（窗口早就收回去了）
# 目标：露出来不到 0.25 秒（微信 4 放出来约 0.38 秒后会自己抢前台，要赶在它之前收回去）；最多等 $PaintMs 毫秒，还没画出来就放回、这次不算
# 放回去以后再盯 0.8 秒，看它会不会自己又弹出来（WatchRepop）。每次记一行数字到 ghost_reads.jsonl
function Test-Painted([Drawing.Bitmap]$b) {
  if (-not $b -or $b.Width -lt 200 -or $b.Height -lt 150) { return $false }   # 只有标题栏那么大一条（还是最小化的样子）不算画出来
  $seen = @{}; for ($i = 1; $i -le 7; $i++) { for ($j = 1; $j -le 7; $j++) { $c = $b.GetPixel([int]($b.Width * $i / 8), [int]($b.Height * $j / 8)); $seen["$([int]($c.R / 8)),$([int]($c.G / 8)),$([int]($c.B / 8))"] = $true } }
  $seen.Count -ge 3   # 全黑 / 全白 / 一种颜色 = 还没画出来
}
function Invoke-GhostSnap([IntPtr]$h, [int]$PaintMs = 200, [int]$MinIdleMs = 5000, [int]$CapMs = 300) {
  $rcap = { $r = [WinTools]::Rect($h); [Ghost7]::CaptureWithin($h, $r.R - $r.L, $r.B - $r.T, [Math]::Max(1, $CapMs - $sw.ElapsedMilliseconds)) }
  if ($h -eq [IntPtr]::Zero) { return @{ ok = $false; why = '没找到窗口' } }
  if (-not [Ghost2]::NeedsGhost($h)) { $r = [WinTools]::Rect($h); return @{ ok = $true; ghost = $false; bmp = [Rec]::Window($h, $r.R - $r.L, $r.B - $r.T) } }
  if ([Ghost2]::Active) { return @{ ok = $false; why = '正在读别的窗口' } }
  if ([Ghost2]::IdleMs() -lt $MinIdleMs) { return @{ ok = $false; why = '你在用电脑，等你停手再读' } }
  $fg = [Ghost2]::Fg(); $rep0 = [Ghost2]::Repops; $was = $false; $repLog = @(); $x = $null; while ([Ghost7]::RepopLog.TryDequeue([ref]$x)) { $repLog += $x }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  if (-not [Ghost2]::Show($h)) { return @{ ok = $false; why = '正在读别的窗口' } }
  $showMs = [int]$sw.ElapsedMilliseconds; $bmp = $null; $tries = 0; $touched = $false; $capMsList = @(); $overCap = $false
  try {
    $was = [Ghost2]::WasHidden
    # 一画出来就截；截图在另一个线程里做，露出来最多 $CapMs 毫秒：到点没截完就收回去、这次不要（以前一次截图有时要 0.3–0.6 秒）
    while ($sw.ElapsedMilliseconds -lt $PaintMs -and [Ghost2]::Active) {
      $tries++; $b = & $rcap; $capMsList += [Ghost7]::LastCaptureMs
      if (-not $b) { $overCap = $true; break }
      if (Test-Painted $b) { $bmp = $b; break }; $b.Dispose()
      if ($sw.ElapsedMilliseconds + [Ghost7]::LastCaptureMs -ge $CapMs) { $overCap = $true; break }   # 再截一次就会超时：不截了
      Start-Sleep -Milliseconds 15 }
    $touched = [bool][Ghost2]::UserTouched
  } finally { $vis = [int]$sw.ElapsedMilliseconds; [Ghost2]::Hide(); $hideMs = [int]$sw.ElapsedMilliseconds - $vis; [Ghost2]::WatchRepop($h, $was, 800, $fg) }
  $fgNow = [Ghost2]::Fg(); $fgChanged = $fgNow -ne $fg; $restored = $false; $who = ''
  if ($fgChanged) { $who = Get-FgChangeWho ([Ghost2]::PidOf($h)) ([Ghost2]::PidOf($fgNow)); if ($who -eq 'ours' -and -not $touched -and [Ghost2]::IdleMs() -gt $vis) { $restored = [Ghost2]::Back($fg) } }   # 是它自己抢的、你没动：还回去；别的程序 / 你自己切的：不动
  $rec = [ordered]@{ ts = (Get-Date).ToString('s'); mode = 'snap'; state = $(if ($was) { 'tray' } else { 'minimized' }); visible_ms = $vis; show_ms = $showMs; capture_ms = @($capMsList); hide_ms = $hideMs; over_cap = $overCap; painted = [bool]$bmp; tries = $tries
    fg_changed = $fgChanged; fg_who = $who; fg_restored = $restored; user_input = $touched; repops_before = $rep0; repops_since_last = @($repLog) }
  try { $lf = Join-Path $(if ($script:V2Data) { $script:V2Data } else { Join-Path $PSScriptRoot 'data' }) 'ghost_reads.jsonl'; [IO.File]::AppendAllLines($lf, [string[]]@(($rec | ConvertTo-Json -Compress))) } catch {}
  if ($touched) { if ($bmp) { $bmp.Dispose() }; return @{ ok = $false; why = '你动了电脑，已放回'; rec = $rec } }
  if ($overCap) { if ($bmp) { $bmp.Dispose() }; return @{ ok = $false; why = '截图太慢，已放回，这次不读'; rec = $rec; slow = $true } }
  if (-not $bmp) { return @{ ok = $false; why = '没来得及画出来，已放回，下次再试'; rec = $rec } }
  @{ ok = $true; ghost = $true; bmp = $bmp; rec = $rec }
}