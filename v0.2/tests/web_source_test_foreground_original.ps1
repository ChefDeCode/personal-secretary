# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# Edge 来源：只读勾选过的网站。假浏览器窗口（不碰你的真 Edge）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_网页读.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
Check 'site rules: subdomain allowed, look-alike not' ((Test-SiteAllowed 'https://work.example.com/x' @('example.com')) -and -not (Test-SiteAllowed 'https://badexample.com' @('example.com')) -and -not (Test-SiteAllowed 'https://example.com.evil.io' @('example.com')) -and (Test-SiteAllowed 'www.example.com' @('https://www.example.com/')))
function Open-Fake([string]$url) { $p = Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "$PSScriptRoot\fake_browser_window.ps1", '-Url', $url -PassThru; $h = [IntPtr]::Zero; for ($i = 0; $i -lt 40 -and $h -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 300; $h = [WinTools]::LargestVisibleWindow([uint32[]]@($p.Id)) }; @{ p = $p; h = $h } }
$a = Open-Fake 'https://work.example.com/tasks'
try {
  $r = Read-EdgeUia $a.h @('example.com'); Check "ticked site -> reads the page ($(@($r.lines).Count) lines)" ($r.allowed -and @($r.lines).Count -ge 3 -and ($r.lines -join ' ') -match '测试报告')
  $r2 = Read-EdgeUia $a.h @('other.org'); Check 'site not ticked -> reads nothing but the address' (-not $r2.allowed -and @($r2.lines).Count -eq 0)
  $r3 = Read-EdgeUia $a.h @(); Check 'empty list -> reads nothing' (-not $r3.allowed -and @($r3.lines).Count -eq 0)
} finally { Stop-Process -Id $a.p.Id -Force -ErrorAction SilentlyContinue }
"web_source_test: $pass pass, $fail fail"
