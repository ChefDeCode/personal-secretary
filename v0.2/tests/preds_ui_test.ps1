# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 预测回复不卡界面：界面线程上每一轮只看后台快照（最多每 5 秒一次），不再重算「今天」；要的时候只发一次请求，结果和以前一样写进去、刷新小浮窗
. (Join-Path $PSScriptRoot 'lib_test_data.ps1'); $script:TestDataRoot = Use-TestDataFolder 'preds_ui_test'
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"
$ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-Preds', 'Save-Preds', 'New-ReplyBody', 'Test-SafeReply', 'Step-Preds', 'Find-TodoItem', 'Get-PredCandidate' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
foreach ($st in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and -not $($p = $a.Parent; while ($p -and -not ($p -is [Management.Automation.Language.FunctionDefinitionAst])) { $p = $p.Parent }; $p) -and $a.Left.Extent.Text -match '^\$script:(PredFile|PredTask|PredDay|PredCount|GenericReplies|PredNextCheck)$' }, $true)) { . ([scriptblock]::Create($st.Extent.Text)) }
$script:PredFile = Join-Path $script:V2Data 'reply_preds.json'
# 假的：不联网、不弹界面
$script:Requests = New-Object System.Collections.ArrayList; $script:Posted = 0; $script:TodayCalls = 0; $script:Cloud = $true
function Start-Claude($body) { [void]$script:Requests.Add($body); [pscustomobject]@{ IsCompleted = $true } }
function Read-Claude($task) { [pscustomobject]@{ content = @([pscustomobject]@{ type = 'text'; text = '{"options":["好的，收到","我晚点看","稍等一下"]}' }) } }
function Post-Mini { $script:Posted++ }; function Request-ReadSnapshot { }
function Get-Today { $script:TodayCalls++; @() }
function Get-Permission([string]$n) { if ($n -eq 'cloud_text') { $script:Cloud } else { $true } }
function Set-View($today, $rem = @()) { $script:ReadView = @{ today = @($today); mini = @{ reminders = @($rem) } } }
function Round([int]$n = 1) { foreach ($i in 1..$n) { Step-Preds } }
function Item($id, $extra = @{}) { $h = [ordered]@{ id = $id; group = 'reply'; done = $false; who = '测试联系人A'; conv = '测试联系人A'; what = '问你明天几点到'; quote = '明天几点到' }; foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }; [pscustomobject]$h }
# 1) 没有要预测的：200 轮又快又不碰「今天」
Set-View @((Item 'a1' @{ preds = @('好的') }))
$ms = foreach ($i in 1..200) { $script:PredNextCheck = $null; $sw = [Diagnostics.Stopwatch]::StartNew(); Step-Preds; $sw.Elapsed.TotalMilliseconds }
$sorted = @($ms | Sort-Object); $med = $sorted[99]
Check "200 rounds never rebuild 「今天」 on the UI thread (Get-Today calls: $($script:TodayCalls)), median $([Math]::Round($med, 2)) ms" ($script:TodayCalls -eq 0 -and $med -lt 5)
Check 'an item that already has a prediction in the snapshot gets no request' ($script:Requests.Count -eq 0)
# 2) 节流：5 秒内只看一次
$script:PredNextCheck = $null; Set-View @((Item 'b1')); Round 1; $first = $script:Requests.Count; Round 20
Check "one new reply item -> exactly one request, even over 20 more rounds within 5 s ($($script:Requests.Count))" ($first -eq 1 -and $script:Requests.Count -eq 1)
Check 'the request is the same reply-draft request as before (3 short options, quote as data)' ([string]$script:Requests[0].system -match '3 句' -and [string]$script:Requests[0].messages[0].content -match '<message>明天几点到</message>')
# 3) 结果回来：写进预测、刷新小浮窗，和以前一样
Round 1; $h = Get-Preds
Check "the result is saved like before (3 options, not fallback) and the mini window is refreshed ($script:Posted)" (@($h['b1'].opts).Count -eq 3 -and -not $h['b1'].fallback -and $script:Posted -eq 1)
# 4) 快照还没刷新（还没带上 preds）：已经存过的那条不再重复要
$script:PredNextCheck = $null; Round 1
Check 'a just-saved item whose snapshot is not refreshed yet is not requested again' ($script:Requests.Count -eq 1)
# 5) 「等你回复」的提醒对应的那条也会预测
$script:PredNextCheck = $null; Set-View @((Item 'c1' @{ group = 'waiting' })) @([pscustomobject]@{ id = 'reply|t:c1' }); Round 1
Check 'the item behind a 「等你回复」 reminder is predicted too' ($script:Requests.Count -eq 2)
Round 1   # 让它的结果回来
# 6) 不允许把文字发到云端：一次都不要
$script:Cloud = $false; $script:PredNextCheck = $null; Set-View @((Item 'd1')); Round 1
Check 'with 「云端看文字」 off nothing is requested' ($script:Requests.Count -eq 2)
# 7) 已经做完的不要
$script:Cloud = $true; $script:PredNextCheck = $null; Set-View @((Item 'e1' @{ done = $true })); Round 1
Check 'a reply item that is already done gets no request' ($script:Requests.Count -eq 2)
"preds_ui_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
