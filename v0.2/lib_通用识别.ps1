# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_通用识别.ps1 — 通用聊天界面识别器：按“适配”（版面配置，适配.ps1 生成）在本机做 OCR，读出消息（我/对方）和会话列表（名字、未读）
# 只读：只处理已经捕获好的窗口图片；不点击、不输入、不联网。调用方先 dot-source lib_窗口工具.ps1 和 lib_识别.ps1，并设置 $script:GDpi（窗口缩放，200% = 2）
# —— 通用识别器：按版面在本机做 OCR ——
function To-Rect($b, [int]$w, [int]$ht) {
  if (-not $b -or -not $b.present) { return $null }
  $x0 = [Math]::Max(0.0, [Math]::Min(1.0, [double]$b.x0)); $x1 = [Math]::Max(0.0, [Math]::Min(1.0, [double]$b.x1)); $y0 = [Math]::Max(0.0, [Math]::Min(1.0, [double]$b.y0)); $y1 = [Math]::Max(0.0, [Math]::Min(1.0, [double]$b.y1))   # 必须写 0.0/1.0：写 0/1 会选到整数重载，比例全被截成 0
  if ($x1 - $x0 -lt 0.05 -or $y1 - $y0 -lt 0.05) { return $null }
  New-Object Drawing.Rectangle ([int]($x0 * $w)), ([int]($y0 * $ht)), ([int](($x1 - $x0) * $w)), ([int](($y1 - $y0) * $ht))
}
# 区域背景亮度：均匀取样的中位数（给找图用，深色界面另有判断）
function Get-BgLum([Drawing.Bitmap]$b) { $v = @(for ($y = 4; $y -lt $b.Height; $y += [Math]::Max(1, [int]($b.Height / 24))) { for ($x = 4; $x -lt $b.Width; $x += [Math]::Max(1, [int]($b.Width / 16))) { $c = $b.GetPixel($x, $y); [int](($c.R * 299 + $c.G * 587 + $c.B * 114) / 1000) } }) | Sort-Object; if ($v.Count) { $v[[int]($v.Count / 2)] } else { 255 } }
function GNorm([string]$s) { ($s -replace '[\s\p{P}]', '').ToLower() }
# 会话列表 → 条目（名字 + 是否未读）；$k = OCR 前的放大倍数
function Read-ListRows([Drawing.Bitmap]$lb0, $badges, [double]$k) {
  $lb = if ($k -ne 1.0) { $b = New-Object Drawing.Bitmap ([int]($lb0.Width * $k)), ([int]($lb0.Height * $k)); $gg = [Drawing.Graphics]::FromImage($b); $gg.InterpolationMode = 'HighQualityBicubic'; $gg.DrawImage($lb0, 0, 0, $b.Width, $b.Height); $gg.Dispose(); $b } else { $lb0 }
  $lw = $lb.Width; $ll = @(Get-Lines (Invoke-Ocr $lb) | Sort-Object y); if ($k -ne 1.0) { $lb.Dispose() }
  # 时间列：去掉 OCR 插进来的空格、全角冒号后再匹配；或者是贴在右边的短字
  $isTime = { param($l) $s = ($l.文本 -replace '\s', '') -replace '：', ':'; ($s -match $script:TimeRx) -or ($l.x0 / $lw -gt 0.65 -and $s.Length -le 6) }
  $txt = @($ll | Where-Object { -not (& $isTime $_) }); $script:LastTimeCount = $ll.Count - $txt.Count
  $medH = if ($txt.Count) { ($txt | ForEach-Object h | Sort-Object)[[int]($txt.Count / 2)] } else { 30 }
  # 分行：相邻两行的间距只有两种——条目内（名字到预览）和条目之间；两者明显不同时取中点做分界
  $gaps = @(for ($i = 1; $i -lt $txt.Count; $i++) { $txt[$i].y - $txt[$i - 1].y }) | Sort-Object
  $cut = if ($gaps.Count -ge 2 -and $gaps[-1] -gt 1.4 * $gaps[0]) { ($gaps[0] + $gaps[-1]) / 2 } else { 0.5 * $medH }
  $rows = New-Object System.Collections.ArrayList; $cur = $null
  foreach ($l in $txt) { if (-not $cur -or ($l.y - $cur.yLast) -gt $cut) { $cur = [pscustomobject]@{ y = $l.y; yLast = $l.y; lines = New-Object System.Collections.ArrayList }; [void]$rows.Add($cur) }; [void]$cur.lines.Add($l); $cur.yLast = $l.y }
  foreach ($r in $rows) { $nm = $r.lines | Sort-Object y, x0 | Select-Object -First 1; $y0 = $r.y / $k
    [pscustomobject]@{ name = $nm.文本; unread = [bool]($badges | Where-Object { $_.Y -ge $y0 - 22 * $script:GDpi -and $_.Y -le $y0 + 40 * $script:GDpi }) } }
}function Read-Generic($ad, [Drawing.Bitmap]$full) {
  $w = $full.Width; $ht = $full.Height; $res = [ordered]@{ msgs = @(); rows = @() }
  $mr = To-Rect $ad.messages $w $ht
  if ($mr) {
    $img = Crop $full $mr; $cw = $img.Width; $lines = @(Get-Lines (Invoke-Ocr $img) | Sort-Object y)
    # 图片：颜色丰富的块（同微信的找图法）；图片里的字不当成消息正文。$script:GKeepImages 为真时附上裁剪（调用方用完负责 Dispose）
    $boxes = @(); if ($script:GKeepImages) { $boxes = @([Rec]::FindImages($img, 16, 14, [int](40 * $script:GDpi * 1.8), (Get-BgLum $img))) }
    $imgItems = foreach ($bx in $boxes) {
      $inside = @($lines | Where-Object { $c = ($_.x0 + $_.x1) / 2; $m = $_.y + $_.h / 2; $c -ge $bx.X -and $c -le $bx.Right -and $m -ge $bx.Y -and $m -le $bx.Bottom })
      $side = if ((($bx.X + $bx.Width / 2) / $cw -gt 0.5) -eq ($ad.my_side -ne 'left')) { 'me' } else { 'other' }
      [pscustomobject]@{ y = $bx.Y; x0 = $bx.X; k = $side; t = $(if ($inside.Count) { '[图片] ' + (($inside | ForEach-Object 文本) -join ' / ') } else { '[图片]' }); img = (Crop $img $bx) }
    }
    if ($boxes.Count) { $lines = @($lines | Where-Object { $l = $_; $c = ($l.x0 + $l.x1) / 2; $m = $l.y + $l.h / 2; -not ($boxes | Where-Object { $c -ge $_.X -and $c -le $_.Right -and $m -ge $_.Y -and $m -le $_.Bottom }) }) }
    $img.Dispose()
    # 最下面一行文字贴着区域下沿：区域很可能截掉了最新一条（自检会据此判不过）
    $res.cutBottom = [bool]($lines | Where-Object { $_.y + $_.h -gt $mr.Height - 6 * $script:GDpi })
    $medH = if ($lines.Count) { ($lines | ForEach-Object h | Sort-Object)[[int]($lines.Count / 2)] } else { 20 * $script:GDpi }
    $items = @(foreach ($l in $lines) {
      $cx = ($l.x0 + $l.x1) / 2 / $cw; $wid = ($l.x1 - $l.x0) / $cw
      $k = if ($ad.time_separator -and [Math]::Abs($cx - 0.5) -lt 0.12 -and $wid -lt 0.35 -and $l.文本 -match $script:TimeRx) { 'time' }
           elseif ($ad.my_side -eq 'right' -and $l.x1 / $cw -gt 0.72 -and $l.x0 / $cw -gt 0.30) { 'me' }
           elseif ($ad.my_side -eq 'left' -and $l.x0 / $cw -lt 0.28 -and $l.x1 / $cw -lt 0.70) { 'me' }
           elseif ($ad.my_side -eq 'left' -and $l.x1 / $cw -gt 0.72) { 'other' }
           elseif ($ad.my_side -ne 'left' -and $l.x0 / $cw -lt 0.40) { 'other' } else { 'unsure' }
      [pscustomobject]@{ y = $l.y; x0 = $l.x0; k = $k; t = $l.文本; img = $null }
    }) + @($imgItems) | Sort-Object y
    # 群聊名字：靠“对方”一侧、起点最靠外的一簇短行
    $oth = @($items | Where-Object { $_.k -eq 'other' -and -not $_.img })
    if ($ad.sender_name -eq 'above_bubble' -and $oth.Count -ge 2) { $minX = ($oth | Measure-Object x0 -Minimum).Minimum; if (@($oth | Where-Object { $_.x0 - $minX -gt 6 * $script:GDpi }).Count) { foreach ($e in $oth) { if (-not $e.img -and $e.x0 - $minX -lt 4 * $script:GDpi -and $e.t.Length -le 20) { $e.k = 'name' } } } }
    $msgs = New-Object System.Collections.ArrayList; $last = $null
    foreach ($e in $items) {
      if ($e.k -in 'time', 'name', 'unsure') { $last = $null; continue }
      if ($last -and -not $e.img -and -not $last.img -and $last.side -eq $e.k -and ($e.y - $last.yEnd) -lt 1.6 * $medH) { $last.text += $e.t; $last.yEnd = $e.y + $medH; continue }
      $last = [pscustomobject]@{ side = $e.k; text = $e.t; yEnd = $e.y + $(if ($e.img) { $e.img.Height } else { $medH }); img = $e.img }; [void]$msgs.Add($last)
    }
    $res.msgs = @($msgs | ForEach-Object { [pscustomobject]@{ side = $_.side; text = $_.text; img = $_.img } })
  }
  $lr = To-Rect $ad.chat_list $w $ht
  # 列表区域和搜索框重叠时，从搜索框下沿开始（不然搜索框里的字会被当成一条会话）
  $sr = To-Rect $ad.search $w $ht
  if ($lr -and $sr -and $sr.Bottom -gt $lr.Y -and $sr.Y -lt $lr.Y + $lr.Height / 3) { $nt = $sr.Bottom + [int](4 * $script:GDpi); $lr = New-Object Drawing.Rectangle $lr.X, $nt, $lr.Width, ($lr.Bottom - $nt) }
  if ($lr) {
    $lb0 = Crop $full $lr
    $badges = @([Rec]::RedBadges($lb0, 12, [int](24 * $script:GDpi)))   # 红色未读角标几乎所有聊天软件都有：不管模型怎么描述标记样式都检测
    $res.rows = @(Read-ListRows $lb0 $badges 1.0)
    # 名字明显比时间少（短名字被 OCR 漏了）时，放大 1.5 倍再读一次
    if ($script:LastTimeCount -ge 3 -and $res.rows.Count -lt 0.8 * $script:LastTimeCount) { $res.rows = @(Read-ListRows $lb0 $badges 1.5) }
    $lb0.Dispose()
  }
  $res
}
# 版面校正：模型给的区域边界可能差几个百分点。消息区下沿要贴到输入框上方的分隔线——最新消息总在最下面，差一点就会漏掉最新一条
# 在模型给的下沿附近往下找一条“横贯整宽、颜色一致、和上面那行明显不同”的分隔线；找到就用它，否则保持原样
function Find-Rule([Drawing.Bitmap]$b, [int]$x0, [int]$x1, [int]$yFrom, [int]$yTo) {
  $yTo = [Math]::Min($b.Height - 3, $yTo); $xs = @(for ($x = $x0 + 10; $x -lt $x1 - 10; $x += [Math]::Max(8, [int](($x1 - $x0) / 60))) { $x })
  $lum = { param($c) ($c.R * 299 + $c.G * 587 + $c.B * 114) / 1000 }
  for ($y = [Math]::Max(2, $yFrom); $y -le $yTo; $y++) {
    # 细分隔线：这一行整宽颜色一致；上下各隔 3 行也都是整宽一致的底色；分隔线和上下两侧都明显不同（气泡下沿只满足“和上面不同”，会被排除）
    $v = @($xs | ForEach-Object { & $lum $b.GetPixel($_, $y) }); $mn = ($v | Measure-Object -Minimum -Maximum)
    if ($mn.Maximum - $mn.Minimum -gt 3) { continue }
    $up = @($xs | ForEach-Object { & $lum $b.GetPixel($_, $y - 3) }) | Measure-Object -Average -Minimum -Maximum
    $dn = @($xs | ForEach-Object { & $lum $b.GetPixel($_, [Math]::Min($b.Height - 1, $y + 3)) }) | Measure-Object -Average -Minimum -Maximum
    if ($up.Maximum - $up.Minimum -gt 6 -or $dn.Maximum - $dn.Minimum -gt 6) { continue }
    if ([Math]::Abs($up.Average - $v[0]) -ge 5 -and [Math]::Abs($dn.Average - $v[0]) -ge 5) { return $y }
  }
  -1
}
function Refine-Layout($ad, [Drawing.Bitmap]$full, [double]$up = 0.03) {   # $up：从模型给的下沿往上多远开始找（值守每轮用更大的范围，界面挪动时也能找到）
  $w = $full.Width; $ht = $full.Height; $notes = @()
  if ($ad.messages.present) {
    $x0 = [int]([double]$ad.messages.x0 * $w); $x1 = [int]([Math]::Min(1.0, [double]$ad.messages.x1) * $w) - 1
    $y1 = [int]([double]$ad.messages.y1 * $ht)
    $y = Find-Rule $full $x0 $x1 ($y1 - [int]($up * $ht)) ($y1 + [int](0.2 * $ht))
    if ($y -gt 0 -and [Math]::Abs($y - $y1) -gt 0.005 * $ht) { $notes += "消息区下沿 $([Math]::Round([double]$ad.messages.y1, 3)) → $([Math]::Round($y / $ht, 3))"; $ad.messages.y1 = [Math]::Round(($y - 2) / $ht, 4) }
  }
  $notes
}# 当前会话标题：标题区里最靠上、靠左的一行
function Read-GenericTitle($ad, [Drawing.Bitmap]$full) {
  $tr = To-Rect $ad.title $full.Width $full.Height; if (-not $tr) { return '' }
  $tb = Crop $full $tr; $tl = @(Get-Lines (Invoke-Ocr $tb)); $tb.Dispose()
  $t0 = $tl | Where-Object { $_.x0 -lt $tr.Width * 0.5 } | Sort-Object y | Select-Object -First 1
  if ($t0) { ($t0.文本 -replace '\s*[（(]\d+[)）]\s*$', '').Trim() } else { '' }
}