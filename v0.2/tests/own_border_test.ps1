# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 秘书「在想」的 7 秒里，秘书自己窗口周围有没有亮框：模拟「在想」（和真的一样写 state.json），对比窗口四周一圈像素（只比颜色数字，不存截图）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"
Add-Type -AssemblyName System.Drawing
Add-Type 'using System; using System.Runtime.InteropServices; public static class OB { [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; } [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h); [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h); }'
$sp = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'v0.2\\秘书\.ps1' } | Select-Object -First 1
$h = (Get-Process -Id $sp.ProcessId).MainWindowHandle
if ($h -eq [IntPtr]::Zero -or -not [OB]::IsWindowVisible($h) -or [OB]::IsIconic($h)) { 'secretary main window is not on screen; cannot check its frame'; exit }
$r = New-Object OB+R; [void][OB]::GetWindowRect($h, [ref]$r)
function Ring { $pad = 10; $x0 = $r.L - $pad; $y0 = $r.T - $pad; $w = $r.Rt - $r.L + 2 * $pad; $hh = $r.B - $r.T + 2 * $pad
  $b = New-Object Drawing.Bitmap $w, $hh; $g = [Drawing.Graphics]::FromImage($b); $g.CopyFromScreen($x0, $y0, 0, 0, $b.Size); $g.Dispose()
  $px = @(); for ($i = 0; $i -lt $w; $i += 6) { foreach ($y in 2, 12, ($hh - 13), ($hh - 3)) { $px += $b.GetPixel($i, $y).ToArgb() } }; for ($j = 0; $j -lt $hh; $j += 6) { foreach ($x in 2, 12, ($w - 13), ($w - 3)) { $px += $b.GetPixel($x, $j).ToArgb() } }; $b.Dispose(); , $px }
# 不能叫 Diff：那是自带的 Compare-Object 简写，会盖住这个函数（以前一直算出 0）
function Get-RingDiff($a, $b) { $n = 0; for ($i = 0; $i -lt $a.Count; $i++) { $c1 = [Drawing.Color]::FromArgb($a[$i]); $c2 = [Drawing.Color]::FromArgb($b[$i]); if ([Math]::Abs($c1.R - $c2.R) + [Math]::Abs($c1.G - $c2.G) + [Math]::Abs($c1.B - $c2.B) -gt 40) { $n++ } }; [Math]::Round(100.0 * $n / $a.Count, 1) }
$before = Ring
$state = Join-Path $script:DataDir 'state.json'; [double]$maxDiff = 0; $border = 0
for ($k = 0; $k -lt 14; $k++) { Set-Lit $state 3; Start-Sleep -Milliseconds 500; $now = Ring; $maxDiff = [Math]::Max($maxDiff, [double](Get-RingDiff $before $now)); $border = [Math]::Max($border, @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match '07_AI边框特效' }).Count) }
Set-Lit $state 1
"window on screen: yes; ring pixels changed during 7 s think (max %): $maxDiff; border effect processes: $border"
"own_border_test: $(if ($maxDiff -lt 3 -and $border -eq 0) { 'PASS' } else { 'FAIL' })"
