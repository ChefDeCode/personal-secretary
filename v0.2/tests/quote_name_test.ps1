# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 「谁说的」和「叫什么名字」（例如「跟对方确认几点到」）：
# 1) 回复别人时微信在你的气泡下面显示「名字：原话」的引用框 —— 它是别人以前说的，不能并进你这条里当成你说的（深色 / 浅色、单聊 / 群聊、两边都有）
# 2) 单聊里「对方」显示成聊天名字；群聊、网页、文件不换；提醒的话里也是名字
# 自己画聊天区、本机 OCR 认字；虚构内容，不碰微信
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $root = Split-Path $v2 -Parent
. "$root\lib_识别.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$themes = @{
  light = @{ bg = [Drawing.Color]::FromArgb(237, 237, 237); self = [Drawing.Color]::FromArgb(149, 236, 105); other = [Drawing.Color]::White; text = [Drawing.Color]::FromArgb(25, 25, 25); quoteBg = [Drawing.Color]::FromArgb(226, 226, 226); quote = [Drawing.Color]::FromArgb(120, 120, 120); name = [Drawing.Color]::FromArgb(150, 150, 150) }
  dark  = @{ bg = [Drawing.Color]::FromArgb(30, 30, 30); self = [Drawing.Color]::FromArgb(53, 210, 141); other = [Drawing.Color]::FromArgb(47, 47, 48); text = [Drawing.Color]::FromArgb(25, 25, 25); otherText = [Drawing.Color]::FromArgb(220, 220, 220); quoteBg = [Drawing.Color]::FromArgb(40, 40, 40); quote = [Drawing.Color]::FromArgb(140, 140, 140); name = [Drawing.Color]::FromArgb(110, 110, 110) }
}
# 一段对话：别人问 → 你回复并引用了他那句 → 别人再说 → 别人回复并引用了你那句（群聊里别人的气泡上面有名字）
$convo = @(
  @{ side = 'other'; text = '周末你几点到' },
  @{ side = 'self'; text = '我九点左右到'; quote = '示例甲：周末你几点到' },
  @{ side = 'other'; text = '好的那我晚点过来' },
  @{ side = 'other'; text = '收到了谢谢'; quote = '我：我九点左右到' }
)
function New-Chat([string]$theme, [double]$dpi, [bool]$group) {
  $th = $themes[$theme]; $cw = [int](720 * $dpi); $font = New-Object Drawing.Font 'Microsoft YaHei', ([float](14 * $dpi)), ([Drawing.GraphicsUnit]::Pixel); $qf = New-Object Drawing.Font 'Microsoft YaHei', ([float](12 * $dpi)), ([Drawing.GraphicsUnit]::Pixel)
  $pad = [int](12 * $dpi); $side = [int](66 * $dpi); $lh = [int](22 * $dpi)
  $bmp = New-Object Drawing.Bitmap $cw, ([int](560 * $dpi)); $g = [Drawing.Graphics]::FromImage($bmp); $g.TextRenderingHint = 'ClearTypeGridFit'; $g.Clear($th.bg); $y = [int](12 * $dpi)
  foreach ($b in $convo) {
    if ($group -and $b.side -eq 'other') { $g.DrawString('示例甲', $qf, (New-Object Drawing.SolidBrush $th.name), [float]($side + 2 * $dpi), [float]$y); $y += [int](18 * $dpi) }
    $tw = [int][Math]::Ceiling($g.MeasureString($b.text, $font).Width); $bw = $tw + 2 * $pad; $bh = $lh + 2 * $pad
    $bx = if ($b.side -eq 'self') { $cw - $side - $bw } else { $side }
    $g.FillRectangle((New-Object Drawing.SolidBrush $th.($b.side)), $bx, $y, $bw, $bh)
    $tc = if ($b.side -eq 'other' -and $th.otherText) { $th.otherText } else { $th.text }
    $g.DrawString($b.text, $font, (New-Object Drawing.SolidBrush $tc), [float]($bx + $pad), [float]($y + $pad)); $y += $bh + [int](6 * $dpi)
    if ($b.quote) {   # 引用框：小一号的灰字、浅灰底，贴着气泡下面、和气泡同一侧
      $qw = [int][Math]::Ceiling($g.MeasureString($b.quote, $qf).Width) + 2 * [int](8 * $dpi); $qh = [int](30 * $dpi); $qx = if ($b.side -eq 'self') { $cw - $side - $qw } else { $side }
      $g.FillRectangle((New-Object Drawing.SolidBrush $th.quoteBg), $qx, $y, $qw, $qh); $g.DrawString($b.quote, $qf, (New-Object Drawing.SolidBrush $th.quote), [float]($qx + 8 * $dpi), [float]($y + 6 * $dpi)); $y += $qh }
    $y += [int](16 * $dpi)
  }
  $g.Dispose(); @{ bmp = $bmp; cw = $cw; bgLum = [int](($th.bg.R * 299 + $th.bg.G * 587 + $th.bg.B * 114) / 1000) }
}
foreach ($theme in 'dark', 'light') { foreach ($group in $false, $true) {
  $dpi = 2.0; $c = New-Chat $theme $dpi $group; $lines = @(Get-Lines (Invoke-Ocr $c.bmp)); $items = New-Object System.Collections.ArrayList
  foreach ($l in $lines) { $k = switch (Get-LineSpeaker $c.bmp $l $c.cw $dpi $c.bgLum) { 'self' { '我' } 'other' { '对方' } default { '不确定' } }
    [void]$items.Add([pscustomobject]@{ y = $l.y; x0 = $l.x0; x1 = $l.x1; 类 = $k; 文本 = $l.文本; 图片 = $false; 路 = [string]$script:LastSpkPath }) }
  $msgs = @(Join-ChatLines $items $dpi); $c.bmp.Dispose()
  $tag = "$theme / $(if ($group) { 'group' } else { '1:1' })"
  $mine = @($msgs | Where-Object { $_.文本 -match '九点左右' })[0]; $ask = @($msgs | Where-Object { $_.文本 -match '^周末你几点' })[0]; $thanks = @($msgs | Where-Object { $_.文本 -match '收到了' })[0]
  Check "[$tag] the other person's question stays theirs ($(if ($ask) { $ask.发送方 } else { 'not read' }))" ($ask -and $ask.发送方 -ne '我' -and $ask.发送方 -ne '不确定')
  Check "[$tag] your reply is yours, and the quoted line is marked as a quote, not as your words ($(if ($mine) { $mine.发送方 + ' / quote=' + [bool]$mine.引用 } else { 'not read' }))" ($mine -and $mine.发送方 -eq '我' -and $mine.引用 -and $mine.文本 -match '（引用 .*几点到')
  Check "[$tag] nobody is filed as having said the quoted text on its own ($(@($msgs | Where-Object { $_.文本 -match '^\s*示例甲[：:]' }).Count) stray lines)" (-not @($msgs | Where-Object { $_.文本 -match '^\s*示例甲[：:]' -or $_.文本 -match '^\s*我[：:]这有' }).Count)
  Check "[$tag] a quote under someone else's message is attached to theirs ($(if ($thanks) { $thanks.发送方 + ' / quote=' + [bool]$thanks.引用 } else { 'not read' }))" ($thanks -and $thanks.发送方 -ne '我' -and $thanks.引用)
  if ($group) { Check "[$tag] in a group the speaker name is used, the quote is never taken for a name ($(@($msgs | ForEach-Object 发送方 | Sort-Object -Unique) -join ','))" (-not @($msgs | Where-Object { $_.发送方 -match '[：:]' }).Count -and @($msgs | Where-Object 发送方 -eq '示例甲').Count -ge 1) }
} }
# 2) 名字：单聊里的「对方」显示成聊天名字
$T = Join-Path $env:TEMP 'secretary_quote_name'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null
. "$v2\lib_v2.ps1"; $script:DataDir = $T; $script:V2Data = $T; $script:RemDir = $T; $script:DoneFile = "$T\done.json"; $script:CfgPath = "$T\config.json"; [IO.File]::WriteAllText($script:CfgPath, '{"features":{"proactive":true}}')
Check '1:1 chat: 「跟对方确认几点到」 shows the name' ((Resolve-Other '跟对方确认几点到' '小满') -eq '跟小满确认几点到')
Check 'group / web page / file / mail: left as is' ((Resolve-Other '等对方回复' '示例群') -eq '等对方回复' -and (Resolve-Other '等对方回复' '某某（12）') -eq '等对方回复' -and (Resolve-Other '对方' '网页：example.com') -eq '对方' -and (Resolve-Other '对方' 'Outlook 邮件') -eq '对方')
Check 'no chat name known -> left as is (never guesses a name)' ((Resolve-Other '问对方' '') -eq '问对方')
$ts = (Get-Date).AddDays(-2).ToString('s')
[IO.File]::WriteAllLines("$T\todos.jsonl", [string[]]@((@{ ts = $ts; 类别 = '你在等谁'; 事情 = (Protect '等对方交周报'); 谁 = (Protect '对方'); 截止 = (Protect ''); conv = (Protect '小满'); app = '微信'; 原文时间 = $ts } | ConvertTo-Json -Compress)))
$todayRow = @(Get-Today)[0]; Check "today list row uses the name ($($todayRow.who) / $($todayRow.what))" ($todayRow.who -eq '小满' -and $todayRow.what -eq '等小满交周报')
$rc = @(Get-ReminderCandidates (Get-Date) | Where-Object { $_.id -like 'wait|*' })[0]; Check "the 1-day nudge names the person, not 「对方」 ($($rc.text -replace '：.*', ''))" ($rc.text -like '你在等小满的回复*' -and $rc.text -notmatch '对方')
# 3) 整理时模型看到的发言人：单聊里写名字；提示词说明「引用」不是发送人说的；影子对比用的是同一份请求
$w = [IO.File]::ReadAllText("$root\12_值守.ps1")
Check 'extraction labels 1:1 lines with the chat name, explains quotes, and the Haiku shadow reuses the same request' ($w -match '\$oneToOne' -and $w -match '（引用 名字：原话）' -and $w -match 'Start-HaikuShadow \$req')
$r = [IO.File]::ReadAllText("$root\lib_识别.ps1"); Check 'title: taller crop, and the selected chat in the list is used when the title cannot be read' ($r -match 'list-row' -and $r -match '\$titleRect = New-Object Drawing.Rectangle \$cl, 0,')
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"quote_name_test: $pass pass, $fail fail"
