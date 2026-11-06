# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 发送卡「重试」「取消」测试（在临时对话里，不发送任何消息：Start-Send 换成只记录）：旧卡片（缺字段）、新卡片、连点两次、失败后取消再重试
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"
$T = Join-Path $env:TEMP 'secretary_retry_test'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\actions" | Out-Null
$script:ChatFile = "$T\chat.jsonl"; $script:ChatArchive = "$T\chat_archive.jsonl"; $script:ActDir = "$T\actions"
$ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Invoke-SendRetry', 'Invoke-SendCancel' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$script:Sending = @{}; $script:Started = New-Object System.Collections.ArrayList; $script:Posted = New-Object System.Collections.ArrayList
function Start-Send([string]$id, $it) { [void]$script:Started.Add($id); $script:Sending[$id] = $it }   # 只记录，不真的去发
function Post($o) { [void]$script:Posted.Add($o) }
$realGetSwitch = ${function:Get-Switch}; function Get-Switch([string]$k) { if ($k -eq 'send_messages') { return $true }; & $realGetSwitch $k }
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
# 旧格式的卡片：没有 cancelled / failed / result / said（直接写进对话文件，就像以前存下来的）
$a1 = New-SendAction '文件传输助手' '测试消息' ''; $a1.status = 'failed'; Save-Action $a1
$old = [ordered]@{ role = 'ai'; ts = (Get-Date).ToString('s'); id = 'oldcard01'; card = [ordered]@{ kind = 'send'; actionId = $a1.id; who = '文件传输助手'; src = '微信'; text = '测试消息'; opts = @('发送', '先不发'); status = 'closed' } }
Write-ChatLine $old
$r = Invoke-SendCancel 'oldcard01'; $c = (Get-ChatItems | Where-Object id -eq 'oldcard01').card
Assert ($r -eq 'cancelled' -and $c.cancelled -eq $true -and (Get-Action $a1.id).status -eq 'cancelled' -and @($c.result).Count -ge 1) "old card (missing fields): 取消 works, no 「cannot be found」 error"
$r = Invoke-SendRetry 'oldcard01'
Assert ($r -eq 'started' -and $script:Started -contains $a1.id -and (Get-Action $a1.id).status -eq 'confirmed') "old card: 重试 after 取消 starts the send again (same action, no new card)"
$r2 = Invoke-SendRetry 'oldcard01'
Assert ($r2 -eq 'already-sending' -and @($script:Started | Where-Object { $_ -eq $a1.id }).Count -eq 1) "double click on 重试 → only one send"
$r3 = Invoke-SendCancel 'oldcard01'; Assert ($r3 -eq 'sending') "取消 while it is sending does nothing (the send checks itself and never sends a mismatch)"
# 新卡片：失败后取消
$a2 = New-SendAction '文件传输助手' '测试2' ''; $a2.status = 'failed'; Save-Action $a2
$new = Add-ChatItem @{ role = 'ai'; card = @{ kind = 'send'; actionId = $a2.id; who = '文件传输助手'; src = '微信'; text = '测试2'; opts = @('发送', '先不发'); status = 'closed'; result = @(@{ ok = $false; text = '找不到会话' }); failed = $true; cancelled = $false } }
$r = Invoke-SendCancel $new.id; $c = (Get-ChatItems | Where-Object id -eq $new.id).card
Assert ($r -eq 'cancelled' -and $c.cancelled -and @($c.result).Count -eq 2) "new card: 取消 after a failure keeps the failure line and adds 「已取消」"
$script:Sending.Clear(); $r = Invoke-SendRetry $new.id; Assert ($r -eq 'started') "new card: 重试 after 取消 works"
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $script:ok / $script:tot passed"
