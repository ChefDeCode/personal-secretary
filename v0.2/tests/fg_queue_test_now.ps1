# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 连着发几条：3 条发给 2 个不同的聊天，一条接一条（每条都重新等你停手 2 秒），测试窗口自己报告发出去的字逐字比较；
# 每条记微信在最前面停了多久；最后微信回到原样。会真的抢前台，所以等你 2 分钟没动电脑才开始。结果写到 data\fg_queue_test.txt
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_找聊天.ps1"; . "$v2\lib_打字.ps1"; . "$v2\lib_前台发送.ps1"
Add-Type 'using System; using System.Runtime.InteropServices; public static class T7 { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); }'
$out = Join-Path $script:V2Data 'fg_queue_test.txt'; Remove-Item $out -ErrorAction SilentlyContinue; function W($s) { Add-Content $out $s -Encoding UTF8 }
function Same($x, $y) { $x = $x -replace '\s', ''; $y = $y -replace '\s', ''; [bool]($x -and $x -eq $y) }
W 'starting now (you asked)'; $dl = (Get-Date).AddMinutes(40); while ($false) { if ((Get-Date) -gt $dl) { W 'gave up waiting'; exit }; Start-Sleep 5 }
$userClip = Save-Clip; $logF = Join-Path $env:TEMP 'fake_wechat_log.txt'; Remove-Item $logF -ErrorAction SilentlyContinue
try {
  Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force
  $app = Start-Process "$PSScriptRoot\仿微信.exe" -ArgumentList $logF, '目标会话5', '-4000', '200', 5 -PassThru; Start-Sleep 2
  $script:MH = [WinTools]::LargestVisibleWindow([uint32[]]@($app.Id)); $h = $script:MH; [void][T7]::SetWindowPos($h, [IntPtr]::Zero, 200, 200, 0, 0, 0x15); [void][FgSend]::ShowWindow($h, 7)   # 起始：最小化
  $o = @{ proc = '仿微信'; findMain = { param($ids) $script:MH }; summon = { param($hh) [void][FgSend]::ShowWindow($script:MH, 5) }; trayHide = { param($hh) [void][FgSend]::ShowWindow($script:MH, 0) }; pill = $null; same = ${function:Same} }
  $queue = @(@{ conv = '目标会话5'; text = '【秘书测试】第一条' }, @{ conv = '测试联系人07'; text = '【秘书测试】第二条，给另一个人' }, @{ conv = '目标会话5'; text = '【秘书测试】第三条OK？' })
  $res = @(); $n = 0
  foreach ($q in $queue) { $n++
    $r = Invoke-FgSend $o $q.conv $q.text
    $lines = @(Get-Content $logF -Encoding UTF8 -ErrorAction SilentlyContinue)
    $res += [pscustomobject]@{ n = $n; ok = $r.ok; msg = $r.msg; sent_exact = [bool]($lines | Where-Object { $_ -ceq "SENT $($q.conv)`t$($q.text)" }); front_s = [Math]::Round($r.front_ms / 1000.0, 2); fg_back = $r.fg_back; clip_ok = $r.clip_ok } }
  $sentLines = @(Get-Content $logF -Encoding UTF8 | Where-Object { $_ -like 'SENT *' })
  $order = ($sentLines.Count -eq 3 -and $sentLines[0] -ceq "SENT 目标会话5`t$($queue[0].text)" -and $sentLines[1] -ceq "SENT 测试联系人07`t$($queue[1].text)" -and $sentLines[2] -ceq "SENT 目标会话5`t$($queue[2].text)")
  W ($res | Format-Table -AutoSize | Out-String -Width 160); W "in order, no extras: $order; total sends: $($sentLines.Count); WeChat ends minimized like at start: $([FgSend]::IsIconic($h))"
} finally { Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force; W "your clipboard restored: $(Restore-Clip $userClip)" }
