# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 真微信上的「截一张就收」检查：只在你说「可以测」以后手动跑（不在 跑测试.ps1 里）
# 微信现在是什么样（最小化 / 关在托盘里）就用什么样，不去改它；20 次：透明地放出来 → 一画出来就截 → 马上放回 → 认字在截好的图上做
# 每次记：露出来多少毫秒、截全了没有、前台变没变、放回去以后它有没有自己又弹出来（盯 1 秒）、最后是不是回到原样。只有数字，不记任何内容
# 不点、不按键、不发任何东西；你一碰鼠标键盘就停（这一次放回去、后面不再跑）
param([int]$N = 20)
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; . "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_原地读.ps1"
Add-Type 'using System; using System.Runtime.InteropServices; public static class RS { [StructLayout(LayoutKind.Sequential)] public struct WP { public int len, flags, show; public int mx, my, xx, xy; public int l, t, r, b; } [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WP p); [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i); [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c); }'
$out = Join-Path $script:V2Data 'real_snap_check.txt'
$ps = @(Get-Process Weixin -ErrorAction SilentlyContinue); if (-not $ps.Count) { [IO.File]::WriteAllText($out, '微信没开着'); '微信没开着'; return }
$h = [AppWin]::Largest([uint32[]]$ps.Id); if (-not [Ghost2]::IsWindowVisible($h)) { $hm = [Ghost2]::HiddenMain([uint32[]]$ps.Id, 400, 300); if ($hm -ne [IntPtr]::Zero) { $h = $hm } }
function State { $p = New-Object RS+WP; $p.len = 44; [void][RS]::GetWindowPlacement($h, [ref]$p); "$([Ghost2]::IsIconic($h))|$([Ghost2]::IsWindowVisible($h))|$('{0:x}' -f [RS]::GetWindowLong($h, -20))|$($p.show)|$($p.l),$($p.t),$($p.r),$($p.b)" }
$st0 = State; $kind = if (-not [Ghost2]::IsWindowVisible($h)) { 'tray' } elseif ([Ghost2]::IsIconic($h)) { 'minimized' } else { 'open (nothing to test: WeChat is visible)' }
$rows = New-Object System.Collections.ArrayList; $stopped = ''
if ($kind -like 'open*') { $stopped = $kind } else {
  for ($i = 1; $i -le $N; $i++) {
    $fg0 = [Ghost2]::Fg(); $rep0 = [Ghost2]::Repops
    $s = Invoke-GhostSnap $h 200 0
    Start-Sleep -Milliseconds 1000   # 盯 1 秒：它排着的「激活」会不会在我们放回去之后发作
    $chats = 0; $msgs = 0; if ($s.ok) { try { $r = Read-WeChat $h $s.bmp; $chats = @($r.列表).Count; $msgs = @($r.消息).Count } finally { $s.bmp.Dispose() } }
    [void]$rows.Add([pscustomobject]@{ n = $i; ok = $s.ok; visible_ms = $s.rec.visible_ms; painted = $s.rec.painted; chats = $chats; msgs = $msgs; fg_changed = $s.rec.fg_changed; fg_restored = $s.rec.fg_restored; repop = ([Ghost2]::Repops - $rep0); same_state = ((State) -eq $st0); fg_same = ([Ghost2]::Fg() -eq $fg0); why = $s.why })
    if ($s.rec.user_input -or $s.why -match '你动了') { $stopped = "第 $i 次你动了电脑，已停"; break }
    Start-Sleep -Seconds 2
  } }
$vis = @($rows | Where-Object visible_ms | ForEach-Object visible_ms | Sort-Object)
$sum = @("真微信 截一张就收 检查 $((Get-Date).ToString('yyyy-MM-dd HH:mm'))，微信状态：$kind",
  "跑了 $($rows.Count) 次：截到 $(@($rows | Where-Object ok).Count) 次；露出来 中位 $(if ($vis.Count) { $vis[[int](($vis.Count - 1) / 2)] }) ms、最长 $(if ($vis.Count) { $vis[-1] }) ms；超过 250 ms 的 $(@($vis | Where-Object { $_ -gt 250 }).Count) 次",
  "前台变了 $(@($rows | Where-Object fg_changed).Count) 次（还回去 $(@($rows | Where-Object fg_restored).Count)）；放回去以后又自己弹出来 $(($rows | Measure-Object repop -Sum).Sum) 次；最后不是原样 $(@($rows | Where-Object { -not $_.same_state }).Count) 次；前台和开始时不一样 $(@($rows | Where-Object { -not $_.fg_same }).Count) 次",
  "认出的聊天数（每次）：$((@($rows | ForEach-Object chats)) -join ',')", $(if ($stopped) { "停下：$stopped" } else { '' })) | Where-Object { $_ }
$sum += ''; $sum += ($rows | Select-Object n, ok, visible_ms, painted, chats, msgs, fg_changed, fg_restored, repop, same_state, fg_same, why | Format-Table -AutoSize | Out-String -Width 200)
[IO.File]::WriteAllLines($out, [string[]]$sum, (New-Object Text.UTF8Encoding $true)); $sum
