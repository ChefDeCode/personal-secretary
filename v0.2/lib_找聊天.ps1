# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_找聊天.ps1 — 在后台（桌面 2）的会话列表里找一个聊天：本机 OCR 读列表 + 发给窗口的滚轮消息（不动你的鼠标）。
# 以前的问题：刚打开 / 刚挪过的窗口还没画好就读，第一屏读到 0 行；滚了也不看列表动没动，滚不动也照样「翻」满 15 屏。
# 现在：先等窗口画好（列表连续两次读到一样的、至少 2 行）；每翻一屏核对列表真的动了，动不了就换小步再试，再动不了说明到底了，停下。
# 依赖调用方已加载：lib_v2、lib_识别（Rec / Read-WeChat / WinTools）
if (-not ('ListWheel' -as [type])) { Add-Type @'
using System; using System.Runtime.InteropServices;
public static class ListWheel {
  [DllImport("user32.dll", EntryPoint = "PostMessageW")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref PT p); struct PT { public int X, Y; }
  public static void Wheel(IntPtr h, int x, int y, int delta) { var p = new PT { X = x, Y = y }; ClientToScreen(h, ref p); PostMessage(h, 0x020A, (IntPtr)((delta & 0xFFFF) << 16), (IntPtr)(((p.Y & 0xFFFF) << 16) | (p.X & 0xFFFF))); }
}
'@ }
function Get-ListSnap([IntPtr]$h) {   # 读列表；这一张截图留着（$script:ListBmp），近似的名字要放大再认一次
  $r = [WinTools]::Rect($h); $b = [Rec]::Window($h, $r.R - $r.L, $r.B - $r.T); $x = Read-WeChat $h $b
  if ($script:ListBmp) { $script:ListBmp.Dispose() }; $script:ListBmp = $b; $x }
# 两个名字像不像（OCR 认错一两个字的程度）：长度差不超过 1，且同位置一样的字至少一半
function Test-NameNear([string]$a, [string]$b) { $a = $a -replace '\s', ''; $b = $b -replace '\s', ''; if (-not $a -or -not $b -or [Math]::Abs($a.Length - $b.Length) -gt 1) { return $false }
  $n = [Math]::Min($a.Length, $b.Length); $same = 0; for ($i = 0; $i -lt $n; $i++) { if ($a[$i] -eq $b[$i]) { $same++ } }; $same * 2 -ge [Math]::Max($a.Length, $b.Length) }
# 把截图里某一块换几种方式再 OCR（加白边、缩到 0.75、放大 1.5 / 3 倍）：小字认错时，换个样子往往就认对了；返回所有认出的行
function Read-Zoomed([Drawing.Bitmap]$src, [Drawing.Rectangle]$rc) {
  $rc = [Drawing.Rectangle]::Intersect($rc, (New-Object Drawing.Rectangle 0, 0, $src.Width, $src.Height)); if ($rc.Width -lt 4 -or $rc.Height -lt 4) { return @() }
  foreach ($v in @(@(1.0, 40), @(0.75, 20), @(1.5, 40), @(3.0, 0))) {
    $k = $v[0]; $pad = $v[1]; $big = New-Object Drawing.Bitmap ([int]($rc.Width * $k) + 2 * $pad), ([int]($rc.Height * $k) + 2 * $pad); $g = [Drawing.Graphics]::FromImage($big)
    $g.Clear([Drawing.Color]::White); $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($src, (New-Object Drawing.Rectangle $pad, $pad, ([int]($rc.Width * $k)), ([int]($rc.Height * $k))), $rc, 'Pixel'); $g.Dispose()
    @(Get-Lines (Invoke-Ocr $big) | ForEach-Object { [string]$_.文本 }); $big.Dispose() } }
function Get-ListSig($s) { (@($s.列表) | ForEach-Object { ([string]$_.会话 -replace '\s', '') }) -join '|' }

# 返回 @{ item; snap; pages; moved; waits; rows0; why; back }；back 是把列表滚回原处的脚本块
function Find-ChatInList([IntPtr]$h, [string]$conv, [scriptblock]$same, [int]$maxPages = 25) {
  # 1) 等窗口画好：最多 3 秒
  $waits = 0; $prev = $null; $s = $null
  for ($i = 0; $i -lt 15; $i++) {
    $s = Get-ListSnap $h; $sig = Get-ListSig $s
    if (@($s.列表).Count -ge 2 -and $sig -eq $prev) { break }
    $prev = $sig; $waits++; Start-Sleep -Milliseconds 200
  }
  $rows0 = @($s.列表).Count
  # 先找完全一样的；没有就把「像」的那几行放大 3 倍再认一次，认出来完全一样才算（绝不按「像」来点）
  $dpiZ = [WinTools]::Dpi($h) / 96.0
  $hit = { param($snap)
    $x = @($snap.列表) | Where-Object { & $same $_.会话 $conv } | Select-Object -First 1; if ($x) { return $x }
    foreach ($it in @($snap.列表 | Where-Object { Test-NameNear $_.会话 $conv })) {
      $rc = New-Object Drawing.Rectangle 0, ([int]($it.点Y - 26 * $dpiZ)), ([int]($script:ListBmp.Width * 0.32)), ([int](44 * $dpiZ))
      if (@(Read-Zoomed $script:ListBmp $rc) | Where-Object { & $same $_ $conv }) { $script:ZoomHits++; return $it } } }   # 不用 GetNewClosure：要看到本函数里的变量和 $script:ListBmp
  $item = & $hit $s
  $r0 = [WinTools]::Rect($h); $w0 = $r0.R - $r0.L; $ht0 = $r0.B - $r0.T; $b0 = [Rec]::Window($h, $w0, $ht0); $lay0 = [Rec]::Layout($b0); $b0.Dispose(); $dpi0 = [WinTools]::Dpi($h) / 96.0
  $lx = [int]((60 * $dpi0 + $w0 * $lay0[0]) / 2); $ly = [int]($ht0 * 0.55)
  $state = @{ notches = 0 }; $back = { for ($k = 0; $k -lt $state.notches; $k++) { [ListWheel]::Wheel($h, $lx, $ly, 120); Start-Sleep -Milliseconds 30 } }.GetNewClosure()
  if ($item) { return @{ item = $item; snap = $s; pages = 0; moved = 0; waits = $waits; rows0 = $rows0; why = ''; back = $back } }
  # 2) 往下翻：每屏 3 格；列表没动就先多等一下再看，还不动就换成一格一格地滚，再不动就是到底了
  $pages = 0; $moved = 0; $sig = Get-ListSig $s; $why = 'not-found'
  while ($pages -lt $maxPages) {
    $pages++; [ListWheel]::Wheel($h, $lx, $ly, -360); $state.notches += 3; Start-Sleep -Milliseconds 450
    $s = Get-ListSnap $h; $n = Get-ListSig $s
    if ($n -eq $sig) { Start-Sleep -Milliseconds 500; $s = Get-ListSnap $h; $n = Get-ListSig $s }
    if ($n -eq $sig) { for ($k = 0; $k -lt 3; $k++) { [ListWheel]::Wheel($h, $lx, $ly, -120); Start-Sleep -Milliseconds 120 }; $state.notches += 3; Start-Sleep -Milliseconds 400; $s = Get-ListSnap $h; $n = Get-ListSig $s }
    if ($n -eq $sig) { $why = $(if ($moved) { 'list-end' } else { 'no-scroll' }); break }
    $moved++; $sig = $n
    $item = & $hit $s; if ($item) { $why = ''; break }
  }
  @{ item = $item; snap = $s; pages = $pages; moved = $moved; waits = $waits; rows0 = $rows0; why = $why; back = $back }
}

# 打开后核对聊天标题：完全一样才算；读出来「像」时，把标题那块换几种方式再认一次（认出完全一样才算）。刚点开时可能还没画好：最多看 4 次
function Confirm-ChatTitle([IntPtr]$h, [string]$conv, [scriptblock]$same, [int]$tries = 4) {
  for ($i = 0; $i -lt $tries; $i++) {
    $s = Get-ListSnap $h; if (& $same $s.会话 $conv) { return @{ ok = $true; snap = $s; tries = $i + 1 } }
    $script:TitleRead = @{ len = ([string]$s.会话).Length; near = [bool](Test-NameNear $s.会话 $conv); want_len = $conv.Length; list_rows = @($s.列表).Count }   # 只记数字：标题读出几个字、像不像、列表几行
    if ($true) {   # 读出来不一样（或者没读出来）：把标题那块换几种方式再认，认出完全一样才算
      $b = $script:ListBmp; $lay = [Rec]::Layout($b); $dpi = [WinTools]::Dpi($h) / 96.0; $cl = [int]($b.Width * $lay[0]); $ct = [int]($b.Height * $lay[1])
      $rc = New-Object Drawing.Rectangle $cl, ([int][Math]::Max(0, $ct - 56 * $dpi)), ([int](($b.Width - $cl) * 0.6)), ([int][Math]::Min($ct, 56 * $dpi))
      if (@(Read-Zoomed $b $rc) | Where-Object { & $same ($_ -replace '\s*[（(]\d+[)）]\s*$', '') $conv }) { $script:ZoomHits++; return @{ ok = $true; snap = $s; tries = $i + 1 } }
    }
    Start-Sleep -Milliseconds 400
  }
  @{ ok = $false; snap = $s; tries = 4 }
}