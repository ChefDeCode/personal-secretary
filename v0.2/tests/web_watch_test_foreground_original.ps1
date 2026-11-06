# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# Edge 来源的设置和值守：网站清单的加 / 删（临时改，结束后改回）；值守只在开关开着、网站在清单里时读（假浏览器窗口 + 临时设置）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $realRoot = Split-Path $v2 -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $realRoot 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_网页读.ps1"; . "$v2\lib_原地读.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$orig = (Read-Config).edge_sites
try {
  Check 'add a site (url pasted -> stored as site name)' ((Set-EdgeSites 'add' 'https://www.Work.Example.com/tasks?x=1') -eq '' -and @((Read-Config).edge_sites) -contains 'work.example.com')
  Check 'nonsense rejected' ((Set-EdgeSites 'add' 'not a site') -ne '')
  Check 'remove a site' ((Set-EdgeSites 'remove' 'work.example.com') -eq '' -and @((Read-Config).edge_sites) -notcontains 'work.example.com')
} finally { $c = Read-Config; if ($null -eq $orig) { $c.PSObject.Properties.Remove('edge_sites') } else { $c | Add-Member -NotePropertyName edge_sites -NotePropertyValue $orig -Force }; Save-Config $c }
$ast = [Management.Automation.Language.Parser]::ParseFile("$realRoot\12_值守.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Watch-Edge' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$root = Join-Path $env:TEMP 'secretary_web_watch'; New-Item -ItemType Directory -Force $root | Out-Null
function SetCfg($on, $sites) { [IO.File]::WriteAllText("$root\config.json", (@{ features = @{ watch_edge = $on }; edge_sites = @($sites) } | ConvertTo-Json)) }
$stats = @{ 错误 = 0 }; $script:Saved = 0; $script:Conv = ''; function Save-Messages($c, $m, $b, $app) { $script:Saved += @($m).Count; $script:Conv = $c }
$p = Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "$PSScriptRoot\fake_browser_window.ps1", '-Url', 'https://work.example.com/tasks' -PassThru
try {
  $h = [IntPtr]::Zero; for ($i = 0; $i -lt 40 -and $h -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 300; $h = [WinTools]::LargestVisibleWindow([uint32[]]@($p.Id)) }
  function Get-EdgeWindow { $h }
  SetCfg $false @('example.com'); $script:EdgeLast = [datetime]::MinValue; Watch-Edge; Check 'switch off -> does not read' ($script:Saved -eq 0 -and -not $stats.网页查看)
  SetCfg $true @('other.org'); $script:EdgeLast = [datetime]::MinValue; Watch-Edge; Check 'site not in the list -> nothing handed over' ($script:Saved -eq 0)
  SetCfg $true @('example.com'); $script:EdgeLast = [datetime]::MinValue; Watch-Edge; Check "ticked site -> page handed to the organiser ($script:Saved lines, as $script:Conv)" ($script:Saved -ge 3 -and $script:Conv -eq '网页：work.example.com')
  $s0 = $script:Saved; $script:EdgeLast = [datetime]::MinValue; Watch-Edge; Check 'same page again -> nothing new' ($script:Saved -eq $s0)
  Check 'no errors' ($stats.错误 -eq 0)
} finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
"web_watch_test: $pass pass, $fail fail"
