# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 窄窗口布局：轮次条、搜索按钮、「回到最新」都不盖住聊天卡片。在后台用无界面的 Edge 打开界面的一个副本（虚构卡片，不碰真数据、不抢前台）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$T = Join-Path $env:TEMP 'secretary_layout'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null; Copy-Item "$v2\ui\*" $T -Recurse -Force
$probe = [IO.File]::ReadAllText("$PSScriptRoot\layout_probe.html")
$html = [IO.File]::ReadAllText("$T\index.html"); [IO.File]::WriteAllText("$T\probe.html", $html.Replace('</html>', $probe + '</html>'), (New-Object Text.UTF8Encoding $false))
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; $url = 'file:///' + ("$T\probe.html" -replace '\\', '/')
foreach ($w in 480, 640, 790, 1200, 1440) {
  $ErrorActionPreference = 'Continue'; $o = & $edge --headless --disable-gpu --no-first-run "--user-data-dir=$T\ud$w" --force-device-scale-factor=2 "--window-size=$w,900" --virtual-time-budget=6000 --dump-dom $url 2>$null | Out-String; $ErrorActionPreference = 'Stop'   # Edge 会往错误输出里写无关的提示
  $h = ([regex]::Match($o, '<html[^>]*>')).Value; $raw = [Net.WebUtility]::HtmlDecode(([regex]::Match($h, 'data-probe="([^"]*)"')).Groups[1].Value)
  if (-not $raw) { Check "width $w measured" $false; continue }; $j = $raw | ConvertFrom-Json
  Check "width $w (css $($j.w), 200% DPI): rail ticks over cards $($j.railTicksOverCards), search over cards $($j.search), back-to-latest over cards $($j.toBottom), no sideways scroll" ($j.railTicksOverCards -eq 0 -and $j.search -eq 'search:0' -and $j.toBottom -eq 'toBottom:0' -and -not $j.hscroll)
  if ($j.w -lt 640) { Check "  narrow: rail is a thin track ($($j.railW) px)" ($j.railW -le 10) }
}
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"layout_test: $pass pass, $fail fail"