# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 标题识别测量（只在你说「可以测」以后手动跑；不在 跑测试.ps1 里）
# 做什么：把开着的微信按几种宽高摆一下、每种截一张，用秘书的 Read-WeChat 认一遍，只记数字（标题来源、诊断数字）。
# 不点、不按键、不滚动、不切聊天、不改微信设置；不碰剪贴板。可以放出 / 移动 / 改大小，最后（出错也一样）全部还原并核对。
# 你一碰鼠标或键盘就马上停下、还原。
# 结果（只有数字）：%TEMP%\secretary_title_measure\result.txt
# 截图：%TEMP%\secretary_title_measure\captures\ —— 修好识别后要在同样的截图上再测一次（-Again），之后用 -Cleanup 删掉。截图只在本机，不上传。
#   第一次：     powershell -NoProfile -ExecutionPolicy Bypass -File "<本文件>"
#   修好后再测： powershell -NoProfile -ExecutionPolicy Bypass -File "<本文件>" -Again
#   删掉截图：   powershell -NoProfile -ExecutionPolicy Bypass -File "<本文件>" -Cleanup
param([switch]$Again, [switch]$Cleanup)
$ErrorActionPreference = 'Stop'
$Work = Join-Path $env:TEMP 'secretary_title_measure'; $Cap = Join-Path $Work 'captures'; $Out = Join-Path $Work 'result.txt'
if ($Cleanup) { if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }; '截图和结果已删除'; return }
[void][IO.Directory]::CreateDirectory($Cap)
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\tests\lib_test_data.ps1"; $script:TestDataRoot = Use-TestDataFolder 'title_measure'   # 秘书的数据和设置都指向临时文件夹
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_原地读.ps1"
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class TM {
  [StructLayout(LayoutKind.Sequential)] public struct WP { public int len, flags, show; public int mx, my, xx, xy; public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] public struct RC { public int l, t, r, b; }
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WP p);
  [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr h, ref WP p);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RC r);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out PT p);
}
'@
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); $s }
# 只记数字：标题来源（title / list-row / none 这三个词之一）和诊断数字；不记任何认出来的文字
function Measure-Bmp($bmp, $hwnd, [string]$tag) {
  $r = Read-WeChat $hwnd $bmp; $d = $r.诊断
  '{0} | {1}x{2} | title={3} | title_lines={4} title_h={5} | lay={6} | list_rows={7} sel_diff={8} | msgs={9} | retry={10}' -f $tag, $bmp.Width, $bmp.Height, $r.标题来源, $d.title_lines, $d.title_h, ($d.lay -join '/'), $d.list_rows, $d.sel_diff, @($r.消息).Count, [string]$d.retry
}
$ps = @(Get-Process Weixin -ErrorAction SilentlyContinue); if (-not $ps.Count) { Say '微信没开着：没做任何事' | Out-Null; [IO.File]::WriteAllLines($Out, $lines); '微信没开着'; return }
$h = [WinTools]::LargestVisibleWindow([uint32[]]$ps.Id); if ($h -eq [IntPtr]::Zero) { $h = [Ghost2]::HiddenMain([uint32[]]$ps.Id, 400, 300) }
if ($h -eq [IntPtr]::Zero) { Say '没找到微信窗口：没做任何事' | Out-Null; [IO.File]::WriteAllLines($Out, $lines); return }

if ($Again) {   # 修好后：在第一次存下的同样截图上再认一遍（不动窗口）
  Say "再测 $((Get-Date).ToString('yyyy-MM-dd HH:mm'))（同一批截图）"
  foreach ($f in Get-ChildItem $Cap -Filter '*.png' | Sort-Object Name) { $b = [Drawing.Bitmap]::FromFile($f.FullName); try { Say (Measure-Bmp $b $h $f.BaseName) } finally { $b.Dispose() } }
  [IO.File]::WriteAllLines($Out.Replace('.txt', '_after.txt'), $lines, (New-Object Text.UTF8Encoding $true)); return
}

