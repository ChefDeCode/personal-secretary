# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 整理事项时「谁说的」的测试：用户自己的请求 → 你在等谁；看不出是谁说的 → 绝不进「需要你回」
# 只用虚构消息；不读微信、不写任何数据文件。-Cloud 时再用同一批虚构消息调用一次模型（需要 .env 和云端权限）
param([switch]$Cloud)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
# 从值守脚本里只取需要的函数和提示词（不运行它的主循环）
$ast = [Management.Automation.Language.Parser]::ParseFile("$root\12_值守.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-SpeakerCode', 'Repair-TodoSpeaker', 'Invoke-LocalRules', 'Invoke-Claude', 'Get-ApiKey' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
foreach ($as in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -in '$sysPrompt', '$schema' }, $false)) { . ([scriptblock]::Create($as.Extent.Text)) }
$stats = @{ 不确定说话人 = 0; 云端调用 = 0; 云端成功 = 0; 云端tokens入 = 0; 云端tokens出 = 0; 云端费用美元 = 0; 云端平均毫秒 = 0 }; $cloudMs = New-Object System.Collections.ArrayList

$batch = @(
  [pscustomobject]@{ 发送方 = '我'; 文本 = '你能不能明天中午之前把修改后的报价单发给我？'; 显示时间 = '' },          # 1 用户要求别人
  [pscustomobject]@{ 发送方 = '示例甲'; 文本 = '周五下午的方案你看过了吗？'; 显示时间 = '' },                      # 2 别人问用户
  [pscustomobject]@{ 发送方 = '不确定'; 文本 = '这个能不能帮我看一下？'; 显示时间 = '' },                          # 3 看不出是谁
  [pscustomobject]@{ 发送方 = '我'; 文本 = '好的，我晚点把纪要整理给你'; 显示时间 = '' },                          # 4 用户答应
  [pscustomobject]@{ 发送方 = '我'; 文本 = '记得把下周二的会议室订一下'; 显示时间 = '' })                         # 5 用户要求别人
function Run($found) { @(foreach ($f in $found) { $src = $batch[$f.原文序号 - 1]; Repair-TodoSpeaker $f $src '示例甲' }) }

# 本地规则
$r = Run @(Invoke-LocalRules $batch)
$by = @{}; foreach ($x in $r) { $by[[int]$x.原文序号] = $x }
Assert ($by[1].类别 -eq '你在等谁' -and $by[1].谁 -eq '示例甲' -and $by[1].截止) "local: the user's own request → 你在等谁 (waiting on 示例甲, keeps the deadline)"
Assert ($by[2].类别 -eq '需要你回的') "local: someone else's question → 需要你回的"
Assert (-not $by[3]) "local: unknown speaker → not listed as 需要你回的"
Assert ($by[4].类别 -eq '你答应别人的') "local: the user's promise → 你答应别人的"
Assert ($by[5].类别 -eq '你在等谁') "local: 「记得…」 from the user → 你在等谁"
# 模型说错时的硬保证（模拟模型把用户的请求判成「需要你回的」，把不确定的也判成「需要你回的」）
$bad = @([pscustomobject]@{ 类别 = '需要你回的'; 谁 = '我'; 事情 = '报价单'; 截止 = '明天中午'; 原文序号 = 1 },
         [pscustomobject]@{ 类别 = '需要你回的'; 谁 = '对方'; 事情 = '帮看一下'; 截止 = ''; 原文序号 = 3 },
         [pscustomobject]@{ 类别 = '需要你回的'; 谁 = '对方'; 事情 = '帮看一下'; 截止 = '今天'; 原文序号 = 3 },
         [pscustomobject]@{ 类别 = '你在等谁'; 谁 = '示例甲'; 事情 = '方案'; 截止 = ''; 原文序号 = 2 })
$r = Run $bad
Assert ($r[0].类别 -eq '你在等谁' -and $r[0].谁 -eq '示例甲') "guard: model said 需要你回 for the user's own message → corrected to 你在等谁"
Assert (@($r | Where-Object { $_.原文序号 -eq 3 -and $_.类别 -eq '需要你回的' }).Count -eq 0) "guard: unknown speaker never becomes 需要你回"
Assert (@($r | Where-Object { $_.原文序号 -eq 3 }).Count -eq 1 -and @($r | Where-Object { $_.原文序号 -eq 3 })[0].类别 -eq '有截止时间的') "guard: unknown speaker with a deadline is kept only as 有截止时间的"
Assert (@($r | Where-Object { $_.原文序号 -eq 2 }).Count -eq 0) "guard: 你在等谁 on someone else's message is dropped"

if ($Cloud) {
  $r = Run @(Invoke-Claude '示例甲' $batch)
  $c1 = @($r | Where-Object 原文序号 -eq 1); $c2 = @($r | Where-Object 原文序号 -eq 2); $c5 = @($r | Where-Object 原文序号 -eq 5)
  "  cloud: $($r.Count) items; categories by message: $(($r | ForEach-Object { "$($_.原文序号)=$($_.类别)" }) -join ', ')"
  Assert (-not ($r | Where-Object { $_.类别 -eq '需要你回的' -and $_.原文序号 -in 1, 3, 4, 5 })) "cloud: nothing the user said (or unknown) became 需要你回"
  Assert ($c1.Count -and $c1[0].类别 -eq '你在等谁') "cloud: the user's request → 你在等谁"
  Assert ($c2.Count -and $c2[0].类别 -eq '需要你回的') "cloud: the other person's question → 需要你回的"
}
"RESULT: $script:ok / $script:tot passed"
