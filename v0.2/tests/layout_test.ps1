# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
. (Join-Path $PSScriptRoot 'lib_test_data.ps1'); $script:TestDataRoot = Use-TestDataFolder 'layout_test'   # 测试用自己的临时数据文件夹，不碰真的数据
. "$PSScriptRoot\lib_synthetic_test.ps1"
foreach($page in 'index.html','mini.html'){
 $text=[IO.File]::ReadAllText((Join-Path $v2 "ui\$page"))
 $markup=($text -split '<script',2)[0]
 $ids=@([regex]::Matches($markup,'\bid="([^"]+)"')|ForEach-Object{$_.Groups[1].Value})
 $duplicates=@($ids|Group-Object|Where-Object Count -gt 1)
 Check "$page unique static DOM anchors" ($ids.Count -gt 5 -and $duplicates.Count -eq 0)
 Check "$page message input preserved" ($markup -match '<(textarea|input)\b')
 Check "$page WebView messaging bridge preserved" ($text -match 'webview')
}
'[PENDING_NATIVE] geometry_at_five_widths'
Done-Test
