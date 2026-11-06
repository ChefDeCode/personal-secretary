# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 收起来的窗口也能读（所有来源共用的透明读）：仿微信测试窗口（不碰真微信）在 最小化 / 关在托盘里（隐藏） / 被盖住 / 在屏幕外 四种样子下，
# 内置微信读法和商店插件读法都能读到；读完窗口回到原样、前台不变、不会弹出来；读到一半你动了鼠标 → 30 毫秒级放回去，这一次不算
# 会动测试窗口的状态（看不见），所以等你停手 5 秒才开始
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $root = Split-Path $v2 -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_通用识别.ps1"; . "$v2\lib_商店.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
Add-Type 'using System; using System.Runtime.InteropServices; public static class GA { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h); [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i); [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e); public static void Nudge() { mouse_event(1, 0, 0, 0, UIntPtr.Zero); } }'
$T = Join-Path $env:TEMP 'secretary_ghost_all'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\adapters" | Out-Null; $script:V2Data = $T
# 临时插件：读整个窗口的文字（只读）
$d = "$T\adapters\p-ghost"; New-Item -ItemType Directory -Force $d | Out-Null
[IO.File]::WriteAllText("$d\manifest.json", '{"id":"p-ghost","app":{"process":"仿微信.exe","display":"测试软件"},"permissions":["app.observe","region.read:message_area"]}')
[IO.File]::WriteAllText("$d\config.json", (@{ regions = @{ message_area = @{ x = 0.0; y = 0.0; w = 1.0; h = 1.0 } } } | ConvertTo-Json -Depth 4))
[IO.File]::WriteAllText("$d\script.json", '{"actions":{"read_open_chat":[{"op":"find_window"},{"op":"read_region","region":"message_area","as":"text"},{"op":"emit","field":"text"}]}}')
[IO.File]::WriteAllText("$d\installed.json", (@{ id = 'p-ghost'; version = '1.0.0'; source = 'store'; app_process = '仿微信.exe'; app = '测试软件'; name = '测试'; permissions = @('app.observe', 'region.read:message_area'); enabled = $true; withdrawn = $false } | ConvertTo-Json))
while ([Ghost2]::IdleMs() -lt 5000) { Start-Sleep -Milliseconds 500 }
$logF = Join-Path $env:TEMP 'fake_wechat_log.txt'; $cover = $null
try {
  Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force
  $app = Start-Process "$PSScriptRoot\仿微信.exe" -ArgumentList $logF, '目标会话5', '-4000', '200', 5 -PassThru; Start-Sleep 2
  $h = [WinTools]::LargestVisibleWindow([uint32[]]@($app.Id)); [void][GA]::SetWindowPos($h, [IntPtr]::Zero, 200, 200, 0, 0, 0x15); Start-Sleep -Milliseconds 300
  $builtin = { $r = [WinTools]::Rect($h); $b = [Rec]::Window($h, $r.R - $r.L, $r.B - $r.T); try { @((Read-WeChat $h $b).列表).Count } finally { $b.Dispose() } }
  foreach ($state in 'minimized', 'tray (hidden)', 'covered', 'off-screen') {
    [void][GA]::ShowWindow($h, 9); [void][GA]::SetWindowPos($h, [IntPtr]::Zero, 200, 200, 0, 0, 0x15); Start-Sleep -Milliseconds 300
    switch ($state) {
      'minimized' { [void][GA]::ShowWindow($h, 7) }
      'tray (hidden)' { [void][GA]::ShowWindow($h, 0) }
      'covered' { $cover = Start-Process "$PSScriptRoot\秘书测试窗口.exe" -ArgumentList '300', '260' -PassThru; Start-Sleep 2; [void][GA]::SetWindowPos($cover.MainWindowHandle, [IntPtr]::Zero, 150, 150, 0, 0, 0x15) }
      'off-screen' { [void][GA]::SetWindowPos($h, [IntPtr]::Zero, -4000, 200, 0, 0, 0x15) }
    }
    Start-Sleep -Milliseconds 500
    $min0 = [GA]::IsIconic($h); $vis0 = [GA]::IsWindowVisible($h); $ex0 = [GA]::GetWindowLong($h, -20); $fg0 = [GA]::GetForegroundWindow()
    # 找窗口：托盘里（隐藏）的也要找得到
    $found = Get-PluginWindow @($app)
    Check "[$state] the window is found ($([bool]($found -eq $h)))" ($found -eq $h)
    $g = Invoke-GhostRead $h $builtin 0
    Check "[$state] built-in reader reads it ($($g.value) chats, through ghost: $([bool]$g.ghost))" ($g.ok -and $g.value -gt 0)
    $p = Invoke-PluginAction 'p-ghost' 'read_open_chat'
    $txt = if ($p.ok -and $p.data) { [string]$p.data['text'] } else { '' }; Check "[$state] plugin reader reads it ($($txt.Length) characters) $(if (-not $p.ok) { $p.reason })" ($p.ok -and $txt.Length -gt 5)
    Start-Sleep -Milliseconds 200
    Check "[$state] back exactly as it was (minimized $min0 -> $([GA]::IsIconic($h)), visible $vis0 -> $([GA]::IsWindowVisible($h)), styles same), foreground unchanged" ([GA]::IsIconic($h) -eq $min0 -and [GA]::IsWindowVisible($h) -eq $vis0 -and [GA]::GetWindowLong($h, -20) -eq $ex0 -and [GA]::GetForegroundWindow() -eq $fg0)
    if ($cover) { $cover.Kill(); $cover = $null }
  }
  # 读到一半你动了：马上放回去，这次不算
  [void][GA]::ShowWindow($h, 9); Start-Sleep -Milliseconds 300; [void][GA]::ShowWindow($h, 7); Start-Sleep -Milliseconds 400
  $sw = $null; $g = Invoke-GhostRead $h { [GA]::Nudge(); $script:sw = [Diagnostics.Stopwatch]::StartNew(); while ([Ghost2]::Active -and $script:sw.ElapsedMilliseconds -lt 2000) { Start-Sleep -Milliseconds 2 }; $script:backMs = $script:sw.ElapsedMilliseconds; 1 } 0
  Check "input mid-read -> put back in $($script:backMs) ms, this read is dropped ($($g.why))" (-not $g.ok -and $script:backMs -lt 150 -and [GA]::IsIconic($h))
  # 你正在用电脑（刚动过）→ 先不放出来
  [GA]::Nudge(); $g = Invoke-GhostRead $h $builtin 5000; Check "you are using the PC -> it waits instead ($($g.why))" (-not $g.ok -and [GA]::IsIconic($h))
} finally { if ([Ghost2]::Active) { [Ghost2]::Hide() }; if ($cover) { try { $cover.Kill() } catch {} }; Get-Process 仿微信 -ErrorAction SilentlyContinue | Stop-Process -Force; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
"ghost_all_test: $pass pass, $fail fail"
