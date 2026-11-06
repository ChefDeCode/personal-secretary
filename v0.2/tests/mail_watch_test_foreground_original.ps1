# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 值守读 Outlook（假邮件窗口 + 临时设置）：没连接 → 不读；连接了 → 读一次交给整理；画面没变 → 不重复；最小化 → 不读
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $realRoot = Split-Path $v2 -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $realRoot 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_邮件读.ps1"; . "$v2\lib_原地读.ps1"
Add-Type 'using System; using System.Runtime.InteropServices; public static class MW2 { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h); }'
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$ast = [Management.Automation.Language.Parser]::ParseFile("$realRoot\12_值守.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Watch-Mail' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$root = Join-Path $env:TEMP 'secretary_mail_watch'; New-Item -ItemType Directory -Force $root | Out-Null; function SetCfg($on) { [IO.File]::WriteAllText("$root\config.json", (@{ features = @{ watch_outlook = $on } } | ConvertTo-Json)) }
$stats = @{ 错误 = 0 }; $script:Saved = 0; $script:Conv = ''; function Save-Messages($c, $m, $b, $app) { $script:Saved += @($m).Count; $script:Conv = $c }
$p = Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "$PSScriptRoot\fake_mail_window.ps1" -PassThru; Start-Sleep 4
try {
  $h = [IntPtr]::Zero; for ($i = 0; $i -lt 30 -and $h -eq [IntPtr]::Zero; $i++) { $h = [WinTools]::LargestVisibleWindow([uint32[]]@($p.Id)); if ($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 300 } }
  function Get-MailWindow { if (Test-MailReadable $h) { @{ h = $h; proc = 'fake' } } }
  SetCfg $false; $script:MailLast = [datetime]::MinValue; $script:MailSig = ''; Watch-Mail; Check 'not connected -> does not read' ($script:Saved -eq 0 -and -not $stats.邮件读取)
  SetCfg $true; $script:MailLast = [datetime]::MinValue; Watch-Mail; Check "connected -> reads ($($stats.邮件行) rows, $($stats.邮件未读) unread, $($stats.邮件毫秒) ms) and hands $script:Saved lines to the organiser" ($script:Saved -ge 6 -and $script:Conv -eq 'Outlook 邮件')
  $s0 = $script:Saved; $script:MailLast = [datetime]::MinValue; Watch-Mail; Check 'nothing changed -> nothing handed over again' ($script:Saved -eq $s0)
  [void][MW2]::ShowWindow($h, 6); Start-Sleep -Milliseconds 400; $n0 = $stats.邮件读取; $script:MailLast = [datetime]::MinValue; Watch-Mail; Check "minimized -> read invisibly when you're away, or waits while you're using the PC; either way it stays minimized (reads +$([int]$stats.邮件读取 - $n0))" ([MW2]::IsIconic($h))
  Check 'no errors' ($stats.错误 -eq 0)
} finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
"mail_watch_test: $pass pass, $fail fail"
