# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 压缩过的对话：原文还在档案里，能取回来给界面（临时文件，不动你的真对话）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"
$T = Join-Path $env:TEMP 'secretary_older_chat'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null
$script:ChatFile = "$T\chat.jsonl"; $script:ChatArchive = "$T\chat_archive.jsonl"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$base = (Get-Date).AddDays(-5)
for ($i = 0; $i -lt 50; $i++) { [void](Add-ChatItem @{ role = $(if ($i % 2) { 'ai' } else { 'me' }); text = "测试消息 $i" }) }
$all = @(Get-ChatItems); $old3 = $all[3]; $old3.text = '测试消息 3（改过第一次）'; Update-ChatItem $old3; $old3.text = '测试消息 3（改过第二次）'; Update-ChatItem $old3
# 像压缩那样：chat.jsonl 只留最后 16 条，档案不动
$keep = @(Get-ChatItems | Select-Object -Last 16); [IO.File]::WriteAllLines($script:ChatFile, [string[]]@($keep | ForEach-Object { Protect ($_ | ConvertTo-Json -Depth 8 -Compress) }))
$older = @(Get-OlderChatItems)
Check "older originals come back ($($older.Count) of 34)" ($older.Count -eq 34)
Check 'in time order, none of the recent 16 repeated' (($older[0].text -eq '测试消息 0') -and -not ($older | Where-Object { $keep.id -contains $_.id }))
Check 'an edited old message comes back as its latest version' ((($older | Where-Object id -eq $old3.id).text) -eq '测试消息 3（改过第二次）')
Check 'archive still encrypted at rest' (-not ((Get-Content $script:ChatArchive -Raw) -match '测试消息'))
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"older_chat_test: $pass pass, $fail fail"
