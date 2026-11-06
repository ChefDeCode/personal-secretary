# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 边缘线.ps1（v0.2）— 屏幕边上的小波浪：显示秘书状态，点一下呼出/收起小浮窗，按住拖动可以换位置
# 画法：直接运行定稿 ui\float_v2.html 的绘制代码（ui\edge.html，requestAnimationFrame 逐帧），不在这里另写一套
# 窗口：无边框、置顶、工具窗口（不进任务栏、所有桌面可见）、不抢焦点；用颜色键做透明，WebView2 背景透明；
#       显示窗口永远鼠标穿透；线上盖一条几乎不可见的命中窗口（不透明度 1/255）接收悬停/点击/拖动并转告页面；拖动时窗口跟着鼠标走，线卷成圆环
# 状态（每 0.3 秒推给页面）：干活中 = data\state.json 亮着；暂停 = 用户在设置里关了“读取微信”；值守没在运行不算暂停（照常微微起伏）；
#       新提醒/重要 = data\notice.json 未看过；勿扰、主题、贴边读 config.json；浮窗开着读 v0.2\data\ui_state.json；位置写 v0.2\data\edge_pos.json
# 用法：由 秘书.ps1 或 12_值守.ps1 以 -OwnerPid 启动；-Test 时额外读 v0.2\data\edge_test.json 覆盖状态并记录帧间隔（测量用）
param([int]$OwnerPid = 0, [switch]$Test)
$v2 = $PSScriptRoot; $root = Split-Path $v2 -Parent
. (Join-Path $root 'lib_窗口工具.ps1')   # 同时把本进程设为每显示器 DPI 感知 V2
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)   # 出错不弹 .NET 错误框
$wvDir = Join-Path $root 'lib\webview2'
Add-Type -Path (Join-Path $wvDir 'Microsoft.Web.WebView2.Core.dll'); Add-Type -Path (Join-Path $wvDir 'Microsoft.Web.WebView2.WinForms.dll')
[Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($wvDir)
$dataV1 = Join-Path $root 'data'; $dataV2 = Join-Path $v2 'data'; New-Item -ItemType Directory -Force $dataV2 | Out-Null
$stateFile = Join-Path $dataV1 'state.json'; $noticeFile = Join-Path $dataV1 'notice.json'
$uiFile = Join-Path $dataV2 'ui_state.json'; $posFile = Join-Path $dataV2 'edge_pos.json'

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, (Join-Path $wvDir 'Microsoft.Web.WebView2.Core.dll') @'
using System; using System.Drawing; using System.Windows.Forms; using System.Runtime.InteropServices;
public class EdgeForm : Form {
  public EdgeForm() { FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual; }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x80 | 0x08000000 | 0x8 | 0x20; return p; } }   // 工具窗口 | 不激活 | 置顶 | 鼠标穿透（显示用，永远点不中）
}
// 命中窗口：盖在线上的一条几乎不可见的窗口（不透明度 1/255，仍能接收鼠标），负责悬停、点击、拖动，再转告页面
public class HitForm : Form {
  public HitForm() { FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual; BackColor = Color.Black; Opacity = 1.0 / 255; Cursor = new Cursor(LoadCursor(IntPtr.Zero, 32649)); }   // 系统手形指针（跟随系统缩放；WinForms 自带的 Cursors.Hand 在 200% 下会变小）
  [DllImport("user32.dll")] static extern IntPtr LoadCursor(IntPtr h, int id);
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x80 | 0x08000000 | 0x8; return p; } }
  protected override void WndProc(ref Message m) { if (m.Msg == 0x21) { m.Result = (IntPtr)3; return; } base.WndProc(ref m); }   // WM_MOUSEACTIVATE → 不激活
}
public class EdgeCtl {
  [DllImport("user32.dll")] static extern bool GetCursorPos(out Point p);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid); public static int OwnerPid;
  public Form F; public HitForm Hit = new HitForm(); public Microsoft.Web.WebView2.Core.CoreWebView2 Web;
  public double Scale = 1, LineX = 282, H = 300; public bool Dragging; public Point LastPt; public event EventHandler Clicked, DragEnded, GlideDone;
  Point downAt; bool down, hover;
  // 松手后的滑回：窗口滑到贴边位置，页面里的线一直在窗口中央，同时由圆环舒展回波浪
  Timer glide = new Timer(); int gx0, gy0, gx1, gy1; double gms; System.Diagnostics.Stopwatch gsw = new System.Diagnostics.Stopwatch();
  public EdgeCtl() {
    glide.Interval = 10;
    glide.Tick += (s, e) => {
      double t = Math.Min(1, gsw.Elapsed.TotalMilliseconds / gms), k = 1 - Math.Pow(1 - t, 3);   // 缓出
      SetWindowPos(F.Handle, new IntPtr(-1), (int)Math.Round(gx0 + (gx1 - gx0) * k), (int)Math.Round(gy0 + (gy1 - gy0) * k), 0, 0, 0x0001 | 0x0010);
      if (t >= 1) { glide.Stop(); PlaceHit(); if (GlideDone != null) GlideDone(this, EventArgs.Empty); }
    };
    Hit.MouseEnter += (s, e) => { hover = true; Post("{\"type\":\"hover\",\"on\":true}"); };
    Hit.MouseLeave += (s, e) => { hover = false; if (!Dragging) Post("{\"type\":\"hover\",\"on\":false}"); };
    Hit.MouseDown += (s, e) => { if (e.Button == MouseButtons.Left) { down = true; downAt = Cursor; } };
    Hit.MouseMove += (s, e) => {
      if (!down) return; Point p = Cursor;
      if (!Dragging && Math.Abs(p.X - downAt.X) + Math.Abs(p.Y - downAt.Y) > 5 * Scale) { Dragging = true; Post("{\"type\":\"drag\",\"on\":true}"); }
      if (Dragging) Follow(p);
    };
    Hit.MouseUp += (s, e) => {
      if (!down) return; down = false;
      if (Dragging) { Dragging = false; Post("{\"type\":\"drag\",\"on\":false}"); if (!hover) Post("{\"type\":\"hover\",\"on\":false}"); if (DragEnded != null) DragEnded(this, EventArgs.Empty); }
      else { AllowSetForegroundWindow(OwnerPid > 0 ? OwnerPid : -1); if (Clicked != null) Clicked(this, EventArgs.Empty); }   // 本进程刚收到点击，把“设前台”的权利只让给秘书本身（不是所有程序，免得微信之类趁机跳到前台），浮窗才能拿到焦点
    };
  }
  public Point Cursor { get { Point p; GetCursorPos(out p); return p; } }
  void Post(string j) { if (Web != null) { try { Web.PostWebMessageAsJson(j); } catch { } } }
  // 拖动：线中心对准指针，命中窗口缩成 48×48 跟着
  void Follow(Point p) {
    if (glide.Enabled) glide.Stop(); LastPt = p;
    SetWindowPos(F.Handle, new IntPtr(-1), (int)(p.X - LineX * Scale), (int)(p.Y - H / 2 * Scale), 0, 0, 0x0001 | 0x0010);
    int s = (int)(48 * Scale); SetWindowPos(Hit.Handle, new IntPtr(-1), p.X - s / 2, p.Y - s / 2, s, s, 0x0010);
  }
  // 命中区：线中心两侧各 20、上下各 (196+24)/2（舒展后的长度，与定稿 #hit 一致）
  // 从当前位置滑到 (x, y)；滑动时命中窗口缩成一个点停在终点，滑完再铺开（避免滑动途中误触悬停）
  public void GlideTo(int x, int y, double ms) {
    gx0 = F.Left; gy0 = F.Top; gx1 = x; gy1 = y; gms = Math.Max(1, ms);
    SetWindowPos(Hit.Handle, new IntPtr(-1), (int)(x + LineX * Scale), (int)(y + H / 2 * Scale), 1, 1, 0x0010);
    gsw.Restart(); glide.Start();
  }
  // 测量用：不动真实鼠标，走和真实拖动相同的路径（Follow → DragEnded）
  public void SimBegin(Point p) { down = true; downAt = p; Dragging = true; Post("{\"type\":\"drag\",\"on\":true}"); Follow(p); }
  public void SimMove(Point p) { if (Dragging) Follow(p); }
  public void SimEnd() { if (!Dragging) return; down = false; Dragging = false; Post("{\"type\":\"drag\",\"on\":false}"); if (!hover) Post("{\"type\":\"hover\",\"on\":false}"); if (DragEnded != null) DragEnded(this, EventArgs.Empty); }
  public void PlaceHit() {
    int w = (int)(40 * Scale), h = (int)(220 * Scale);
    SetWindowPos(Hit.Handle, new IntPtr(-1), (int)(F.Left + LineX * Scale) - w / 2, (int)(F.Top + H / 2 * Scale) - h / 2, w, h, 0x0010);
  }
}
'@
[EdgeCtl]::OwnerPid = $OwnerPid   # 点线以后只把「设前台」的权利让给秘书本身

