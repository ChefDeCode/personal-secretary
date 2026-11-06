# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_识别.ps1 — 微信窗口的本地识别（捕获、版面标定、聊天区/标题/会话列表 OCR、图片块），供 12_值守.ps1 使用
# 只读：只对窗口做 PrintWindow 捕获和本机 Windows OCR；不点击、不输入、不滚动、不联网。
# 依赖 lib_窗口工具.ps1（DPI 感知、窗口工具），调用方需先 dot-source 它。
Add-Type -AssemblyName System.Drawing, System.Runtime.WindowsRuntime
Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class Rec {
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  public static int Cloaked(IntPtr h) { int v; DwmGetWindowAttribute(h, 14, out v, 4); return v; }
  [DllImport("user32.dll", EntryPoint = "PostMessageW")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  // 第 2 步：向窗口投递一次左键单击（窗口内坐标，微信 4.x 为无边框窗口，窗口坐标即客户区坐标）；不移动真实鼠标、不激活窗口
  public static void Click(IntPtr h, int x, int y) {
    var l = (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF));
    PostMessage(h, 0x0200, IntPtr.Zero, l);          // WM_MOUSEMOVE
    PostMessage(h, 0x0201, (IntPtr)1, l);            // WM_LBUTTONDOWN (MK_LBUTTON)
    PostMessage(h, 0x0202, IntPtr.Zero, l); }        // WM_LBUTTONUP
  public static Bitmap Window(IntPtr h, int w, int ht) {
    var bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) { var hdc = g.GetHdc(); PrintWindow(h, hdc, 2); g.ReleaseHdc(hdc); }
    return bmp; }
  static int[] Pixels(Bitmap b) {
    var data = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    var px = new int[b.Width * b.Height]; Marshal.Copy(data.Scan0, px, 0, px.Length); b.UnlockBits(data); return px; }
  static int Lum(int c) { return (((c >> 16) & 0xFF) * 299 + ((c >> 8) & 0xFF) * 587 + (c & 0xFF) * 114) / 1000; }
  // 画面指纹（采样哈希）：只用于判断画面是否变化
  public static long Fingerprint(Bitmap b) { var px = Pixels(b); long h = 17; for (int i = 0; i < px.Length; i += 37) h = h * 31 + px[i]; return h; }
  // 版面标定：{聊天区左边界, 上边界, 下边界}（比例）+ 背景亮度；方法同 10_后台OCR读取.ps1
  public static double[] Layout(Bitmap b) {
    int w = b.Width, h = b.Height; var px = Pixels(b);
    var bg = new List<int>();
    for (int y = (int)(h * .15); y < h * .85; y += 10) for (int x = (int)(w * .55); x < w - 20; x += 25) bg.Add(Lum(px[y * w + x]));
    bg.Sort(); int bgL = bg[bg.Count / 2];
    int best = (int)(w * .3), bestVotes = 0;
    for (int x = (int)(w * .10); x < w * .6; x += 2) { int votes = 0;
      for (int y = (int)(h * .10); y < h * .95; y += 8) { int l = Lum(px[y * w + x - 6]), r = Lum(px[y * w + x + 6]);
        if (Math.Abs(r - bgL) <= 3 && Math.Abs(l - bgL) >= 6) votes++; }
      if (votes > bestVotes) { bestVotes = votes; best = x; } }
    int left = best + 8;
    Func<int, bool> isRule = y => { int first = Lum(px[y * w + left + 10]); if (Math.Abs(first - bgL) < 3) return false;
      for (int x = left + 10; x < w - 10; x += 16) if (Math.Abs(Lum(px[y * w + x]) - first) > 3) return false; return true; };
    int top = (int)(h * .08), bottom = (int)(h * .92);
    for (int y = (int)(h * .25); y > 0; y--) if (isRule(y)) { top = y + 2; break; }
    for (int y = (int)(h * .55); y < h; y++) if (isRule(y)) { bottom = y - 2; break; }
    return new double[] { (double)left / w, (double)top / h, (double)bottom / h, bgL }; }
  // 图片块：同 10_后台OCR读取.ps1
  public static List<Rectangle> FindImages(Bitmap b, int cell, int minColors, int minSize, int bgLum) {
    int gw = b.Width / cell, gh = b.Height / cell; var hit = new bool[gw, gh]; var px = Pixels(b); var seen = new HashSet<int>();
    for (int gy = 0; gy < gh; gy++) for (int gx = 0; gx < gw; gx++) {
      seen.Clear(); long sr = 0, sg = 0, sb = 0; int n = 0;
      for (int y = gy * cell; y < (gy + 1) * cell; y += 2) for (int x = gx * cell; x < (gx + 1) * cell; x += 2) {
        int c = px[y * b.Width + x]; seen.Add(((c >> 20) & 0xF) << 8 | ((c >> 12) & 0xF) << 4 | ((c >> 4) & 0xF));
        sr += (c >> 16) & 0xFF; sg += (c >> 8) & 0xFF; sb += c & 0xFF; n++; }
      int mr = (int)(sr / n), mg = (int)(sg / n), mb = (int)(sb / n), ml = (mr * 299 + mg * 587 + mb * 114) / 1000;
      bool wechatGreen = mg > mr + 50 && mg > mb + 20;
      hit[gx, gy] = seen.Count >= minColors || (bgLum < 80 && ml > bgLum + 90 && !wechatGreen); }
    var res = new List<Rectangle>(); var done = new bool[gw, gh]; var q = new Queue<Point>();
    for (int gy = 0; gy < gh; gy++) for (int gx = 0; gx < gw; gx++) {
      if (!hit[gx, gy] || done[gx, gy]) continue;
      int x0 = gx, x1 = gx, y0 = gy, y1 = gy; q.Enqueue(new Point(gx, gy)); done[gx, gy] = true;
      while (q.Count > 0) { var p = q.Dequeue();
        x0 = Math.Min(x0, p.X); x1 = Math.Max(x1, p.X); y0 = Math.Min(y0, p.Y); y1 = Math.Max(y1, p.Y);
        for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) { int nx = p.X + dx, ny = p.Y + dy;
          if (nx >= 0 && ny >= 0 && nx < gw && ny < gh && hit[nx, ny] && !done[nx, ny]) { done[nx, ny] = true; q.Enqueue(new Point(nx, ny)); } } }
      var r = new Rectangle(x0 * cell, y0 * cell, (x1 - x0 + 1) * cell, (y1 - y0 + 1) * cell);
      if (r.Width >= minSize && r.Height >= minSize) res.Add(r); }
    return res; }
  // 未读角标：微信红色（R 高、G/B 低）像素连成的小块，返回各块中心（会话列表区域内的坐标）
  // 边长超过 maxSide 的红块不算（例如本身是红色的头像），角标直径约 8~20 DIP
  public static List<Point> RedBadges(Bitmap b, int minPx, int maxSide) {
    int w = b.Width, h = b.Height; var px = Pixels(b); var mark = new bool[w, h]; var res = new List<Point>();
    for (int y = 0; y < h; y += 2) for (int x = 0; x < w; x += 2) { int c = px[y * w + x];
      int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, bl = c & 0xFF; mark[x, y] = r > 190 && g < 100 && bl < 100 && r - g > 110; }
    var done = new bool[w, h]; var q = new Queue<Point>();
    for (int y = 0; y < h; y += 2) for (int x = 0; x < w; x += 2) {
      if (!mark[x, y] || done[x, y]) continue; long sx = 0, sy = 0; int n = 0, bx0 = x, bx1 = x, by0 = y, by1 = y;
      q.Enqueue(new Point(x, y)); done[x, y] = true;
      while (q.Count > 0) { var p = q.Dequeue(); sx += p.X; sy += p.Y; n++;
        bx0 = Math.Min(bx0, p.X); bx1 = Math.Max(bx1, p.X); by0 = Math.Min(by0, p.Y); by1 = Math.Max(by1, p.Y);
        for (int d = 0; d < 4; d++) { int nx = p.X + (d == 0 ? 2 : d == 1 ? -2 : 0), ny = p.Y + (d == 2 ? 2 : d == 3 ? -2 : 0);
          if (nx >= 0 && ny >= 0 && nx < w && ny < h && mark[nx, ny] && !done[nx, ny]) { done[nx, ny] = true; q.Enqueue(new Point(nx, ny)); } } }
      if (n >= minPx && bx1 - bx0 <= maxSide && by1 - by0 <= maxSide) res.Add(new Point((int)(sx / n), (int)(sy / n))); }
    return res; }
}
'@
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$script:asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$type) { $t = $script:asTask.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait(-1) | Out-Null; $t.Result }
$script:ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]::new('zh-Hans-CN'))

