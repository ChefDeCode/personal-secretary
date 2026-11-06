# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 对话（agent 回合）测试：用秘书自己的函数在一个空白的临时对话里跑，最多跑到「出现确认卡」为止；绝不发送、不碰微信
# 自带密钥和账号两条路各跑一次；不改任何设置（账号那条路是在测试里临时指定，不写配置）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . "$v2\lib_账号.ps1"
$T = Join-Path $env:TEMP 'secretary_turn_test'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null
$script:ChatFile = "$T\chat.jsonl"; $script:ChatArchive = "$T\chat_archive.jsonl"; $script:SummaryFile = "$T\summary.txt"   # 临时对话，不写进真实的对话记录
$cfgBefore = [IO.File]::ReadAllText($script:CfgPath)
$ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-HistoryMessages', 'Start-Turn', 'Send-TurnRequest', 'Poll-Turn', 'Finish-Turn', 'Start-Claude', 'Read-Claude', 'Get-ApiKey' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
foreach ($as in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -in '$stepNames', '$http' }, $false)) { . ([scriptblock]::Create($as.Extent.Text)) }
$usageFile = "$T\usage.json"; $script:Usage = [pscustomobject]@{ calls = 0; input = 0; output = 0; cacheRead = 0; usd = 0.0 }
$script:Posted = New-Object System.Collections.ArrayList
function Post($o) { [void]$script:Posted.Add($o) }; function Show-Notice($t) {}; function Write-MemUsed {}; function Write-ErrorLog {}; function Start-Compaction {}; function Post-MiniRaw {}
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
# 和秘书里一样的轮询：出错时也要把回合收掉
function Run-Turn([string]$text) {
  $script:Posted.Clear(); [void](Add-ChatItem @{ role = 'me'; text = $text }); $sw = [Diagnostics.Stopwatch]::StartNew(); $err = $null
  Start-Turn $text
  while ($script:Turn -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 200; try { Poll-Turn } catch { $err = $_.Exception.GetType().Name; if ($_.Exception -is [Management.Automation.CommandNotFoundException]) { "     missing command: $($_.Exception.CommandName)" | Out-Host }; if ($script:Turn) { Finish-Turn $null '这一步出错了' } } }
  $items = @($script:Posted | Where-Object { $_.type -eq 'item' } | ForEach-Object { $_.item })
  $busyOff = [bool]($script:Posted | Where-Object { $_.type -eq 'busy' -and -not $_.on })
  @{ ms = $sw.ElapsedMilliseconds; err = $err; stuck = [bool]$script:Turn; busyOff = $busyOff; items = $items; cards = @($items | Where-Object { $_.card }); errText = @($items | Where-Object { $_.text -match '^出错了|^没连上' }).Count; steps = @($items | ForEach-Object { $_.steps } | ForEach-Object { $_.text }) }
}
$script:ActDir = "$T\actions"; New-Item -ItemType Directory -Force $script:ActDir | Out-Null   # 待确认的发送也只写到临时文件夹
$realSendOn = Get-Switch 'send_messages'; "     your 替你发消息 switch: $(if ($realSendOn) { 'on' } else { 'off' }) (unchanged); the test also runs with it treated as on, in memory only"
$script:RealStartClaude = ${function:Start-Claude}; $sendOn = $true; $realGetSwitch = ${function:Get-Switch}; function Get-Switch([string]$k) { if ($k -eq 'send_messages') { return $true }; & $realGetSwitch $k }
"     替你发消息 switch is $(if ($sendOn) { 'on' } else { 'off' })"
foreach ($mode in 'local', 'account') {
  "— $(if ($mode -eq 'local') { '自带密钥' } else { '我们的账号' }) —"
  if ($mode -eq 'account') { if (-not (Test-SignedIn)) { "     not signed in, skipped"; continue }; function Get-AIMode { 'account' } } else { function Get-AIMode { 'local' } }
  Remove-Item "$T\chat*.jsonl" -ErrorAction SilentlyContinue   # 每次都从空白对话开始（这正是出错的情况：前面只有一句话）
  $r = Run-Turn '我今天答应过谁什么？'
  Assert (-not $r.err -and -not $r.stuck -and $r.busyOff -and -not $r.errText -and $r.items.Count) "plain question: answered, 「秘书在想…」 cleared ($($r.ms) ms; steps: $($r.steps -join '、'))"
  Remove-Item "$T\chat*.jsonl" -ErrorAction SilentlyContinue
  $r = Run-Turn '给文件传输助手发条消息说测试一下'
  $card = @($r.cards)[0]
  if ($sendOn) { Assert (-not $r.err -and -not $r.stuck -and $r.busyOff -and $card -and $card.card.status -eq 'open') "send request on a fresh chat: tool loop ok, ends at an OPEN confirm card (nothing sent) ($($r.ms) ms; steps: $($r.steps -join '、'))"
    if ($card) { Assert ($card.card.who -and $card.card.text) "confirm card shows the target chat and the draft text" } }
  else { Assert (-not $r.err -and -not $r.stuck -and $r.busyOff -and -not $r.errText) "send request with 替你发消息 off: no error, tells the user how to turn it on ($($r.ms) ms)" }
}
"— 用户原话：你发一条测试消息给微信的文件传输助手 —"
function Get-AIMode { 'local' }; Remove-Item "$T\chat*.jsonl" -ErrorAction SilentlyContinue; ${function:Start-Claude} = $script:RealStartClaude
$r = Run-Turn '你发一条测试消息给微信的文件传输助手'
$card = @($r.cards)[0]; $raw = (Get-Content $script:ChatFile | ForEach-Object { Unprotect $_ }) -join "`n"
Assert ($card -and $card.card.who -eq '文件传输助手' -and $card.card.status -eq 'open' -and $raw -notmatch '"steps":\{') "the exact sentence → OPEN confirm card to 文件传输助手 (not sent); steps stored as lists ($($r.ms) ms)""— 出错时 —"
function Get-AIMode { 'local' }; Remove-Item "$T\chat*.jsonl" -ErrorAction SilentlyContinue
function Start-Claude($body) { throw 'Claude 调用失败：HTTP 503' }   # 模拟 AI 连不上
$r = Run-Turn '测试一下出错'
$e = @($r.items | Where-Object { $_.retry })
Assert (-not $r.stuck -and $r.busyOff -and $e.Count -and $e[0].text -match '^没连上 AI' -and $e[0].retry -eq '测试一下出错') "AI unreachable → plain 「没连上 AI」 line with a 重试 button; input usable again"
Assert (([IO.File]::ReadAllText($script:CfgPath)) -eq $cfgBefore) "settings unchanged"
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $script:ok / $script:tot passed"