# —— 尺寸（DIP）：窗口 564×300，线永远在窗口正中，离贴靠的屏幕边 18（与定稿一致），两侧各 282 留给舒展、圆环和摘要胶囊 ——
#    贴边时朝外的一半在屏幕外（透明、鼠标穿透）；线在窗口里的位置不随贴左/贴右变化，所以换边也只是整窗滑过去，不会跳
$W = 564.0; $H = 300.0
$scr = [Windows.Forms.Screen]::PrimaryScreen; $wa = $scr.WorkingArea
$g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g.DpiX / 96; $g.Dispose()   # 本进程是每显示器 DPI 感知，这里拿到的是真实缩放（200% → 2）
$wpx = [int]($W * $scale); $hpx = [int]($H * $scale)
$key = [Drawing.Color]::FromArgb(150, 139, 126)   # 颜色键取暖灰（介于浅/深色线色之间），线边缘抗锯齿不会出现明显的黑/白毛边
$form = New-Object EdgeForm
$form.BackColor = $key; $form.TransparencyKey = $key; $form.Text = '秘书小波浪'
$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2; $wv.Dock = 'Fill'; $wv.DefaultBackgroundColor = [Drawing.Color]::Transparent
$cp = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties; $cp.UserDataFolder = Join-Path $dataV2 'webview2_edge'; $wv.CreationProperties = $cp
$form.Controls.Add($wv)
$ctl = New-Object EdgeCtl; $ctl.F = $form; $ctl.Scale = $scale; $ctl.H = $H

