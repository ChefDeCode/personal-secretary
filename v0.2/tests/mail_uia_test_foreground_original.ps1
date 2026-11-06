# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# Outlook 原地读（UIA）用假邮件窗口测：列表行、未读、打开的邮件正文；不点不打字、不抢前台、最小化时不读
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_邮件读.ps1"
Add-Type 'using System; using System.Runtime.InteropServices; public static class MT { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }'
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$fp = Join-Path $PSScriptRoot 'fake_mail_window.ps1'
$fg0 = [MT]::GetForegroundWindow()
$p = Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $fp -PassThru; Start-Sleep 3
try {
  $h = [IntPtr]::Zero; for ($i = 0; $i -lt 40 -and $h -eq [IntPtr]::Zero; $i++) { $h = [WinTools]::LargestVisibleWindow([uint32[]]@($p.Id)); if ($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 300 } }
  Check 'fake mail window is up' ($h -ne [IntPtr]::Zero)
  $fgBefore = [MT]::GetForegroundWindow()
  $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Read-MailUia $h; $ms = $sw.ElapsedMilliseconds
  Check "reads the mail list ($(@($r.rows).Count) rows, $($r.nodes) nodes, $ms ms)" (@($r.rows).Count -eq 4)
  Check "marks unread rows ($(@($r.rows | Where-Object unread).Count))" (@($r.rows | Where-Object unread).Count -eq 2)
  Check "reads the open mail ($(@($r.body).Count) lines)" (@($r.body).Count -ge 3 -and ($r.body -join ' ') -match '会议室')
  Check 'did not take the foreground' ([MT]::GetForegroundWindow() -eq $fgBefore)
  [void][MT]::ShowWindow($h, 6); Start-Sleep -Milliseconds 500
  Check 'minimized -> not read (waits until it is open)' (-not (Test-MailReadable $h))
} finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
"mail_uia_test: $pass pass, $fail fail"
