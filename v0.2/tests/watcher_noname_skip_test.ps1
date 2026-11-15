# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 微信这一轮没认出聊天名（标题来源 none）：不存消息、记一次跳过、不推进「见过」和首屏基线；下一次认出名字时同样的消息照常存一次。标题 / 列表行照旧。
# 只在后台跑：从 12_值守.ps1 取出 Save-Messages / Save-WeChatRead 两个函数，其它全用假的；不读屏、不开窗口、不碰真数据
. "$PSScriptRoot\lib_synthetic_test.ps1"
Import-TestFunctions "$productRoot\12_值守.ps1" @('Save-Messages', 'Save-WeChatRead')
function KeyOf([string]$s) { $sha = [Security.Cryptography.SHA256]::Create(); try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').Substring(0, 32) } finally { $sha.Dispose() } }
function Protect([string]$s) { 'enc:' + $s }
function Get-Feature($n) { $false }; function Get-Permission($n) { $false }
function Get-SpeakerCode($s) { if ($s -eq '我') { 'self' } else { 'other' } }
function Add-PersistentMessages($recs) { foreach ($r in @($recs)) { $script:Saved.Add($r) } }
function Reset {
  $script:seen = New-Object 'System.Collections.Generic.HashSet[string]'; $script:seenContent = New-Object 'System.Collections.Generic.HashSet[string]'; $script:knownConv = New-Object 'System.Collections.Generic.HashSet[string]'
  $script:imgCalls = New-Object System.Collections.ArrayList; $script:stats = [ordered]@{ 去重跳过 = 0; 首屏基线 = 0; 新消息 = 0; 错误 = 0; 说话人_self = 0; 说话人_other = 0 }
  $script:Saved = New-Object System.Collections.Generic.List[object]; $script:lastFp = 'fp'; $script:NoNameRetry = 0
}
function Msgs { @([pscustomobject]@{ 发送方 = '对方'; 文本 = '示例一'; 图片 = $false }, [pscustomobject]@{ 发送方 = '我'; 文本 = '示例二'; 图片 = $false }) }
function ReadOf([string]$from, [string]$conv) { @{ 会话 = $conv; 消息 = @(Msgs); 列表 = @(); 标题来源 = $from } }
try {
  # 1) none：什么都不存，计数 +1，「见过这个聊天」和去重记录都不动，画面记录清掉（下一轮再认）
  Reset; $r = Save-WeChatRead (ReadOf 'none' '') $false
  Check 'title source none -> nothing saved' ($script:Saved.Count -eq 0 -and $r.skipped -and $r.saved -eq 0)
  Check 'skip counter goes up by one' ([int]$stats.没认出聊天名跳过 -eq 1)
  Check 'no chat marked as seen, no message keys remembered' ($knownConv.Count -eq 0 -and $seen.Count -eq 0 -and $seenContent.Count -eq 0)
  Check 'the screen fingerprint is cleared so the next round reads again' ($null -eq $lastFp)
  Check 'no first-screen or new-message counts moved' ($stats.首屏基线 -eq 0 -and $stats.新消息 -eq 0)
  # 2) 下一次认出名字：同样的消息存一次（新消息，不是首屏基线——因为之前没存过、这也不是第一次看就记基线的情况由调用方决定）
  $r = Save-WeChatRead (ReadOf 'title' '示例聊天') $false
  Check "next named read saves the same messages once ($($script:Saved.Count))" ($script:Saved.Count -eq 2 -and -not $r.skipped -and $r.saved -eq 2)
  Check 'they are saved under the chat name' (@($script:Saved | Where-Object { $_.conv -eq 'enc:示例聊天' }).Count -eq 2)
  $r = Save-WeChatRead (ReadOf 'title' '示例聊天') $false
  Check 'reading the same screen again does not save them twice' ($script:Saved.Count -eq 2 -and $r.saved -eq 0)
  # 首屏基线：none 那一轮不算「第一次看到这个聊天」，下一次有名字的首屏读照旧记基线
  Reset; [void](Save-WeChatRead (ReadOf 'none' '') $true); $r = Save-WeChatRead (ReadOf 'title' '示例聊天') $true
  Check 'a skipped round does not use up the first-screen baseline' ($script:Saved.Count -eq 2 -and @($script:Saved | Where-Object { $_.baseline }).Count -eq 2 -and $stats.首屏基线 -eq 2)
  # 3) 连续 none：最多 3 次清画面记录，之后不再清（省得一直重认同一屏）
  Reset; foreach ($i in 1..5) { $script:lastFp = 'fp'; [void](Save-WeChatRead (ReadOf 'none' '') $false) }
  Check 'after 3 skips in a row the fingerprint is kept (no endless re-reading)' ($lastFp -eq 'fp' -and [int]$stats.没认出聊天名跳过 -eq 5)
  $script:lastFp = 'fp'; [void](Save-WeChatRead (ReadOf 'title' '示例聊天') $false); $script:lastFp = 'fp'; [void](Save-WeChatRead (ReadOf 'none' '') $false)
  Check 'a named read resets the retry allowance' ($null -eq $lastFp)
  # 4) 标题直接认出 / 靠列表行补上：和以前完全一样
  Reset; $a = Save-WeChatRead (ReadOf 'title' '示例聊天') $false; $n1 = $script:Saved.Count
  Reset; $b = Save-WeChatRead (ReadOf 'list-row' '示例聊天') $false; $n2 = $script:Saved.Count
  Reset; $c = Save-Messages '示例聊天' @(Msgs) $false; $n3 = $script:Saved.Count
  Check 'title and list-row reads save exactly what Save-Messages saves' ($n1 -eq 2 -and $n2 -eq 2 -and $n3 -eq 2 -and -not $a.skipped -and -not $b.skipped -and [int]$stats.没认出聊天名跳过 -eq 0)
  Check 'title and list-row reads keep the fingerprint' ($lastFp -eq 'fp')
  # 5) 只在微信「屏幕直接读」的那一处调用；其它来源（快照、透明还原、文件夹、邮件）不经过它
  $w = [IO.File]::ReadAllText("$productRoot\12_值守.ps1")
  Check 'the WeChat round saves through Save-WeChatRead (the only direct save of $res is inside it)' ($w -match 'Save-WeChatRead \$res \(-not \$curUnread\)' -and ([regex]::Matches($w, 'Save-Messages \$res\.会话 \$res\.消息')).Count -eq 1)
  Check 'only one caller of Save-WeChatRead' (([regex]::Matches($w, 'Save-WeChatRead \$')).Count -eq 1)
  Check 'the read log line carries skip and the numbers-only diagnostics' ($w -match 'ev = ''read'';[^\r\n]*skip = \[int\]\(\[string\]\$res\.标题来源 -eq ''none''\); diag = \$res\.诊断')
  # 6) 诊断只有数字
  $ast = [Management.Automation.Language.Parser]::ParseFile("$productRoot\lib_识别.ps1", [ref]$null, [ref]$null)
  $fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-WeChat' }, $true) | Select-Object -First 1
  $dl = ($fn.Extent.Text -split "`n" | Where-Object { $_ -match '\$diag = ' }) -join ''
  $keys = @([regex]::Matches($dl, '(\w+) = ') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'diag' })
  Check "diagnostics carry the agreed numbers ($($keys -join ','))" ((@('lay', 'title_h', 'title_lines', 'list_rows', 'sel_diff') | Where-Object { $keys -notcontains $_ }).Count -eq 0)
  Check 'diagnostics hold no text (only counts, sizes, ratios)' ($dl -notmatch '\$title\b|会话|文本|\$tl\[|\$list\[|\.会话|\.文本' -and $fn.Extent.Text -match '标题来源 = \$titleFrom; 诊断 = \$diag')
} finally { }
Done-Test
