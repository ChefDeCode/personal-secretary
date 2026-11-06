# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 「谁说的」判断的模拟测试：自己画聊天区（左右气泡、浅色 / 深色、单聊 / 群聊、100% / 150% 缩放），用本机 OCR 读，再判断每一行是谁说的
# 不碰微信、不发任何鼠标键盘输入；所有文字都是虚构的。同时用旧规则（只看文字行位置）跑一遍做对比。
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root\lib_识别.ps1"
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0

$themes = @{
  light = @{ bg = [Drawing.Color]::FromArgb(237, 237, 237); self = [Drawing.Color]::FromArgb(149, 236, 105); other = [Drawing.Color]::White; text = [Drawing.Color]::FromArgb(25, 25, 25); name = [Drawing.Color]::FromArgb(150, 150, 150) }
  dark  = @{ bg = [Drawing.Color]::FromArgb(17, 17, 17); self = [Drawing.Color]::FromArgb(62, 166, 98); other = [Drawing.Color]::FromArgb(44, 44, 44); text = [Drawing.Color]::FromArgb(220, 220, 220); name = [Drawing.Color]::FromArgb(110, 110, 110) }
}
# 一段对话：side = self / other；lines = 气泡里的每一行；group 里别人的气泡上方有名字
$convo = @(
  @{ side = 'other'; lines = @('周五下午的方案你看过了吗') },
  @{ side = 'self';  lines = @('看过了') },
  @{ side = 'self';  lines = @('你能不能明天中午之前把修改后的报价单发给我，我要拿去和老板确认一下') },   # 以前被当成别人说的：一行很宽
  @{ side = 'self';  lines = @('另外麻烦你把上次会议的纪要也整理一份，', '重点写清楚每个人负责的部分和时间，', '周四前给我') },  # 多行：最后一行很短、靠左
  @{ side = 'other'; lines = @('好的，我明天中午前把报价单和纪要都发给你，有问题再找你确认') },
  @{ side = 'other'; lines = @('对了，下周二的会议室你订了吗？', '我这边还没收到通知') },
  @{ side = 'self';  lines = @('还没，我下午订') }
)
function New-Chat([string]$theme, [double]$dpi, [bool]$group) {
  $th = $themes[$theme]; $cw = [int](720 * $dpi); $font = New-Object Drawing.Font 'Microsoft YaHei', ([float](14 * $dpi)), ([Drawing.GraphicsUnit]::Pixel)
  $nameFont = New-Object Drawing.Font 'Microsoft YaHei', ([float](12 * $dpi)), ([Drawing.GraphicsUnit]::Pixel)
  $lh = [int](22 * $dpi); $pad = [int](12 * $dpi); $side = [int](66 * $dpi); $maxW = $cw - $side - [int](120 * $dpi)   # 气泡最宽：另一侧留出头像位
  $hgt = 0; foreach ($b in $convo) { $hgt += $b.lines.Count * $lh + 2 * $pad + [int](16 * $dpi) + $(if ($group -and $b.side -eq 'other') { [int](18 * $dpi) } else { 0 }) }
  $bmp = New-Object Drawing.Bitmap $cw, ($hgt + [int](20 * $dpi)); $g = [Drawing.Graphics]::FromImage($bmp); $g.TextRenderingHint = 'ClearTypeGridFit'; $g.Clear($th.bg)
  $truth = New-Object System.Collections.ArrayList; $y = [int](10 * $dpi); $names = @('示例甲', '示例乙'); $ni = 0
  foreach ($b in $convo) {
    if ($group -and $b.side -eq 'other') { $g.DrawString($names[$ni++ % 2], $nameFont, (New-Object Drawing.SolidBrush $th.name), [float]($side + 2 * $dpi), [float]$y); [void]$truth.Add(@{ y0 = $y; y1 = $y + [int](18 * $dpi); side = 'name' }); $y += [int](18 * $dpi) }
    $tw = ($b.lines | ForEach-Object { [int][Math]::Ceiling($g.MeasureString($_, $font).Width) } | Measure-Object -Maximum).Maximum
    $bw = [Math]::Min($maxW, $tw + 2 * $pad); $bh = $b.lines.Count * $lh + 2 * $pad
    $bx = if ($b.side -eq 'self') { $cw - $side - $bw } else { $side }
    $g.FillRectangle((New-Object Drawing.SolidBrush $th.($b.side)), $bx, $y, $bw, $bh)
    $ly = $y + $pad; foreach ($ln in $b.lines) { $g.DrawString($ln, $font, (New-Object Drawing.SolidBrush $th.text), [float]($bx + $pad), [float]$ly); $ly += $lh }
    [void]$truth.Add(@{ y0 = $y; y1 = $y + $bh; side = $b.side }); $y += $bh + [int](16 * $dpi)
  }
  $g.Dispose(); @{ bmp = $bmp; truth = $truth; cw = $cw; bgLum = [int](($th.bg.R * 299 + $th.bg.G * 587 + $th.bg.B * 114) / 1000) }
}
function Old-Speaker($l, $cw) { if ($l.x1 / $cw -gt 0.78 -and $l.x0 / $cw -gt 0.35) { 'self' } elseif ($l.x0 / $cw -lt 0.30) { 'other' } else { 'unknown' } }