# —— 位置：贴左/右边（默认右边、垂直居中），或自由摆放（设置里关掉“贴边”）——
$script:side = 'right'; $script:freeX = $null; $script:topPx = $wa.Top + [int](($wa.Height - $hpx) / 2)
if (Test-Path $posFile) { try { $p = Get-Content $posFile -Raw | ConvertFrom-Json; $script:side = [string]$p.side; if ($p.y -ne $null) { $script:topPx = [int]([double]$p.y * $scale) }; if ($p.side -eq 'free') { $script:freeX = [int]([double]$p.x * $scale) } } catch {} }
function Page-Side { if ($script:side -eq 'free') { if (($form.Left + $wpx / 2) -lt ($wa.Left + $wa.Width / 2)) { 'left' } else { 'right' } } else { $script:side } }
function Line-X { $W / 2 }
# 目标位置（像素）：贴左/贴右时线离屏幕边 18；自由摆放就在原处
function Target-Pos {
  $top = [Math]::Max($wa.Top, [Math]::Min($wa.Bottom - $hpx, $script:topPx))
  $left = switch ($script:side) { 'left' { $wa.Left + 18 * $scale - $wpx / 2 } 'free' { $script:freeX } default { $wa.Right - 18 * $scale - $wpx / 2 } }
  [int]$left, [int]$top
}
function Place-Window {
  $left, $top = Target-Pos
  $form.Bounds = New-Object Drawing.Rectangle $left, $top, $wpx, $hpx
  $ctl.LineX = Line-X
  if ($ctl.Hit.IsHandleCreated) { $ctl.PlaceHit() }
}
# 小浮窗（秘书.ps1）按这里的 lineX/lineY（DIP）× scale 摆在线旁边
function Save-Pos { [IO.File]::WriteAllText($posFile, (@{ side = $(if ($script:side -eq 'free') { 'free' } else { $script:side }); x = $form.Left / $scale; y = $form.Top / $scale; lineX = $form.Left / $scale + (Line-X); lineY = $form.Top / $scale + $H / 2; scale = $scale } | ConvertTo-Json -Compress)) }
Place-Window; Save-Pos

