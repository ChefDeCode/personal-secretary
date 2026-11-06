# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 截图最多 1 GB：超了从最旧的截图删起，删到上限以下；记录留着标成 pruned；没超就一张不动。只动截图文件夹
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; . "$v2\lib_v2.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$T = Join-Path $env:TEMP 'secretary_attcap'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\images" | Out-Null
$realCap = $script:AttImgCap; $script:AttData = $T
Add-Type -AssemblyName System.Drawing
$ids = foreach ($i in 1..6) { $bmp = New-Object Drawing.Bitmap 300, 200; $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::FromArgb(40 * $i, 90, 160)); $g.Dispose()
  $rec = Save-AttImage $bmp @{ app = '测试'; conv = 'c'; sender = 's'; msg_key = "k$i"; shown = ''; source = 'test' }; $bmp.Dispose(); Start-Sleep -Milliseconds 1100; $rec.id }
[IO.File]::WriteAllText("$T\messages.jsonl", 'keep'); [IO.File]::WriteAllText("$T\attachments_note.txt", 'keep')
$size = { [long](Get-ChildItem "$T\images" -File | Measure-Object Length -Sum).Sum }
$all = & $size; $per = [long]($all / 6)
Check "real cap is 1 GB ($([int]($realCap / 1MB)) MB)" ($realCap -eq 1GB)
Check 'under the cap nothing is removed' ((Limit-AttImages $all) -eq 0 -and @(Get-ChildItem "$T\images" -File).Count -eq 12)
$n = Limit-AttImages ([long]($all - 2.5 * $per)); $left = @(Get-ChildItem "$T\images" -File | ForEach-Object { $_.BaseName } | Sort-Object -Unique)
Check "over the cap: oldest removed first ($n removed)" ($n -eq 3 -and -not @($ids[0..2] | Where-Object { $left -contains $_ }).Count -and -not @($ids[3..5] | Where-Object { $left -notcontains $_ }).Count)
Check 'now under the cap' ((& $size) -le ($all - 2.5 * $per))
$recs = @(Get-AttRecords); Check 'records are kept and marked pruned' (@($recs | Where-Object mode -eq 'pruned').Count -eq 3 -and $recs.Count -eq 6)
Check 'other files are never touched' ((Test-Path "$T\messages.jsonl") -and (Test-Path "$T\attachments_note.txt"))
Check 'settings show usage and the cap' ((Get-AttStorage).cap -eq 1GB)
"att_cap_test: $pass pass, $fail fail"