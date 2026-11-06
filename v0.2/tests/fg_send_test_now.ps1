# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 「借用最前面不到 1 秒」测试：仿微信测试窗口（不碰真微信），四种起始状态（在你桌面但不在前面 / 最小化 / 托盘 / 桌面 2），
# 再加：聊天名字对不上 → 不粘贴；中途有「用户输入」→ 立刻停、清理、剪贴板还原；输入框有草稿 → 不动。
# 发出去的字由测试窗口自己报告（不靠 OCR）逐字比较。会真的抢前台，所以等你 2 分钟没动电脑才开始；你一回来就停。结果写到 data\fg_send_test.txt
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_找聊天.ps1"; . "$v2\lib_打字.ps1"; . "$v2\lib_前台发送.ps1"
Add-Type 'using System; using System.Runtime.InteropServices; public static class T6 { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e); public static void Nudge() { mouse_event(1, 1, 0, 0, UIntPtr.Zero); mouse_event(1, -1, 0, 0, UIntPtr.Zero); } }'
$out = Join-Path $script:V2Data 'fg_send_test.txt'; Remove-Item $out -ErrorAction SilentlyContinue; function W($s) { Add-Content $out $s -Encoding UTF8 }
function Same($x, $y) { $x = $x -replace '\s', ''; $y = $y -replace '\s', ''; [bool]($x -and $x -eq $y) }
W "starting now (you asked)"; $dl = (Get-Date).AddMinutes(40); while ($false -and [FgSend]::IdleMs() -lt 120000) { if ((Get-Date) -gt $dl) { W 'gave up waiting'; exit }; Start-Sleep 5 }
$userClip = Save-Clip   # 你自己剪贴板里的东西：测完原样放回
$logF = Join-Path $env:TEMP 'fake_wechat_log.txt'
$text = '【秘书测试】明天3点开会，OK？'
$cases = @(
  @{ name = 'on your desktop, not in front'; state = 'here'; conv = '目标会话5' }
  @{ name = 'minimized'; state = 'min'; conv = '目标会话5' }
  @{ name = 'in tray (hidden)'; state = 'tray'; conv = '目标会话5' }
  @{ name = 'name not found -> no paste'; state = 'here'; conv = '不存在的人' }
  @{ name = 'user input mid-way -> abort'; state = 'here'; conv = '目标会话5'; nudge = $true }
  @{ name = 'draft in box -> untouched'; state = 'here'; conv = '目标会话5'; pre = '还没写完的草稿' }
  @{ name = 'paste would land in search box'; state = 'here'; conv = '目标会话5'; mode = 'stayinsearch' }
  @{ name = 'clipboard locked by another program'; state = 'here'; conv = '目标会话5'; lock = $true }
  @{ name = 'copy-back arrives late (250 ms)'; state = 'here'; conv = '目标会话5'; mode = 'slowcopy' }
  @{ name = 'copy-back not possible -> OCR check'; state = 'here'; conv = '目标会话5'; mode = 'nocopy' }
)
$res = @()
try {
foreach ($c in $cases) {
  if ($script:AfterTick -and [FgSend]::LastInput() -ne $script:AfterTick) { W 'stopped: you came back'; break }
  Remove-Item $logF -ErrorAction SilentlyContinue; Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force
  $app = Start-Process "$PSScriptRoot\仿微信.exe" -ArgumentList $logF, '目标会话5', '-4000', '200', 5, $(if ($c.mode) { $c.mode } else { 'normal' }), $(if ($c.pre) { $c.pre } else { '""' }) -PassThru; Start-Sleep 2
  $script:MH = [WinTools]::LargestVisibleWindow([uint32[]]@($app.Id)); $h = $script:MH; [void][T6]::SetWindowPos($h, [IntPtr]::Zero, 200, 200, 0, 0, 0x15)
  # 起始：先打开过一次目标聊天（预填草稿要在打开时出现），再回到列表初始状态
  switch ($c.state) { 'min' { [void][FgSend]::ShowWindow($h, 7) } 'tray' { [void][FgSend]::ShowWindow($h, 0) } }
  Start-Sleep -Milliseconds 500
  [Windows.Forms.Clipboard]::SetText('原来剪贴板里的字'); $prev = [FgSend]::GetForegroundWindow()
  $o = @{ proc = '仿微信'; findMain = { param($ids) $script:MH }; summon = { param($hh) [void][FgSend]::ShowWindow($hh, 5) }; trayHide = { param($hh) [void][FgSend]::ShowWindow($hh, 0) }; pill = $null; same = ${function:Same} }
  if ($c.nudge) { $o.afterFront = { [T6]::Nudge() } }
  if ($false) { $job = Start-Job -ScriptBlock { Start-Sleep -Milliseconds 1200; Add-Type 'using System; using System.Runtime.InteropServices; public static class N { [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e); public static void Go() { mouse_event(1, 1, 0, 0, UIntPtr.Zero); mouse_event(1, -1, 0, 0, UIntPtr.Zero); } }'; [N]::Go() } }
  $lk = $null; if ($c.lock) { $lk = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', 'Add-Type ''using System; using System.Runtime.InteropServices; public static class CL { [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h); [DllImport("user32.dll")] public static extern bool CloseClipboard(); }''; [void][CL]::OpenClipboard([IntPtr]::Zero); Start-Sleep 9; [void][CL]::CloseClipboard()'); Start-Sleep -Milliseconds 800 }   # 另一个程序占着剪贴板
  $r = Invoke-FgSend $o $c.conv $text
  if ($lk) { Stop-Process -Id $lk.Id -Force -ErrorAction SilentlyContinue }

  Start-Sleep -Milliseconds 300
  $lines = @(if (Test-Path $logF) { Get-Content $logF -Encoding UTF8 })
  $sentOk = [bool]($lines | Where-Object { $_ -ceq "SENT $($c.conv)`t$text" }); $anySent = @($lines | Where-Object { $_ -like 'SENT *' }).Count
  [void]$h; $endState = if (-not [FgSend]::IsWindowVisible($h)) { 'tray' } elseif ([FgSend]::IsIconic($h)) { 'min' } else { 'here' }
  $clipNow = try { [Windows.Forms.Clipboard]::GetText() } catch { '?' }
  $res += [pscustomobject]@{ case = $c.name; ok = $r.ok; msg = $r.msg; sent_exact = $sentOk; sends = $anySent; front_s = [Math]::Round($r.front_ms / 1000.0, 2); total_s = [Math]::Round($r.visible_ms / 1000.0, 2); fg_back = $r.fg_back; focus = $r.focus; verify = $r.verify; diag = $r.diag; steps_ms = $(if ($r.t) { ($r.t.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ' } else { '' }); back_to_start = ($endState -eq $c.state); clip_restored = ($clipNow -ceq '原来剪贴板里的字') }
  Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 300; $script:AfterTick = [FgSend]::LastInput()   # 只有这之后「不是测试自己」的输入才算你回来了
}
} finally { Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force; $uc = Restore-Clip $userClip; W "your clipboard restored after test: $uc" }   # 出错也一定把你的剪贴板放回去
W ($res | Format-Table -AutoSize | Out-String -Width 220)