# —— 状态 → 页面 ——
function Post($obj) { if ($wv.CoreWebView2) { $wv.CoreWebView2.PostWebMessageAsJson(($obj | ConvertTo-Json -Depth 5 -Compress)) } }
$script:lastNoticeTs = $null; $script:testSeq = $null; $script:testState = $null
function Read-States {
  $cfg = $null; try { $cfg = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  $working = Test-Lit $stateFile
  $userPaused = $false; try { if ($null -ne $cfg.features.watch_wechat) { $userPaused = -not [bool]$cfg.features.watch_wechat } } catch {}; try { if ([bool]$cfg.features.paused) { $userPaused = $true } } catch {}
  $open = $false; try { if (Test-Path $uiFile) { $open = [bool](Get-Content $uiFile -Raw -ErrorAction Stop | ConvertFrom-Json).miniOpen } } catch {}
  $n = $null; try { if (Test-Path $noticeFile) { $n = Get-Content $noticeFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } } catch {}
  $msg = @{ type = 'state'; base = $(if ($working) { 'reading' } elseif ($userPaused) { 'paused' } else { 'idle' }); alert = $null; dnd = [bool]$cfg.dnd; open = $open
            theme = [string]$cfg.ui_theme; side = (Page-Side); ripple = $false; pill = $null }
  if ($n -and -not $n.seen) {
    $msg.alert = [string]$n.kind
    if ($null -eq $script:lastNoticeTs) { $script:lastNoticeTs = [string]$n.ts }   # 启动前就有的提醒：只保持颜色，不再划波
    elseif ([string]$n.ts -ne $script:lastNoticeTs) {                            # 新来的提醒：划一道波；重要的再滑出摘要
      $script:lastNoticeTs = [string]$n.ts; $msg.ripple = $true
      if ($n.kind -eq 'important' -and $n.summary) { $parts = ([string]$n.summary) -split '：', 2; $msg.pill = @{ who = $parts[0]; text = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) } }
    }
  } elseif ($n) { $script:lastNoticeTs = [string]$n.ts } else { $script:lastNoticeTs = '' }
  # 秘书自己的短提示（比如“还在托盘里”、操作失败）：从线里滑出一行，勿扰时也显示
  $np = Join-Path $dataV2 'notice_pill.json'
  if (Test-Path $np) { try { $nj = Get-Content $np -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $script:lastPillTs) { $script:lastPillTs = [string]$nj.ts }   # 启动前的旧提示不再弹
    elseif ([string]$nj.ts -ne $script:lastPillTs) { $script:lastPillTs = [string]$nj.ts; $msg.pill = @{ who = '秘书'; text = [string]$nj.text; force = $true } } } catch {} }
  elseif ($null -eq $script:lastPillTs) { $script:lastPillTs = '' }
  if ($Test) { Apply-Test $msg }
  $signature = $msg | ConvertTo-Json -Compress -Depth 5
  if ($signature -ne $script:lastStateSignature) { Post $msg; $script:lastStateSignature = $signature }
  # 微信外的边框（功能开关 border）只在借用前台发送时亮（border.json，只有发送写）；读取、思考时只让这条线呼吸，不亮边框
  $borderFile = Join-Path $dataV1 'border.json'
  if ((Test-Lit $borderFile) -and (Get-Feature 'border') -and (-not $script:borderProc -or $script:borderProc.HasExited)) {
    $script:borderProc = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root '07_AI边框特效.ps1'), '-StateFile', $borderFile)
  }
  if ($OwnerPid -and -not (Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue)) { $form.Close() }
}
# 测量用：edge_test.json = {seq, base, alert, hover, drag, ripple, stats:"上一段的标签"}；seq 变了才生效
function Apply-Test($msg) {
  $tf = Join-Path $dataV2 'edge_test.json'; if (-not (Test-Path $tf)) { return }
  try { $tj = Get-Content $tf -Raw | ConvertFrom-Json } catch { return }
  if ($tj.seq -ne $script:testSeq) {
    $script:testSeq = $tj.seq; $script:testState = $tj
    if ($tj.stats) { Post @{ type = 'stats'; label = [string]$tj.stats; n = 600 } }
    if ($tj.ripple) { $msg.ripple = $true }
    # 模拟拖动：path = [[x,y],...]（屏幕像素），每 16 毫秒走一个点，走完松手；同时让页面记录接下来 1.2 秒每帧的圆环程度和线的位置
    if ($tj.path) { $script:simPath = @($tj.path); $script:simI = 0; Post @{ type = 'probe'; label = [string]$tj.seq; ms = 1200 + 16 * $script:simPath.Count }; $simTimer.Start() }
  }
  $ts = $script:testState; if (-not $ts -or $ts.path) { return }
  if ($ts.base) { $msg.base = [string]$ts.base }; if ($ts.alert) { $msg.alert = [string]$ts.alert }
  $msg.test = @{ hover = [bool]$ts.hover; drag = [bool]$ts.drag }
}