$tally = @{ new = @{ right = 0; wrong = 0; unknown = 0 }; old = @{ right = 0; wrong = 0; unknown = 0 } }; $selfAsOther = 0; $oldSelfAsOther = 0; $n = 0
foreach ($theme in 'light', 'dark') { foreach ($dpi in 1.0, 1.5) { foreach ($group in $false, $true) {
  $c = New-Chat $theme $dpi $group; $lines = @(Get-Lines (Invoke-Ocr $c.bmp)); $r = @{ right = 0; wrong = 0; unknown = 0 }
  foreach ($l in $lines) {
    $cy = $l.y + $l.h / 2; $tr = $c.truth | Where-Object { $cy -ge $_.y0 -and $cy -le $_.y1 } | Select-Object -First 1
    if (-not $tr -or $tr.side -eq 'name') { continue }   # 名字行由后面的群聊逻辑单独处理
    $n++; $sp = Get-LineSpeaker $c.bmp $l $c.cw $dpi $c.bgLum; $od = Old-Speaker $l $c.cw
    if ($sp -eq 'unknown') { $tally.new.unknown++; $r.unknown++ } elseif ($sp -eq $tr.side) { $tally.new.right++; $r.right++ } else { $tally.new.wrong++; $r.wrong++; if ($tr.side -eq 'self') { $selfAsOther++ } }
    if ($od -eq 'unknown') { $tally.old.unknown++ } elseif ($od -eq $tr.side) { $tally.old.right++ } else { $tally.old.wrong++; if ($tr.side -eq 'self') { $oldSelfAsOther++ } }
  }
  "  $theme / $([int]($dpi * 100))% / $(if ($group) { '群聊' } else { '单聊' })：OCR 行 $($lines.Count)，判对 $($r.right)，判错 $($r.wrong)，不确定 $($r.unknown)"
  $c.bmp.Dispose()
} } }
$acc = [Math]::Round(100.0 * $tally.new.right / [Math]::Max(1, $n), 1); $oacc = [Math]::Round(100.0 * $tally.old.right / [Math]::Max(1, $n), 1)
"  新规则：$n 行里判对 $($tally.new.right)（$acc%），判错 $($tally.new.wrong)，不确定 $($tally.new.unknown)；自己说的被当成别人说的：$selfAsOther"
"  旧规则：判对 $($tally.old.right)（$oacc%），判错 $($tally.old.wrong)，不确定 $($tally.old.unknown)；自己说的被当成别人说的：$oldSelfAsOther"
Assert ($n -ge 40) "enough OCR lines measured ($n)"
Assert ($tally.new.wrong -eq 0) "new rule: no line attributed to the wrong person"
Assert ($selfAsOther -eq 0) "new rule: nothing the user said is attributed to someone else"
Assert ($acc -ge 95) "new rule accuracy ≥ 95% ($acc%)"
Assert ($oldSelfAsOther -gt 0) "the old rule reproduces the reported bug ($oldSelfAsOther self lines taken as the other person's)"

# 矛盾时记「不确定」：右边的气泡涂成别人的颜色
$bmp = New-Object Drawing.Bitmap 720, 80; $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear($themes.light.bg); $g.FillRectangle([Drawing.Brushes]::White, 420, 10, 234, 46)
$g.DrawString('这是一条测试消息', (New-Object Drawing.Font 'Microsoft YaHei', 14, ([Drawing.GraphicsUnit]::Pixel)), [Drawing.Brushes]::Black, 432, 22); $g.Dispose()
$l = @(Get-Lines (Invoke-Ocr $bmp))[0]; Assert ((Get-LineSpeaker $bmp $l 720 1.0 237) -eq 'unknown') "position says self, colour says other → unknown (never guessed)"
$script:WxSelfSide = 'left'; $bmp2 = New-Object Drawing.Bitmap 720, 80; $g = [Drawing.Graphics]::FromImage($bmp2); $g.Clear($themes.light.bg); $g.FillRectangle((New-Object Drawing.SolidBrush $themes.light.self), 66, 10, 200, 46)
$g.DrawString('左边是我自己', (New-Object Drawing.Font 'Microsoft YaHei', 14, ([Drawing.GraphicsUnit]::Pixel)), [Drawing.Brushes]::Black, 78, 22); $g.Dispose()
$l = @(Get-Lines (Invoke-Ocr $bmp2))[0]; Assert ((Get-LineSpeaker $bmp2 $l 720 1.0 237) -eq 'self') "adapter self_side = left: a green bubble on the left is the user"
$script:WxSelfSide = $null; $bmp.Dispose(); $bmp2.Dispose()
"RESULT: $script:ok / $script:tot passed"
