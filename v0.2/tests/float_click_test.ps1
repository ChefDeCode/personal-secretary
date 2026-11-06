# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 浮窗按钮回归测试（真实鼠标 SendInput，只点秘书自己的窗口）：提醒卡 好的 / 稍后→1小时 / 不用再提醒、早上简报 好的、勿扰开关、输入框、×
$ErrorActionPreference = 'Stop'
$v2 = (Split-Path $PSScriptRoot -Parent); $d = "$v2\data"; $cfgF = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config.json')
. "$PSScriptRoot\float_hit.ps1" -KeepOpen *> $null
. "$PSScriptRoot\lib_测试输入.ps1"   # 真实点击都经过保护   # 借用 FH 类型和 MiniH（会打开一次浮窗）
$ev = [Threading.EventWaitHandle]::OpenExisting('Local\SecretaryPanelToggle'); if (-not ([FH]::GetWindowLong((MiniH), -20) -band 0x20)) { [void]$ev.Set(); Start-Sleep -Milliseconds 700 }   # 按实际状态：开着就先关上
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RM {
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public MI mi; }   // 必须正好 40 字节（x64），多了 SendInput 会直接失败
  [StructLayout(LayoutKind.Sequential)] struct MI { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int size);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; } [DllImport("user32.dll")] public static extern bool GetCursorPos(out P p);
  public static uint Click(int x, int y) { SetCursorPos(x, y); System.Threading.Thread.Sleep(80); var a = new INPUT[2]; a[0].type = 0; a[0].mi.flags = 2; a[1].type = 0; a[1].mi.flags = 4; return SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
}
'@
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$p0 = New-Object RM+P; [void][RM]::GetCursorPos([ref]$p0)
# 测试数据：3 张虚构的提醒卡（不含任何真实内容），保留原来的状态以便恢复
$stF = "$d\reminders_state.json"; $orig = Get-Content $stF -Raw
$s = $orig | ConvertFrom-Json; $cards = @(1..3 | ForEach-Object { [pscustomobject]@{ id = "test|$_"; item = "test-item-$_"; text = "测试提醒 $_"; ts = (Get-Date).ToString('s'); important = $false; parts = @() } })
$cards += [pscustomobject]@{ id = 'brief|test'; item = 'brief'; text = '测试简报'; ts = (Get-Date).ToString('s'); important = $false; parts = @() }; $s.active = @(@($s.active) + $cards); [IO.File]::WriteAllText($stF, ($s | ConvertTo-Json -Depth 6 -Compress))
New-Item -ItemType File -Force "$d\float_test_on" | Out-Null; Remove-Item "$d\float_rects.json" -ErrorAction SilentlyContinue
function Rects { Start-Sleep -Milliseconds 700; (Get-Content "$d\float_rects.json" -Raw -Encoding UTF8 | ConvertFrom-Json) }
function ClickEl($rects, $pred) { $e = @($rects.items | Where-Object $pred)[0]; if (-not $e) { throw [TestAbort]::new('安全中止：要点的按钮没找到') }; $h = MiniH; $Q = New-Object FH+R; [void][FH]::GetWindowRect($h, [ref]$Q); Invoke-TestClick ([int]($Q.L + $e.x * $rects.dpr)) ([int]($Q.T + $e.y * $rects.dpr)); $true }
function State { Get-Content $stF -Raw | ConvertFrom-Json }
try {
  # 路径 1：真实鼠标点屏幕边的线（命中窗口在边缘线进程里，是秘书自己的窗口）
  $ep = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match '边缘线\.ps1' } | Select-Object -First 1).ProcessId
  $hit = [FH]::Of($ep) | Where-Object { $rr = New-Object FH+R; [void][FH]::GetWindowRect($_, [ref]$rr); ($rr.Rt - $rr.L) -lt 120 -and ($rr.B - $rr.T) -gt 200 } | Select-Object -First 1
  $hr = New-Object FH+R; [void][FH]::GetWindowRect($hit, [ref]$hr); Invoke-TestClick ([int](($hr.L + $hr.Rt) / 2)) ([int](($hr.T + $hr.B)) / 2); Start-Sleep -Milliseconds 1200; "   (input events sent so far: $([TIn]::Sent))"
  $h = MiniH; Assert (-not ([FH]::GetWindowLong($h, -20) -band 0x20)) "edge-line click opened the float and it takes clicks"
  # 页面要拿到新的提醒数据：等浮窗刷新（每 2 秒）
  Start-Sleep -Milliseconds 2300; $Q = Rects
  Assert (@($Q.items | Where-Object { $_.card -like 'test|*' -and $_.t -eq '好的' }).Count -eq 3) "reminder cards rendered: $(@($Q.items | Where-Object { $_.t -eq '好的' }).Count) cards (3 test cards)"
  # 好的（测试卡 1）——按卡片顺序：原来的简报在前，测试卡在后
  $n0 = @((State).active).Count; [void](ClickEl $Q { $_.card -eq 'test|1' -and $_.t -eq '好的' }); Start-Sleep -Milliseconds 900
  Assert (-not (@((State).active) | Where-Object id -eq 'test|1')) "好的 dismissed the card (cards $n0 → $(@((State).active).Count))"
  # 稍后 → 1 小时（测试卡 2，现在是第 2 张）
  $Q = Rects; [void](ClickEl $Q { $_.sel -eq '.rem .lt' -and $_.card -eq 'test|2' })
  $Q = Rects; $sub = @($Q.items | Where-Object { $_.sel -eq '.rem [data-rem]' -and $_.t -eq '1 小时' })
  Assert ($sub.Count -ge 1) "稍后 shows 1 小时 / 明天"
  [void](ClickEl $Q { $_.card -eq 'test|2' -and $_.t -eq '1 小时' }); Start-Sleep -Milliseconds 900
  $st = State; Assert (-not (@($st.active) | Where-Object id -eq 'test|2') -and $st.snooze.'test|2') "稍后 1 小时 rescheduled the card (until $(if ($st.snooze.'test|2') { ([datetime]$st.snooze.'test|2').ToString('HH:mm') }))"
  # 不用再提醒（测试卡 3）
  $Q = Rects; [void](ClickEl $Q { $_.card -eq 'test|3' -and $_.t -eq '不用再提醒' }); Start-Sleep -Milliseconds 900
  $st = State; Assert ($st.muted.'test-item-3' -and -not (@($st.active) | Where-Object id -eq 'test|3')) "不用再提醒 stopped that reminder"
  # 原来那张傍晚出现的早上简报：好的
  $Q = Rects; $had = @($Q.items | Where-Object { $_.card -like 'brief|*' -and $_.t -eq '好的' }).Count
  if ($had) { [void](ClickEl $Q { $_.card -like 'brief|*' -and $_.t -eq '好的' }); Start-Sleep -Milliseconds 900 }
  Assert (-not (@((State).active) | Where-Object { $_.id -like 'brief|*' })) "morning brief card dismissed with 好的"
  # 勿扰开关：点两次，恢复原样
  $dnd0 = [bool](Get-Content $cfgF -Raw -Encoding UTF8 | ConvertFrom-Json).dnd
  $Q = Rects; [void](ClickEl $Q { $_.sel -eq '#dnd' }); Start-Sleep -Milliseconds 700; $dnd1 = [bool](Get-Content $cfgF -Raw -Encoding UTF8 | ConvertFrom-Json).dnd
  [void](ClickEl $Q { $_.sel -eq '#dnd' }); Start-Sleep -Milliseconds 700; $dnd2 = [bool](Get-Content $cfgF -Raw -Encoding UTF8 | ConvertFrom-Json).dnd
  Assert ($dnd1 -ne $dnd0 -and $dnd2 -eq $dnd0) "勿扰 toggle responds (and is back to its original value)"
  # 输入框：点一下拿到焦点
  [void](ClickEl $Q { $_.sel -eq '.ask input' }); $Q2 = Rects; Assert ($Q2.active -eq 'INPUT') "input box takes focus on click"
  # 列表行和「打开完整窗口」：只检查点击会落在浮窗上（真点会去请 Claude 写回复 / 弹出主窗口）
  $h = MiniH; $Q = New-Object FH+R; [void][FH]::GetWindowRect($h, [ref]$Q)
  $tg = @($Q2.items | Where-Object { $_.sel -in 'button.row', '#full' }); $okHit = 0
  foreach ($e in $tg) { $p = New-Object FH+P; $p.X = [int]($Q.L + $e.x * $Q2.dpr); $p.Y = [int]($Q.T + $e.y * $Q2.dpr); if ([FH]::GetAncestor([FH]::WindowFromPoint($p), 2) -eq $h) { $okHit++ } }
  Assert ($okHit -eq $tg.Count -and $tg.Count -ge 1) "list rows and 打开完整窗口 are hit-testable ($okHit/$($tg.Count))"
  # ×：收起
  [void](ClickEl $Q2 { $_.sel -eq '#close' }); Start-Sleep -Milliseconds 800
  Assert ([FH]::GetWindowLong((MiniH), -20) -band 0x20) "× closes the float (back to click-through)"
  # 路径 2：和托盘、提醒到达后打开一样的入口（同一个开关函数）
  [void]$ev.Set(); Start-Sleep -Milliseconds 900; $Q3 = Rects
  $hw = MiniH; $wr = New-Object FH+R; [void][FH]::GetWindowRect($hw, [ref]$wr); $e = @($Q3.items | Where-Object { $_.sel -eq '#dnd' })[0]
  $pp = New-Object FH+P; $pp.X = [int]($wr.L + $e.x * $Q3.dpr); $pp.Y = [int]($wr.T + $e.y * $Q3.dpr)
  Assert ([FH]::GetAncestor([FH]::WindowFromPoint($pp), 2) -eq $hw) "opened via the toggle used by the tray / reminders: controls hit-testable"
  [void]$ev.Set(); Start-Sleep -Milliseconds 700
} catch [TestAbort] { "  [ABORT] $($_.Exception.Message)" } finally {
  Restore-MovedWindows
  if (-not ([FH]::GetWindowLong((MiniH), -20) -band 0x20)) { [void]$ev.Set(); Start-Sleep -Milliseconds 700 }   # 测完一定关上浮窗
  [void][RM]::SetCursorPos($p0.X, $p0.Y)   # 鼠标放回原处
  Remove-Item "$d\float_test_on", "$d\float_rects.json" -ErrorAction SilentlyContinue
  $s = Get-Content $stF -Raw | ConvertFrom-Json; $s.active = @(@($s.active) | Where-Object { $_.id -notlike 'test|*' -and $_.id -ne 'brief|test' }); foreach ($k in 'snooze', 'muted', 'fired') { foreach ($n in @($s.$k.PSObject.Properties.Name)) { if ($n -like 'test*') { $s.$k.PSObject.Properties.Remove($n) } } }; [IO.File]::WriteAllText($stF, ($s | ConvertTo-Json -Depth 6 -Compress))
  $ev.Dispose()
}
"RESULT: $script:ok / $script:tot passed"
