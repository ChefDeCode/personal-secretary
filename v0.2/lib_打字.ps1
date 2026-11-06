# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_打字.ps1 — 在后台往输入框里打一段字，并严格核对（不对就删干净，换下一种打法）。
# 打法依次：1) WM_CHAR  2) WM_IME_CHAR  3) 按键三连（KEYDOWN VK_PACKET / WM_CHAR / KEYUP），全部用 W 版 PostMessage。
# 每种打完：输入框 OCR（原图 + 加白边 / 缩放几种再认）里要有一行和要打的字「完全一样」才算对；不对就按打了几个字删几下，
# 再用像素（和打字前的输入框比）+ OCR 确认删干净了，才试下一种。删不干净就停，不再试。
# 依赖调用方已加载：lib_识别（Rec / Crop / Invoke-Ocr / Get-Lines）、lib_找聊天（Read-Zoomed）
if (-not ('TypeW' -as [type])) { Add-Type @'
using System; using System.Runtime.InteropServices;
public static class TypeW {
  [DllImport("user32.dll", EntryPoint = "PostMessageW")] static extern bool Post(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static void Chars(IntPtr h, string s) { foreach (char c in s) { Post(h, 0x0102, (IntPtr)c, (IntPtr)1); System.Threading.Thread.Sleep(15); } }        // WM_CHAR
  public static void Ime(IntPtr h, string s) { foreach (char c in s) { Post(h, 0x0286, (IntPtr)c, (IntPtr)1); System.Threading.Thread.Sleep(15); } }          // WM_IME_CHAR
  public static void Triplet(IntPtr h, string s) { foreach (char c in s) { Post(h, 0x0100, (IntPtr)0xE7, (IntPtr)1); Post(h, 0x0102, (IntPtr)c, (IntPtr)1); Post(h, 0x0101, (IntPtr)0xE7, unchecked((IntPtr)(int)0xC0000001)); System.Threading.Thread.Sleep(15); } }
  public static void Key(IntPtr h, int vk, int n) { for (int i = 0; i < n; i++) { Post(h, 0x0100, (IntPtr)vk, (IntPtr)1); Post(h, 0x0101, (IntPtr)vk, unchecked((IntPtr)(int)0xC0000001)); System.Threading.Thread.Sleep(15); } }
  public static void Back(IntPtr h, int n) { for (int i = 0; i < n; i++) { Post(h, 0x0100, (IntPtr)0x08, (IntPtr)0x000E0001); Post(h, 0x0101, (IntPtr)0x08, unchecked((IntPtr)(int)0xC00E0001)); System.Threading.Thread.Sleep(20); } }
}
'@ }
function Get-TypeNorm($s) { ([string]$s -replace '\s', '') }
# 核对用的「正文」：去掉空白和标点符号（OCR 认不准全角标点）；汉字、字母、数字必须一个不差
function Get-TypeCore($s) { ([string]$s -replace '[\s\p{P}\p{S}]', '') }
# 两张输入框截图有多少像素明显不一样（0~1）
# 核对用的「骨架」：按字（含表情）逐个看；汉字、字母、数字原样保留，标点符号和表情各占一个「?」位置（字形可以认不准，但位置和个数必须对）；空白去掉
function Get-TypeSlots([string]$s) {
  $e = [Globalization.StringInfo]::GetTextElementEnumerator($s); $sb = New-Object Text.StringBuilder
  while ($e.MoveNext()) { $g = [string]$e.Current; if ($g -match '^\s+$') { continue }; if ($g.Length -eq 1 -and $g -match '^[\p{L}\p{Nd}]$') { [void]$sb.Append($g) } else { [void]$sb.Append('?') } }
  $sb.ToString() }
# 认出来的字对不对：骨架完全一样（汉字字母数字一个不差、标点和表情的个数和位置都一样、总长度一样）。
# 唯一放宽：认字软件看不见表情——要发的字里有表情、认出来的正好少了这几个表情的位置、而且输入框像素确实变了，才算对
function Test-TypedMatch($cands, [string]$text, [bool]$pixelChanged) {
  $want = Get-TypeSlots $text
  $noEmoji = New-Object Text.StringBuilder; $e = [Globalization.StringInfo]::GetTextElementEnumerator($text); while ($e.MoveNext()) { $g = [string]$e.Current; if ($g -match '^\s+$') { continue }; if ($g.Length -ge 2 -or $g -match '^\p{So}$') { continue }; [void]$noEmoji.Append($(if ($g -match '^[\p{L}\p{Nd}]$') { $g } else { '?' })) }
  $hasEmoji = $noEmoji.Length -ne $want.Length
  foreach ($c in @($cands)) { $s = Get-TypeSlots $c; if ($s -ceq $want) { return $true }; if ($hasEmoji -and $pixelChanged -and $s -ceq $noEmoji.ToString()) { return $true } }
  $false }function Get-PixDiff([Drawing.Bitmap]$a, [Drawing.Bitmap]$b) {
  $n = 0; $d = 0; for ($y = 0; $y -lt [Math]::Min($a.Height, $b.Height); $y += 2) { for ($x = 0; $x -lt [Math]::Min($a.Width, $b.Width); $x += 2) { $n++; $p = $a.GetPixel($x, $y); $q = $b.GetPixel($x, $y); if ([Math]::Abs(($p.R + $p.G + $p.B) - ($q.R + $q.G + $q.B)) -gt 90) { $d++ } } }
  if ($n) { $d / $n } else { 0 } }
function Get-InputShot([IntPtr]$h, [Drawing.Rectangle]$inRect) { $r = [WinTools]::Rect($h); $full = [Rec]::Window($h, $r.R - $r.L, $r.B - $r.T); $ib = Crop $full $inRect; $full.Dispose(); $ib }
# 输入框里认出的字：原图一行一行 + 几种变换再认；返回所有候选（去空白）
function Read-InputCandidates([Drawing.Bitmap]$ib) {
  $plain = (@(Get-Lines (Invoke-Ocr $ib)) | Where-Object { $_.文本 -notmatch '^\s*(发送|发送\(S\)|Send)\s*$' } | ForEach-Object 文本) -join ''   # 微信输入区里的「发送」按钮不算输入框里的字
  @(@(Get-TypeNorm $plain) + @(Read-Zoomed $ib (New-Object Drawing.Rectangle 0, 0, $ib.Width, $ib.Height) | ForEach-Object { Get-TypeNorm $_ })) | Where-Object { $_ } }
function Get-EditDistance([string]$a, [string]$b) {
  $prev = 0..$b.Length
  for ($i = 1; $i -le $a.Length; $i++) { $cur = @($i) + @(0) * $b.Length
    for ($j = 1; $j -le $b.Length; $j++) { $c = if ($a[$i - 1] -ceq $b[$j - 1]) { 0 } else { 1 }; $cur[$j] = [Math]::Min([Math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $c) }
    $prev = $cur }
  $prev[$b.Length] }

# 返回 @{ ok; method; tries = @(每种打法的数字); clean }
function Invoke-TypeVerified([IntPtr]$h, [string]$text, [Drawing.Rectangle]$inRect, [int]$clickX, [int]$clickY, [string[]]$methods = @('char', 'ime', 'triplet')) {
  $want = Get-TypeNorm $text; $units = $text.Length; $elems = (New-Object Globalization.StringInfo $text).LengthInTextElements
  $pre = Get-InputShot $h $inRect; $tries = New-Object System.Collections.ArrayList; $script:TypeTries = $tries   # 半路停下（比如微信抢了前台）时，发送那边也能把已经做过的几步记下来
  # 每个小步骤都标出来（只记名字，不在半路停）：前台一变，记录里就知道是哪一步之后变的；微信抢了前台就先把打进去的字删掉再停
  $mk = { param($s) if ('FgTrace' -as [type]) { [FgTrace]::StepName = $s } }
  $grab = { ('FgTrace' -as [type]) -and [FgTrace]::WeChatTookFront }
  foreach ($m in $methods) {
    & $mk "click:$m"; [Rec]::Click($h, $clickX, $clickY); Start-Sleep -Milliseconds 300
    & $mk "keys:$m"; switch ($m) { 'char' { [TypeW]::Chars($h, $text) } 'ime' { [TypeW]::Ime($h, $text) } 'triplet' { [TypeW]::Triplet($h, $text) } }
    Start-Sleep -Milliseconds 700; & $mk "check:$m"
    if (& $grab) {   # 微信抢了前台：先把这次打进去的删掉（输入前是空的，不会删到你的字），确认删干净，再停
      [TypeW]::Back($h, $elems + 2); Start-Sleep -Milliseconds 400; $ib = Get-InputShot $h $inRect; $cl2 = ((Get-PixDiff $pre $ib) -le 0.002) -and -not (@(Read-InputCandidates $ib) | Where-Object { $_ }); $ib.Dispose()
      [void]$tries.Add([ordered]@{ method = $m; grabbed = $true; deleted_clean = $cl2 }); $pre.Dispose(); return @{ ok = $false; method = $m; tries = $tries; clean = $cl2; grabbed = $true } }
    $ib = Get-InputShot $h $inRect; $px = Get-PixDiff $pre $ib; $cands = @(Read-InputCandidates $ib); $ib.Dispose()
    $exact = Test-TypedMatch $cands $text ($px -gt 0.002)
    $best = if ($cands.Count) { ($cands | Sort-Object { Get-EditDistance $_ $want } | Select-Object -First 1) } else { '' }
    $t = [ordered]@{ method = $m; posted = $units; ocr_chars = $best.Length; edit = $(if ($best) { Get-EditDistance $best $want } else { $want.Length }); pixel_changed = ($px -gt 0.002); exact = $exact; deleted_clean = $null }
    [void]$tries.Add($t); if ($exact) { $pre.Dispose(); return @{ ok = $true; method = $m; tries = $tries; clean = $true } }
    # 不对：删掉我们打的（打了几个字删几下，多删两下防漏；输入前是空的，所以不会删到你的字）
    & $mk "back:$m"; [TypeW]::Back($h, $elems + 2); Start-Sleep -Milliseconds 500
    $ib = Get-InputShot $h $inRect; $px2 = Get-PixDiff $pre $ib; $left = @(Read-InputCandidates $ib) | Where-Object { $_.Length -gt 0 } | Select-Object -First 1; $ib.Dispose()
    $t.deleted_clean = ($px2 -le 0.002 -and -not $left)
    if (-not $t.deleted_clean) { $pre.Dispose(); return @{ ok = $false; method = $m; tries = $tries; clean = $false } }
  }
  $pre.Dispose(); @{ ok = $false; method = ''; tries = $tries; clean = $true }
}

# 输入框是不是空的：认不出字，而且那块颜色基本一样（没有字的笔画）
function Test-InputEmpty([Drawing.Bitmap]$ib) {
  if (@(Read-InputCandidates $ib | Where-Object { $_ -and $_ -notmatch '^(发送|Send)$' }).Count) { return $false }
  $n = 0; $s = 0.0; $s2 = 0.0; for ($y = 2; $y -lt $ib.Height - 2; $y += 3) { for ($x = 2; $x -lt $ib.Width - 2; $x += 3) { $p = $ib.GetPixel($x, $y); $l = ($p.R + $p.G + $p.B) / 3.0; $n++; $s += $l; $s2 += $l * $l } }
  if (-not $n) { return $true }; $m = $s / $n; ($s2 / $n - $m * $m) -lt 60 }
# 清空输入框（只有你在卡片上点了「替换后发送」才用）：点输入框，往下到最后一行、到行尾，再一下一下地删；每删 10 下看一次空了没有。
# 最多删「认出的字数 + 20」下；删不干净就停，绝不在剩下的字后面接着打
function Clear-InputBox([IntPtr]$h, [Drawing.Rectangle]$inRect, [int]$clickX, [int]$clickY, [int]$guessLen) {
  [Rec]::Click($h, $clickX, $clickY); Start-Sleep -Milliseconds 250
  [TypeW]::Key($h, 0x28, 30); [TypeW]::Key($h, 0x23, 1)
  # 先删「认出的字数 + 20」下；认字可能少数了（框里放不下、滚出去的字），所以之后只要每删 10 下框里还在变，就接着删；删了没变化就停（最多 1000 下）
  $max = $guessLen + 20; $done = 0; $prev = Get-InputShot $h $inRect
  while ($done -lt 1000) { [TypeW]::Back($h, 10); $done += 10; Start-Sleep -Milliseconds 250
    $ib = Get-InputShot $h $inRect; if (Test-InputEmpty $ib) { $ib.Dispose(); $prev.Dispose(); return @{ ok = $true; presses = $done } }
    $changed = (Get-PixDiff $prev $ib) -gt 0.0005; $prev.Dispose(); $prev = $ib
    if ($done -ge $max -and -not $changed) { break } }
  $prev.Dispose(); @{ ok = $false; presses = $done } }