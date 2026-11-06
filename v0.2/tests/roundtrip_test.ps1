# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 回归测试：每种存下来的记录，列表字段有 0 / 1 / 2 个元素时，存进去再读出来都还是列表（PowerShell 会把只有一个元素的数组拆开）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"
$T = Join-Path $env:TEMP 'secretary_roundtrip'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null
$script:ChatFile = "$T\chat.jsonl"; $script:ChatArchive = "$T\chat_archive.jsonl"; $script:PeopleFile = "$T\people.jsonl"; $script:FileIdxFile = "$T\files.jsonl"
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
function IsList($x) { $x -is [array] -or $x -is [Collections.IList] }
foreach ($n in 0, 1, 2) {
  $steps = @(1..$n | Where-Object { $n } | ForEach-Object { @{ ok = $true; text = "步骤$_" } })
  # 和 Finish-Turn 里一样的写法：$(...) 会把一个元素的数组拆开
  $it = Add-ChatItem @{ role = 'ai'; text = 't'; steps = $(if ($true) { $steps } else { @() }); card = @{ kind = 'send'; opts = @('发送', '先不发'); result = @() } }
  $back = Get-ChatItems | Where-Object id -eq $it.id
  $raw = (Unprotect (Get-Content $script:ChatFile | Select-Object -Last 1))
  Assert ((IsList $back.steps) -and @($back.steps).Count -eq $n -and $raw -match '"steps":\[') "chat item with $n step(s): stored and read back as a list"
  $p = New-PersonRecord; $p.aliases = @(1..$n | Where-Object { $n } | ForEach-Object { [pscustomobject]@{ text = "称呼$_"; source = 'user_confirmed' } }); $p.chats = @([pscustomobject]@{ app = '微信'; title = "人$n" })
  Save-People @($p); $q = @(Get-People)[0]
  Assert ((IsList $q.aliases) -and @($q.aliases).Count -eq $n -and (IsList $q.chats)) "person with $n alias(es): list after round trip"
  $idx = @{}; $idx["f$n"] = [pscustomobject]@{ id = "f$n"; name = 'a.txt'; keywords = @(1..$n | Where-Object { $n } | ForEach-Object { "k$_" }); topics = @(1..$n | Where-Object { $n } | ForEach-Object { [pscustomobject]@{ text = "t$_" } }) }
  Save-FileIndex $idx; $g = (Get-FileIndex)["f$n"]
  Assert (@($g.topics).Count -eq $n -and @($g.keywords).Count -eq $n) "file record with $n topic(s)/keyword(s): count kept after round trip"
}
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $script:ok / $script:tot passed"