# —— 记下原样 ——
$wp0 = New-Object TM+WP; $wp0.len = 44; [void][TM]::GetWindowPlacement($h, [ref]$wp0)
$vis0 = [TM]::IsWindowVisible($h); $ico0 = [TM]::IsIconic($h); $rc0 = New-Object TM+RC; [void][TM]::GetWindowRect($h, [ref]$rc0)
$prev0 = [TM]::GetWindow($h, 3); $fg0 = [TM]::GetForegroundWindow(); $cur0 = New-Object TM+PT; [void][TM]::GetCursorPos([ref]$cur0)
Say "测量 $((Get-Date).ToString('yyyy-MM-dd HH:mm'))；开始时：可见=$vis0 最小化=$ico0 放置=$($wp0.show) 大小=$($rc0.r - $rc0.l)x$($rc0.b - $rc0.t) dpi=$([WinTools]::Dpi($h)) 微信在前台=$($fg0 -eq $h)"
'别碰鼠标和键盘，大约 1 分钟；一碰就会停下并还原。'
$t0 = Get-Date; while ([Ghost2]::IdleMs() -lt 3000 -and ((Get-Date) - $t0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 300 }   # 等你松手（按回车本身算一次输入）
$stopped = ''
try {
  if ([Ghost2]::IdleMs() -lt 3000) { throw '一直有输入，没开始' }
  if (-not $vis0 -or $ico0) { [void][TM]::ShowWindow($h, 4); Start-Sleep -Milliseconds 700 }   # 不激活地放出来
  $rc = New-Object TM+RC; [void][TM]::GetWindowRect($h, [ref]$rc); $W0 = $rc.r - $rc.l; $H0 = $rc.b - $rc.t; $X0 = $rc.l; $Y0 = $rc.t
  $sizes = @(, @($W0, $H0, 'cur')) + @(foreach ($w in 3000, 2400, 2000, 1700, 1500, 1300, 1150, 1000, 900, 800) { , @($w, $H0, "w$w") }) + @(foreach ($ht in 1700, 1300, 1000, 800) { , @([Math]::Min($W0, 2000), $ht, "h$ht") })
  $i = 0
  foreach ($s in $sizes) {
    $i++
    [void][TM]::SetWindowPos($h, [IntPtr]::Zero, $X0, $Y0, [int]$s[0], [int]$s[1], 0x14); Start-Sleep -Milliseconds 900   # NOZORDER | NOACTIVATE
    $r2 = New-Object TM+RC; [void][TM]::GetWindowRect($h, [ref]$r2); $cw = $r2.r - $r2.l; $ch = $r2.b - $r2.t
    for ($k = 1; $k -le $(if ($s[2] -eq 'cur') { 3 } else { 1 }); $k++) {
      if ([Ghost2]::IdleMs() -lt 1000) { throw "你动了（第 $i 步）" }
      $bmp = [Rec]::Window($h, $cw, $ch)
      try { $tag = '{0:00}_{1}_{2}' -f $i, $s[2], $k; $bmp.Save((Join-Path $Cap "$tag.png"), [Drawing.Imaging.ImageFormat]::Png); Say (Measure-Bmp $bmp $h $tag) | Out-Null } finally { $bmp.Dispose() }
      Start-Sleep -Milliseconds 300 }
  }
} catch { $stopped = [string]$_.Exception.Message; if ($stopped.Length -gt 80) { $stopped = $stopped.Substring(0, 80) } }
finally {
  [void][TM]::SetWindowPlacement($h, [ref]$wp0)
  if ($ico0) { [void][TM]::ShowWindow($h, 7) }
  if (-not $vis0) { [void][TM]::ShowWindow($h, 0) }
  if ($vis0 -and -not $ico0) { [void][TM]::SetWindowPos($h, [IntPtr]::Zero, $rc0.l, $rc0.t, $rc0.r - $rc0.l, $rc0.b - $rc0.t, 0x14) }
  if ($prev0 -ne [IntPtr]::Zero) { [void][TM]::SetWindowPos($h, $prev0, 0, 0, 0, 0, 0x13) }
  if ([TM]::GetForegroundWindow() -ne $fg0 -and $fg0 -ne [IntPtr]::Zero) { [void][TM]::SetForegroundWindow($fg0) }
  $cur1 = New-Object TM+PT; [void][TM]::GetCursorPos([ref]$cur1); $wp1 = New-Object TM+WP; $wp1.len = 44; [void][TM]::GetWindowPlacement($h, [ref]$wp1); $rc1 = New-Object TM+RC; [void][TM]::GetWindowRect($h, [ref]$rc1)
  Say "还原：可见=$([TM]::IsWindowVisible($h))（原 $vis0） 最小化=$([TM]::IsIconic($h))（原 $ico0） 放置=$($wp1.show)（原 $($wp0.show)） 位置大小一样=$(($rc1.l -eq $rc0.l) -and ($rc1.t -eq $rc0.t) -and ($rc1.r -eq $rc0.r) -and ($rc1.b -eq $rc0.b)) 层次一样=$([TM]::GetWindow($h, 3) -eq $prev0) 前台一样=$([TM]::GetForegroundWindow() -eq $fg0) 鼠标没动=$(($cur1.x -eq $cur0.x) -and ($cur1.y -eq $cur0.y))" | Out-Null
  if ($stopped) { Say "停下：$stopped" | Out-Null }
  [IO.File]::WriteAllLines($Out, $lines, (New-Object Text.UTF8Encoding $true))
}
$lines
"结果在：$Out"
