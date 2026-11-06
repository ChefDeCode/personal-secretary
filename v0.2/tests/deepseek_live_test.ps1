# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# DeepSeek 真实测试（用户给的测试密钥，已加密存在设置里）：测试连接、一句短对话、一次只到确认卡的发送请求、一次「明远」认人、错误密钥的提示；
# 另外确认 Claude（.env）和我们的账号两条路照常。用设置的副本跑，测完用户的选择不变；不显示任何密钥；不发送任何消息
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . "$v2\lib_账号.ps1"
$T = Join-Path $env:TEMP 'secretary_ds_test'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\actions" | Out-Null
$realCfg = $script:CfgPath; $before = [IO.File]::ReadAllText($realCfg); Copy-Item $realCfg "$T\config.json"; $script:CfgPath = "$T\config.json"
. "$v2\lib_AI源.ps1"
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$c = Get-AiCfg; $c.provider = 'deepseek'; Save-AiCfg $c   # 只改副本
$tk = Test-ProviderKey 'deepseek'; Assert $tk.ok "DeepSeek 测试连接: $($tk.text)"
# 对话（用秘书自己的回合代码；临时对话；虚构联系人）
$script:ChatFile = "$T\chat.jsonl"; $script:ChatArchive = "$T\chat_archive.jsonl"; $script:SummaryFile = "$T\summary.txt"; $script:ActDir = "$T\actions"; $script:PeopleFile = "$T\people.jsonl"
$ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-HistoryMessages', 'Start-Turn', 'Send-TurnRequest', 'Poll-Turn', 'Finish-Turn', 'Start-Claude', 'Read-Claude', 'Get-ApiKey', 'On-PersonChoice' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
foreach ($as in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -in '$stepNames', '$http' }, $false)) { . ([scriptblock]::Create($as.Extent.Text)) }
$usageFile = "$T\usage.json"; $script:Usage = [pscustomobject]@{ calls = 0; input = 0; output = 0; cacheRead = 0; usd = 0.0 }; $script:Posted = New-Object System.Collections.ArrayList
function Post($o) { [void]$script:Posted.Add($o) }; function Show-Notice($t) {}; function Write-MemUsed {}; function Write-ErrorLog {}; function Start-Compaction {}; function Post-MiniRaw {}
$script:Src = @{ chats = @(@{ app = '微信'; title = 'Leo明远'; last = '2026-10-31T20:00:00' }, @{ app = '微信'; title = '王明远'; last = '2026-10-20T10:00:00' }, @{ app = '微信'; title = '文件传输助手'; last = '' }); senders = @() }
function Get-PeopleSources { $script:Src }; function Get-ConvNames { @($script:Src.chats | ForEach-Object { $_.title }) }
$realGetSwitch = ${function:Get-Switch}; function Get-Switch([string]$k) { if ($k -eq 'send_messages') { return $true }; & $realGetSwitch $k }
function Wait-Turn { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($script:Turn -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 200; try { Poll-Turn } catch { if ($script:Turn) { Finish-Turn $null '这一步出错了' } } } }
function Run([string]$q) { Remove-Item "$T\chat*.jsonl" -ErrorAction SilentlyContinue; $script:Posted.Clear(); [void](Add-ChatItem @{ role = 'me'; text = $q }); $sw = [Diagnostics.Stopwatch]::StartNew(); Start-Turn $q; Wait-Turn
  @{ ms = $sw.ElapsedMilliseconds; items = @($script:Posted | Where-Object { $_.type -eq 'item' } | ForEach-Object { $_.item }); errs = @($script:Posted | Where-Object { $_.type -eq 'item' -and $_.item.text -match '^出错了|^没连上' }).Count } }
function Get-AIMode { 'local' }
"— DeepSeek —"
$r = Run '用一句话回答：1+1 等于几'; Assert ($r.items.Count -and -not $r.errs -and ($r.items[-1].text -match '2|二')) "short plain chat ($($r.ms) ms)"
$r = Run '给文件传输助手发条消息说【测试】你好'; $sc = @($r.items | Where-Object { $_.card.kind -eq 'send' } | ForEach-Object { $_.card })
Assert ($sc.Count -eq 1 -and $sc[0].who -eq '文件传输助手' -and $sc[0].status -eq 'open') "send request → tool loop → OPEN confirm card, nothing sent ($($r.ms) ms)"
$r = Run '给明远发条消息说明天见'; $pc = @($r.items | Where-Object { $_.card.kind -eq 'person' })
Assert ($pc.Count -eq 1 -and (@($pc[0].card.cands | ForEach-Object { $_.title }) -contains 'Leo明远')) "「明远」 → asks which person (Leo明远 / 王明远) ($($r.ms) ms)"
$vis = Test-ProviderVision; "     vision with $($vis.model): $($vis.ok)"
$c = Get-AiCfg; $good = $c.keys.deepseek; $c.keys | Add-Member deepseek (Protect-Key 'sk-00000000000000000000000000000000') -Force; Save-AiCfg $c
$tw = Test-ProviderKey 'deepseek'; Assert (-not $tw.ok -and $tw.text -match '密钥不对') "wrong key → 「$($tw.text)」"
$c = Get-AiCfg; $c.keys | Add-Member deepseek $good -Force; $c.provider = 'anthropic'; Save-AiCfg $c
"— 其它两条路照常 —"
$r = Run '用一句话回答：2+2 等于几'; Assert ($r.items.Count -and -not $r.errs) "Claude (your existing key) plain chat ($($r.ms) ms)"
if (Test-SignedIn) { function Get-AIMode { 'account' }; $r = Run '用一句话回答：3+3 等于几'; Assert ($r.items.Count -and -not $r.errs) "our account plain chat ($($r.ms) ms)" }
$script:CfgPath = $realCfg
Assert (([IO.File]::ReadAllText($realCfg)) -eq $before) "your settings unchanged (source still 自带密钥 · Claude; DeepSeek key stays saved)"
$leak = @(Get-ChildItem (Split-Path $v2 -Parent) -Recurse -File -Include *.json, *.jsonl, *.log, *.txt -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\webview2' -and $_.Length -lt 20MB -and $(try { [IO.File]::ReadAllText($_.FullName).Contains($dk) } catch { $false }) }).Count
Assert ($dk -and $dk.Length -gt 20 -and $leak -eq 0) "key not in plain text in any settings / log / data file ($leak)"
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $script:ok / $script:tot passed"