# —— 页面消息：点一下 = 开/收小浮窗；拖动 = 窗口跟手，松手贴回最近的一边 ——
$wv.add_CoreWebView2InitializationCompleted({
  param($s, $e)
  if (-not $e.IsSuccess) { $form.Close(); return }
  $c = $wv.CoreWebView2; $ctl.Web = $c
  $c.Settings.AreDefaultContextMenusEnabled = $false; $c.Settings.IsStatusBarEnabled = $false; $c.Settings.AreDevToolsEnabled = $false; $c.Settings.IsZoomControlEnabled = $false
  $c.SetVirtualHostNameToFolderMapping('secretary.local', (Join-Path $v2 'ui'), [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Deny)
  $c.add_NavigationStarting({ param($s2, $e2) if (-not $e2.Uri.StartsWith('https://secretary.local/')) { $e2.Cancel = $true } })
  $c.add_NewWindowRequested({ param($s2, $e2) $e2.Handled = $true })
  $c.add_WebMessageReceived({
    param($s2, $e2); try { $m = $e2.WebMessageAsJson | ConvertFrom-Json } catch { return }
    switch ($m.type) {
      'ready' { $script:lastStateSignature = $null; Read-States }
      { $_ -in 'stats', 'probe' } { Add-Content (Join-Path $dataV2 'edge_stats.jsonl') ($m | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8 }
    }
  })
  $c.Navigate('https://secretary.local/edge.html')
})
$stTimer = New-Object Windows.Forms.Timer; $stTimer.Interval = 300; $stTimer.add_Tick({ try { Read-States } catch { Write-EdgeError $_.Exception 'read-states' } })
$simTimer = New-Object Windows.Forms.Timer; $simTimer.Interval = 16; $script:simPath = @(); $script:simI = 0
$simTimer.add_Tick({
  if ($script:simI -ge $script:simPath.Count) { $simTimer.Stop(); $ctl.SimEnd(); return }
  $pt = New-Object Drawing.Point ([int]$script:simPath[$script:simI][0]), ([int]$script:simPath[$script:simI][1])
  if ($script:simI -eq 0) { $ctl.SimBegin($pt) } else { $ctl.SimMove($pt) }; $script:simI++
})
# —— 命中窗口的事件：点一下 = 开/收小浮窗（秘书没在运行就启动它）；拖完 = 贴回最近的一边（或自由摆放）——
$ctl.add_Clicked({
  $ev = $null; try { $ev = [Threading.EventWaitHandle]::OpenExisting('Local\SecretaryPanelToggle') } catch {}
  if ($ev) { [void]$ev.Set(); $ev.Dispose() } else { $form.Close() }   # 主程序已退出：收掉孤立边缘线，不替用户重新打开
})
$ctl.add_DragEnded({
  $p = $ctl.LastPt
  $snap = $true; try { $sv = (Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).edge_snap; if ($null -ne $sv) { $snap = [bool]$sv } } catch {}
  if ($snap) { $script:side = $(if ($p.X -lt ($wa.Left + $wa.Width / 2)) { 'left' } else { 'right' }) } else { $script:side = 'free'; $script:freeX = $form.Left }
  # 松手：窗口从当前位置缓出滑到贴边处（约 0.45 秒），页面同时把圆环舒展回波浪；每次松手都一样，不论是否换边
  $script:topPx = $form.Top; $left, $top = Target-Pos
  Read-States
  if ($left -eq $form.Left -and $top -eq $form.Top) { $ctl.PlaceHit(); Save-Pos } else { $ctl.GlideTo($left, $top, 450) }
})
$ctl.add_GlideDone({ Save-Pos })
$form.add_FormClosed({ try { $ctl.Hit.Close() } catch {} })
$form.add_Shown({ [void]$wv.EnsureCoreWebView2Async($null); $ctl.Hit.Show(); $ctl.PlaceHit(); $stTimer.Start() })
# 只记错误类型、位置和调用栈
function Write-EdgeError($ex, [string]$where) { try { Add-Content (Join-Path $dataV2 'errors.log') "$((Get-Date).ToString('s')) [edge:$where] $($ex.GetType().FullName) @ $($ex.TargetSite) | $(([string]$ex.ErrorRecord.ScriptStackTrace) -replace '\r?\n', ' <- ')" -Encoding UTF8 } catch {} }
[Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-EdgeError $e.Exception 'ui' })
[Windows.Forms.Application]::Run($form)
