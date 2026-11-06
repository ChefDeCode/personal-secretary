# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 微信外的边框什么时候亮：秘书在想 / 值守在读（含透明还原读）→ 不亮，只有线在呼吸；借用前台发送 → 只在借用那一段亮。
# A、B：真的边缘线在跑，看它会不会拉起边框；C：仿微信窗口里走一遍发送（会抢前台），看边框标记什么时候亮。结果写到 data\border_when_test.txt
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_找聊天.ps1"; . "$v2\lib_打字.ps1"; . "$v2\lib_前台发送.ps1"
Add-Type 'using System; using System.Runtime.InteropServices; public static class TA3 { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); }'
$out = Join-Path $script:V2Data 'border_when_test.txt'; Remove-Item $out -ErrorAction SilentlyContinue; function W($s) { Add-Content $out $s -Encoding UTF8 }
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; W "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
function BorderProcs { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match '07_AI边框特效' }).Count }
$state = Join-Path $script:DataDir 'state.json'; $bfile = Join-Path $script:DataDir 'border.json'
# A) 秘书在想 / 值守在读：只写 state.json
Set-Lit $state 6; $seen = 0; for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Milliseconds 500; $seen = [Math]::Max($seen, (BorderProcs)) }; Set-Lit $state 1
Check 'thinking / reading (incl. invisible restore) -> edge line only, no border' ($seen -eq 0)
# B) 发送借用前台：写 border.json → 边框出来，标记过期后自己退
Start-Sleep 2; Set-Lit $bfile 3; $up = $false; for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Milliseconds 500; if ((BorderProcs) -gt 0) { $up = $true } }
$gone = $false; for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 500; if ((BorderProcs) -eq 0) { $gone = $true; break } }
Check 'send borrow flag -> border shows' $up; Check 'flag expires -> border goes away by itself' $gone
# C) 仿微信里发一次（等 3 秒「立即发」才开始）：等的时候不亮，借用时亮，发完熄
$tmpB = Join-Path $env:TEMP 'border_when_flag.json'; Remove-Item $tmpB -ErrorAction SilentlyContinue
$userClip = Save-Clip; $logF = Join-Path $env:TEMP 'fake_wechat_log.txt'; Remove-Item $logF -ErrorAction SilentlyContinue
try {
  Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force
  $app = Start-Process "$PSScriptRoot\仿微信.exe" -ArgumentList $logF, '目标会话5', '-4000', '200', 5, 'normal' -PassThru; Start-Sleep 2
  $script:MH = [WinTools]::LargestVisibleWindow([uint32[]]@($app.Id)); [void][TA3]::SetWindowPos($script:MH, [IntPtr]::Zero, 200, 200, 0, 0, 0x15)
  $flag = Join-Path $env:TEMP 'send_now_border.flag'; Remove-Item $flag -ErrorAction SilentlyContinue
  $job = Start-Job -ScriptBlock { param($p, $b) Start-Sleep -Milliseconds 1500; $w = (Test-Path $b) -and ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt [long]((Get-Content $b -Raw | ConvertFrom-Json).litUntil)); Start-Sleep -Milliseconds 1500; [IO.File]::WriteAllText($p, '1'); $w } -ArgumentList $flag, $tmpB
  $script:during = $null
  $o = @{ proc = '仿微信'; findMain = { param($ids) $script:MH }; summon = { param($hh) [void][FgSend]::ShowWindow($script:MH, 5) }; trayHide = { param($hh) [void][FgSend]::ShowWindow($script:MH, 0) }; pill = $null; same = { param($x, $y) ($x -replace '\s', '') -eq ($y -replace '\s', '') }
          border = $tmpB; idleMs = 600000; maxWaitSec = 30; nowFlag = $flag; afterFront = { $script:during = Test-Lit $tmpB } }
  $r = Invoke-FgSend $o '目标会话5' '【秘书测试】边框测试'
  $whileWaiting = Receive-Job $job -Wait; Remove-Job $job -Force
  Start-Sleep -Milliseconds 1500; $after = Test-Lit $tmpB
  Check "send went through on the fake window ($($r.msg))" ([bool]$r.ok)
  Check 'while waiting to send -> no border' (-not $whileWaiting)
  Check 'while WeChat is borrowed -> border on' ([bool]$script:during)
  Check 'after the send -> border off' (-not $after)
} finally { Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force; W "your clipboard restored: $(Restore-Clip $userClip)"; Remove-Item $tmpB -ErrorAction SilentlyContinue }
W "border_when_test: $pass pass, $fail fail"
