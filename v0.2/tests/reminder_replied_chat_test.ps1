# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 「有人在等你回复」：原消息之后你在那个聊天里发过消息，就不再提醒；已经弹出来的提醒卡也收掉。事情本身的状态不动、今天卡还在。
# 只在后台跑：临时数据文件夹、虚构的聊天和消息、假时钟；不开窗口、不碰真数据
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib_test_data.ps1'); $script:TestDataRoot = Use-TestDataFolder 'reminder_replied_chat_test'
$v2 = Split-Path $PSScriptRoot -Parent; . "$v2\lib_v2.ps1"
$T = Join-Path $env:TEMP 'secretary_rem_replied_chat'
function Use-Sandbox { $script:CfgPath = "$T\config.json"; $script:RemDir = $T; $script:V2Data = $T; $script:DoneFile = "$T\done.json"; $script:DataDir = $T; $script:MemDir = $T }
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null; Use-Sandbox
[IO.File]::WriteAllText($script:CfgPath, '{"features":{"proactive":true},"remind":{"brief":"09:00","quietFrom":"23:00","quietTo":"06:00","replyHours":4}}')
$d = (Get-Date).Date; $src = $d.AddHours(10)   # 原消息 10:00，4 小时后（14:00）该提醒
function Todo([string]$id, [string]$chat) { [ordered]@{ id = $id; ts = $src.AddSeconds(30).ToString('s'); 原文时间 = $src.ToString('s'); 类别 = '需要你回的'; 事情 = (Protect "示例事情 $id"); 谁 = (Protect '示例人'); 截止 = (Protect ''); conv = (Protect $chat); app = '微信'; 发言 = 'other' } }
function Msg([datetime]$at, [string]$chat, [string]$sender, [bool]$baseline = $false) { (@{ ts = $at.ToString('s'); app = '微信'; conv = (Protect $chat); conv_key = 'k'; sender = (Protect $sender); text = (Protect '示例'); baseline = $baseline; key = [guid]::NewGuid().ToString('n') } | ConvertTo-Json -Compress) }
$todos = @((Todo 'after' '示例聊天一'), (Todo 'before' '示例聊天二'), (Todo 'other' '示例聊天三'), (Todo 'base' '示例聊天四'), (Todo 'later' '示例聊天五'))
[IO.File]::WriteAllLines("$T\todos.jsonl", [string[]]@($todos | ForEach-Object { $_ | ConvertTo-Json -Compress }))
function ReplyIds([datetime]$now) { @(Get-ReminderCandidates $now (Update-OwnReplyIndex) | Where-Object { $_.id -like 'reply|*' } | ForEach-Object { $_.id }) }
# 0) 还没有任何消息记录：全部照常提醒
Check 'no message records at all -> every reply reminder is still there (5)' ((ReplyIds $src.AddHours(4)).Count -eq 5)
# 消息记录：聊天一在原消息之后你发过；聊天二只在原消息之前发过；聊天三里只有对方说话，你在聊天一发的不算聊天三；聊天四只有第一次看到时的整屏旧消息
$lines = @(
  (Msg $src.AddMinutes(-30) '示例聊天二' '我'), (Msg $src.AddMinutes(20) '示例聊天一' '我'), (Msg $src.AddMinutes(25) '示例聊天三' '对方'),
  (Msg $src.AddMinutes(40) '示例聊天四' '我' $true), (Msg $src.AddMinutes(50) '示例聊天五' '对方'))
[IO.File]::WriteAllLines("$T\messages.jsonl", [string[]]$lines, (New-Object Text.UTF8Encoding $false))
$ids = ReplyIds $src.AddHours(4)
Check 'replied in that chat after the source message -> no reminder' ($ids -notcontains 'reply|t:after')
Check 'replied in that chat only before the source message -> still reminds' ($ids -contains 'reply|t:before')
Check 'replied only in another chat -> still reminds' ($ids -contains 'reply|t:other')
Check 'only first-look (baseline) messages of yours -> still reminds' ($ids -contains 'reply|t:base')
Check 'the index file holds no chat names or text' (-not ([IO.File]::ReadAllText("$T\reply_seen.json") -match '示例'))
# 1) 已经弹出来的卡：之后你回了 → 下一次检查就收掉；事情还是 open、今天卡还在、没有被「不用再提醒」
$fired = @(Invoke-ReminderTick $src.AddHours(4)); $fired += @(Invoke-ReminderTick $src.AddHours(5.1))
$allFired = @($fired | ForEach-Object { $_.id; @($_.parts | ForEach-Object { $_.id }) } | Where-Object { $_ })
Check "the not-yet-replied chats fire ($(@($allFired | Where-Object { $_ -like 'reply|*' }).Count)/4)" (@($allFired | Where-Object { $_ -like 'reply|*' } | Sort-Object -Unique).Count -eq 4 -and $allFired -notcontains 'reply|t:after')
Check 'card for chat five is showing before you reply' (@((Get-RemState).active | Where-Object { $_ } | ForEach-Object { $_.id; @($_.parts | ForEach-Object { $_.id }) }) -contains 'reply|t:later')
[IO.File]::AppendAllLines("$T\messages.jsonl", [string[]]@((Msg $src.AddHours(5.2) '示例聊天五' '我')), (New-Object Text.UTF8Encoding $false))
[void](Invoke-ReminderTick $src.AddHours(5.25))
$act = @((Get-RemState).active | Where-Object { $_ } | ForEach-Object { $_.id; @($_.parts | ForEach-Object { $_.id }) })
Check 'you replied in chat five -> its reply card is closed on the next check' ($act -notcontains 'reply|t:later')
Check 'other reply cards stay' ($act -contains 'reply|t:before' -or @($act | Where-Object { $_ -like 'merge|*' }).Count -ge 1)
$t5 = @(Get-TrackedTodos | Where-Object { $_.id -eq 'later' })
Check 'the item itself is untouched (still open, no response state) and so its today card stays' ($t5.Count -eq 1 -and $t5[0].status -eq 'open' -and -not $t5[0].response_state)
Check 'the item is not muted (its other reminders still can come)' (-not (Get-RemState).muted.'t:later')
Check 'it does not come back later' (-not (@(Invoke-ReminderTick $src.AddHours(7)) | Where-Object { $_.id -eq 'reply|t:later' }))
# 2) 只读新增的部分；最后一行没写完先不算
[IO.File]::AppendAllText("$T\messages.jsonl", (Msg $src.AddHours(6) '示例聊天二' '我').Substring(0, 40), (New-Object Text.UTF8Encoding $false))
$off1 = ([IO.File]::ReadAllText("$T\reply_seen.json") | ConvertFrom-Json).offset; [void](Update-OwnReplyIndex)
Check 'a half-written last line is not read yet' ((([IO.File]::ReadAllText("$T\reply_seen.json") | ConvertFrom-Json).offset) -eq $off1)
Check 'reading is incremental (offset = bytes of complete lines)' ($off1 -eq ([IO.File]::ReadAllBytes("$T\messages.jsonl").Length - 40))
# 3) 消息记录换成了别的文件（变短了）→ 从头再读
[IO.File]::WriteAllLines("$T\messages.jsonl", [string[]]@((Msg $src.AddMinutes(-5) '示例聊天一' '我')), (New-Object Text.UTF8Encoding $false))
Check 'a replaced, shorter message file is read again from the start' ((ReplyIds $src.AddHours(4)) -contains 'reply|t:after')
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"reminder_replied_chat_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
