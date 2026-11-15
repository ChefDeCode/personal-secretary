# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 标题没认出来时的第二次找法（顶部整条）：去掉搜索框、符号和单个非汉字的图标，取搜索框右边最靠左的一行；只在「标题来源 none」时才做
# 只在后台跑：从 lib_识别.ps1 取出 Find-TitleInBand，认字结果全是假的；不截图、不开窗口、不碰微信
. "$PSScriptRoot\lib_synthetic_test.ps1"
Import-TestFunctions "$productRoot\lib_识别.ps1" @('Find-TitleInBand')
Add-Type -AssemblyName System.Drawing
function Crop($b, $r) { $script:Cropped = $r; New-Object Drawing.Bitmap 4, 4 }
function Invoke-Ocr($b) { 'ocr' }
function Get-Lines($o) { $script:Lines }
function L([string]$t, [int]$x0, [int]$x1, [int]$y = 96) { [pscustomobject]@{ 文本 = $t; x0 = $x0; x1 = $x1; y = $y; h = 28 } }
$full = New-Object Drawing.Bitmap 2000, 1700
try {
  $script:Lines = @((L '示例' 640 690), (L 'Q搜索' 255 360 101), (L '+' 540 560 95))
  $r = Find-TitleInBand $full 2.0 160
  Check "picks the line right of the search box, skipping the plus icon (x0=$($r.x0))" ($r -and $r.文本 -eq '示例' -and $r.x0 -eq 760)
  Check 'the band starts after the 60-DIP nav bar and is at least 90 DIP tall' ($script:Cropped.X -eq 120 -and $script:Cropped.Height -eq 180 -and $script:Cropped.Width -eq 1480)
  $script:Lines = @((L 'Q搜索' 255 360 101), (L 'A' 540 560 95), (L '示例' 640 690))
  Check 'a single non-CJK letter (an icon read as a letter) is not taken as the title' ((Find-TitleInBand $full 2.0 160).文本 -eq '示例')
  $script:Lines = @((L 'Q搜索' 255 360 101), (L '张' 640 660))
  Check 'a one-character Chinese name is still accepted' ((Find-TitleInBand $full 2.0 160).文本 -eq '张')
  $script:Lines = @((L 'Q搜索' 255 360 101))
  Check 'only the search box (list-only view, no chat open) -> nothing found' ($null -eq (Find-TitleInBand $full 2.0 160))
  $script:Lines = @((L '示例' 100 160))
  Check 'no search box (chat-only view) -> leftmost text line' ((Find-TitleInBand $full 2.0 160).文本 -eq '示例')
  $script:Lines = @((L '、' 300 310), (L '：' 400 410))
  Check 'punctuation-only lines are ignored' ($null -eq (Find-TitleInBand $full 2.0 160))
} finally { $full.Dispose() }
# 只在 none 时多做；正常路径不变
$src = [IO.File]::ReadAllText("$productRoot\lib_识别.ps1")
Check 'the band retry only runs when the title source is none and no layout override is in effect' ($src -match 'if \(\$titleFrom -eq ''none'' -and -not \$LayoutOverride\) \{\s*\$bt = Find-TitleInBand')
Check 'a band hit is labelled title-band (so the watcher saves it under that name)' ($src -match '\$r2\.标题来源 = ''title-band''')
Check 'Read-WeChat keeps its two-argument form for existing callers' ($src -match 'function Read-WeChat\(\[IntPtr\]\$h, \[Drawing\.Bitmap\]\$full, \[double\[\]\]\$LayoutOverride = \$null\)')
Done-Test