function Invoke-Ocr([Drawing.Bitmap]$bmp) {
  $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $ms.Position = 0
  $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($ms)
  $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ras)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $r = Await ($script:ocrEngine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult]); $ms.Dispose(); $r
}
function Clean-Text([string]$s) { $s -replace '(?<=[一-鿿＀-￯，。！？、：；“”‘’（）])\s+|\s+(?=[一-鿿＀-￯，。！？、：；“”‘’（）])', '' }
function Crop([Drawing.Bitmap]$src, [Drawing.Rectangle]$r) { $src.Clone($r, [Drawing.Imaging.PixelFormat]::Format32bppArgb) }
# OCR 结果 → 行对象（坐标为裁剪图内像素）
function Get-Lines($res) {
  foreach ($line in $res.Lines) {
    $b = @($line.Words | ForEach-Object { $_.BoundingRect })
    [pscustomobject]@{
      x0 = ($b | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
      x1 = ($b | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum
      y  = ($b | ForEach-Object { $_.Y } | Measure-Object -Minimum).Minimum
      h  = ($b | ForEach-Object { $_.Height } | Measure-Object -Maximum).Maximum
      文本 = Clean-Text $line.Text }
  }
}
$script:TimeRx = '^\s*((上午|下午|晚上|凌晨|中午|昨天|前天|星期.|周.)?\s*\d{1,2}:\d{2}|\d{4}[/年-]\d{1,2}[/月-]\d{1,2}日?.*|\d{1,2}[/月]\d{1,2}日?.*|昨天|前天|星期.)\s*$'

# —— 谁说的：以气泡左右位置为主、气泡颜色为辅；两者矛盾时记「不确定」，绝不猜成「对方」 ——
# 以前只看文字行的左右：你自己发的长消息一行很宽、起点靠左，就被当成了别人说的。
# 现在先找文字所在的气泡（从文字两侧往外扫同色像素，得到气泡左右边），用气泡的边判断：
#   气泡右边贴着右侧头像 → 自己；左边贴着左侧头像 → 别人；两边都贴（很长）或都不贴 → 位置判断不了
# 颜色：绿色（浅色模式 #95EC69 一类、深色模式深绿）→ 自己；灰白 / 深灰这类中性色（和背景不同）→ 别人
# 位置、颜色都有结论但不一致 → 不确定；找不到气泡（比如群名片的名字行）就退回看文字行的位置
# $script:WxSelfSide = 'left' 时左右对调（适配里的「自己在哪一边」，默认右边）
if (-not ('BubScan' -as [type])) { Add-Type -ReferencedAssemblies System.Drawing @"
using System.Drawing;
public static class BubScan {
  static bool Near(Color a, Color b) { return System.Math.Abs(a.R - b.R) + System.Math.Abs(a.G - b.G) + System.Math.Abs(a.B - b.B) < 30; }
  // 从 x 往左（dir=-1）或往右（dir=1）扫，和参考色相近就继续；返回最后一个同色的 x
  public static int Edge(Bitmap b, int x, int y, int dir, Color c) { while (x + dir >= 0 && x + dir < b.Width && Near(b.GetPixel(x + dir, y), c)) x += dir; return x; }
}
"@ }
function Test-Green($c) { $c.G - $c.R -gt 25 -and $c.G - $c.B -gt 15 }
function Get-Lum($c) { ($c.R * 299 + $c.G * 587 + $c.B * 114) / 1000 }
function Get-Bubble([Drawing.Bitmap]$img, $l, [double]$dpi, [int]$bgLum) {
  $y = [int]($l.y + $l.h / 2); if ($y -lt 0 -or $y -ge $img.Height) { return $null }
  $best = $null
  foreach ($sx in @([int]($l.x0 - 3 * $dpi), [int]($l.x1 + 3 * $dpi))) {
    if ($sx -lt 0 -or $sx -ge $img.Width) { continue }
    $c = $img.GetPixel($sx, $y); $green = Test-Green $c
    $neutral = [Math]::Abs($c.R - $c.G) -lt 14 -and [Math]::Abs($c.G - $c.B) -lt 14
    if (-not $green -and -not ($neutral -and ($bgLum -lt 0 -or [Math]::Abs((Get-Lum $c) - $bgLum) -gt 6))) { continue }   # 取样落在背景上：这一侧没有气泡
    # 从文字两侧往外扫，同色就继续：得到气泡的左右边
    $bl = [BubScan]::Edge($img, [Math]::Max(0, [int]($l.x0 - 3 * $dpi)), $y, -1, $c); $br = [BubScan]::Edge($img, [Math]::Min($img.Width - 1, [int]($l.x1 + 3 * $dpi)), $y, 1, $c)   # 注意：不能叫 $L，PowerShell 变量不分大小写，会把 $l 覆盖
    $best = @{ L = [Math]::Min($bl, $l.x0); R = [Math]::Max($br, $l.x1); color = $(if ($green) { 'self' } else { 'other' }) }
    break
  }
  $best
}
function Get-LineSpeaker([Drawing.Bitmap]$img, $l, [int]$cw, [double]$dpi, [int]$bgLum = -1) {
  $b = Get-Bubble $img $l $dpi $bgLum; $edge = [Math]::Max(90 * $dpi, 0.15 * $cw)
  if ($b) { $right = ($cw - $b.R) -lt $edge; $left = $b.L -lt $edge; $col = $b.color }
  else { $right = $l.x1 / $cw -gt 0.78; $left = $l.x0 / $cw -lt 0.30; $col = '' }
  $pos = if ($right -and -not $left) { 'self' } elseif ($left -and -not $right) { 'other' } else { '' }
  if ($script:WxSelfSide -eq 'left') { $pos = switch ($pos) { 'self' { 'other' } 'other' { 'self' } default { '' } } }
  # 质量记录：这一行是靠哪条路判断的（气泡位置+颜色一致 / 只有气泡位置 / 没找到气泡、看文字位置 / 只有颜色 / 两个矛盾 / 都判断不了）
  $path = if ($pos -and $col -and $pos -ne $col) { 'conflict' } elseif ($pos -and $col) { 'bubble+colour' } elseif ($pos) { if ($b) { 'bubble-side' } else { 'line-position' } } elseif ($col) { 'colour-only' } else { 'none' }
  if ($null -ne $script:SpkPath) { $script:SpkPath[$path] = [int]$script:SpkPath[$path] + 1 }; $script:LastSpkPath = $path
  if ($pos -and $col -and $pos -ne $col) { return 'unknown' }   # 两个信号矛盾：不确定
  if ($pos) { return $pos }; if ($col) { return $col }; 'unknown'
}
# 把认出来的行拼成消息：群聊里认出名字行；同一气泡的多行合并；名字行决定后面别人消息的发送方；时间条记为「显示时间」；引用框挂在上一条后面
function Join-ChatLines($items, [double]$dpi) {
  # 群聊发送者名：靠左行中起点最靠左的一簇（比气泡文字少缩进约 10 DIP）
  $left = @($items | Where-Object { $_.类 -eq '对方' -and -not $_.图片 })
  if ($left.Count -ge 2) {
    $minX = ($left | Measure-Object x0 -Minimum).Minimum
    if (@($left | Where-Object { $_.x0 - $minX -gt 6 * $dpi }).Count) { foreach ($e in $left) { if ($e.x0 - $minX -lt 4 * $dpi -and $e.文本.Length -le 20 -and $e.文本 -notmatch '[：:]') { $e.类 = '名字' } } }   # 「名字：原话」是引用框，不是名字行
  }
  # 按纵向顺序组装消息：同一气泡的多行合并；名字行决定后续对方消息的发送方；时间条记为“显示时间”
  $msgs = New-Object System.Collections.ArrayList; $who = '对方'; $shown = ''; $last = $null
  foreach ($e in ($items | Sort-Object y)) {
    switch ($e.类) {
      '时间' { $shown = $e.文本; $last = $null; continue }
      '名字' { $who = $e.文本; $last = $null; continue }
      default {
        # 引用框：紧跟在一条气泡下面、以「名字：」开头 → 是被回复的那条原话，挂在上一条后面写明「引用」。你这边：不是靠绿色气泡认出来的才算（你自己的绿气泡永远是你说的）；别人那边：灰色引用框看着像别人的灰气泡，也算
        if ($last -and -not $last.图片 -and -not $e.图片 -and ($e.路 -ne 'bubble+colour' -or ($e.类 -ne '我' -and $last.发送方 -ne '我')) -and $e.文本 -match '^\s*[^：:\s]{1,16}[：:]\s*\S' -and ($e.y - $last.yEnd) -lt 60 * $dpi) {
          $last.文本 += "（引用 $($e.文本.Trim())）"; $last | Add-Member -NotePropertyName 引用 -NotePropertyValue $true -Force; $last.yEnd = $e.y + 24 * $dpi; continue }
        $sender = if ($e.类 -eq '我') { '我' } elseif ($e.类 -eq '不确定') { '不确定' } else { $who }
        # 与上一行属于同一气泡（同一侧、间距小于 1.6 行高、都不是图片）→ 合并
        if ($last -and -not $e.图片 -and -not $last.图片 -and $last.发送方 -eq $sender -and ($e.y - $last.yEnd) -lt 34 * $dpi) {
          $last.文本 += $e.文本; $last.yEnd = $e.y + 24 * $dpi; continue }
        $last = [pscustomobject]@{ 发送方 = $sender; 文本 = $e.文本; 图片 = $e.图片; 显示时间 = $shown; yEnd = $e.y + 24 * $dpi; 图像 = $e.图像 }
        [void]$msgs.Add($last)
      }
    }
  }
  $msgs
}
# 识别一次：返回 @{ 会话 = 标题; 消息 = @(...); 列表 = @(...) }
#   消息：发送方（我 / 对方 / 群成员名）、文本、是否图片、显示时间（最近一条时间分隔条）
#   列表：会话名、预览、时间、是否未读
function Read-WeChat([IntPtr]$h, [Drawing.Bitmap]$full) {
  $w = $full.Width; $ht = $full.Height
  $dpi = [WinTools]::Dpi($h) / 96.0
  $lay = [Rec]::Layout($full); $bgLum = [int]$lay[3]
  $cl = [int]($w * $lay[0]); $ct = [int]($ht * $lay[1]); $cb = [int]($ht * $lay[2])

  # —— 当前会话标题：聊天区上方标题栏 ——
  $titleRect = New-Object Drawing.Rectangle $cl, 0, ([int](($w - $cl) * 0.6)), $ct   # 一整条：只裁 56 DIP 那么窄时认不出字（2026-11-03 深色模式、两个字的备注名）
  $title = ''
  if ($titleRect.Height -gt 10) {
    $tb = Crop $full $titleRect; $tl = @(Get-Lines (Invoke-Ocr $tb)); $tb.Dispose()
    # 标题在标题栏左侧、最靠上：取起点在左 40% 内、y 最小的一行（不能取“最高”的一行，标题区下沿可能压到聊天里的图片）
    $t0 = @($tl | Where-Object { $_.x0 -lt $titleRect.Width * 0.4 -and $_.y -ge $ct - 70 * $dpi } | Sort-Object y)[0]; if (-not $t0) { $t0 = @($tl | Where-Object { $_.x0 -lt $titleRect.Width * 0.4 } | Sort-Object y)[-1] }
    if ($t0) { $title = ($t0.文本 -replace '\s*[（(]\d+[)）]\s*$', '').Trim() }
  }

  # —— 聊天区 ——
  $chatRect = New-Object Drawing.Rectangle $cl, $ct, ($w - $cl), ($cb - $ct)
  $img = Crop $full $chatRect; $cw = $img.Width
  $lines = @(Get-Lines (Invoke-Ocr $img))
  $boxes = [Rec]::FindImages($img, 16, 14, [int](40 * $dpi * 1.8), $bgLum)
  $items = New-Object System.Collections.ArrayList
  foreach ($bx in $boxes) {
    $big = New-Object Drawing.Bitmap ($bx.Width * 2), ($bx.Height * 2); $gg = [Drawing.Graphics]::FromImage($big); $gg.InterpolationMode = 'HighQualityBicubic'
    $gg.DrawImage($img, (New-Object Drawing.Rectangle 0, 0, $big.Width, $big.Height), $bx, 'Pixel'); $gg.Dispose()
    $it = (@(Get-Lines (Invoke-Ocr $big)) | ForEach-Object 文本) -join ' / '; $big.Dispose()
    # $script:KeepImages 为真时附上图片裁剪（供值守看图用，调用方用完负责 Dispose）
    [void]$items.Add([pscustomobject]@{ y = $bx.Y; x0 = $bx.X; x1 = $bx.Right; 类 = $(if (($bx.X + $bx.Width / 2) / $cw -lt 0.5) { '对方' } else { '我' }); 文本 = $(if ($it) { "[图片] $it" } else { '[图片]' }); 图片 = $true
      图像 = $(if ($script:KeepImages) { Crop $img $bx } else { $null }) })
  }
  foreach ($l in $lines) {
    $cx = ($l.x0 + $l.x1) / 2; $cy = $l.y + $l.h / 2
    if ($boxes | Where-Object { $cx -ge $_.X -and $cx -le $_.Right -and $cy -ge $_.Y -and $cy -le $_.Bottom }) { continue }   # 图片里的字已单独识别
    $mid = $cx / $cw
    $k = if ([Math]::Abs($mid - 0.5) -lt 0.12 -and ($l.x1 - $l.x0) / $cw -lt 0.35 -and $l.文本 -match $script:TimeRx) { '时间' }
         else { switch (Get-LineSpeaker $img $l $cw $dpi $bgLum) { 'self' { '我' } 'other' { '对方' } default { '不确定' } } }
    [void]$items.Add([pscustomobject]@{ y = $l.y; x0 = $l.x0; x1 = $l.x1; 类 = $k; 文本 = $l.文本; 图片 = $false; 路 = $(if ($k -eq '时间') { '' } else { [string]$script:LastSpkPath }) })
  }
  $img.Dispose()
  $msgs = Join-ChatLines $items $dpi

  # —— 会话列表：导航栏（约 60 DIP）右侧到聊天区左边界 ——
  $navR = [int](60 * $dpi); $lt = [int](56 * $dpi)
  $listRect = New-Object Drawing.Rectangle $navR, $lt, ([Math]::Max(50, $cl - $navR - 8)), ($ht - $lt)
  $lb = Crop $full $listRect; $lw = $lb.Width
  $ll = @(Get-Lines (Invoke-Ocr $lb) | Sort-Object y)
  $badges = [Rec]::RedBadges($lb, 12, [int](24 * $dpi))
  $conv = New-Object System.Collections.ArrayList; $cur = $null
  foreach ($l in $ll) {
    if (-not $cur -or ($l.y - $cur.y) -gt 36 * $dpi) { $cur = [pscustomobject]@{ y = $l.y; 行 = New-Object System.Collections.ArrayList }; [void]$conv.Add($cur) }
    [void]$cur.行.Add($l)
  }
  $list = foreach ($c in $conv) {
    $tm = $c.行 | Where-Object { $_.x1 / $lw -gt 0.75 -and $_.文本 -match $script:TimeRx } | Select-Object -First 1
    $txt = @($c.行 | Where-Object { $_ -ne $tm } | Sort-Object y)
    if (-not $txt.Count) { continue }
    $unread = [bool]($badges | Where-Object { $_.Y -ge $c.y - 22 * $dpi -and $_.Y -le $c.y + 40 * $dpi -and $_.X -lt $lw * 0.45 })
    # 条目底色亮度（取条目右侧空白处）：用户当前所在会话在列表里有高亮底色，用来识别“原会话”
    $py = [int][Math]::Min($lb.Height - 1, $c.y + 14 * $dpi); $pc = $lb.GetPixel([int]($lw - 6 * $dpi), $py)
    # 点X/点Y：该条目在窗口内的点击位置（名字行稍下方、列表中部），供第 2 步点击使用
    [pscustomobject]@{ 会话 = $txt[0].文本; 预览 = (($txt | Select-Object -Skip 1 | ForEach-Object 文本) -join ' '); 时间 = $(if ($tm) { $tm.文本 } else { '' }); 未读 = $unread
                       点X = [int]($navR + $lw * 0.5); 点Y = [int]($lt + $c.y + 14 * $dpi); 底色 = [int](($pc.R * 299 + $pc.G * 587 + $pc.B * 114) / 1000); 选中 = $false }
  }
  $lb.Dispose()
  # 选中项 = 底色与其余条目中位数差别最大、且差值明显（> 6）的那一条
  $list = @($list)
  if ($list.Count -ge 2) {
    $med = ($list.底色 | Sort-Object)[[int]($list.Count / 2)]
    $sel = $list | Sort-Object { -[Math]::Abs($_.底色 - $med) } | Select-Object -First 1
    if ([Math]::Abs($sel.底色 - $med) -gt 6) { $sel.选中 = $true }
  }
  # 标题没认出来：用会话列表里选中的那一行的名字（打开着的就是它）；都没有才留空，之后整理时不写名字
  $titleFrom = 'title'; if (-not $title) { $sel = @($list | Where-Object 选中)[0]; if ($sel -and $sel.会话) { $title = ([string]$sel.会话 -replace '\s*[（(]\d+[)）]\s*$', '').Trim(); $titleFrom = 'list-row' } else { $titleFrom = 'none' } }
  @{ 会话 = $title; 消息 = @($msgs); 列表 = @($list); 版面 = $lay; 标题来源 = $titleFrom }
}