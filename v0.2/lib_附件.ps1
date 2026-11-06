# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_附件.ps1 — 图片和文件记录
# 本机有原件的（比如微信收到的文件）：只记位置（路径、大小、修改时间、前 1MB 的指纹），不复制；之后发现挪走/改过就标出来
# 本机没有原件的（网页、其它软件里的图片）：从屏幕截下那一块，缩到长边 ≤1600 像素存 JPEG，加一张 ≤240 的缩略图，都用 DPAPI 加密放在 data\images\
# 微信的图片在本机是加密的 .dat：不打开、不解码，也同样截屏保存，并记下它属于哪个会话、哪条消息
# 文件位置只在用户自己的“下载”和微信的文件夹（msg\file / FileStorage\File）里按文件名查找，只看目录和文件信息；不碰任何软件的数据库或 .dat
# 记录：data\attachments.jsonl（每条一行，名字、路径、会话、发送方加密）；图片只在用户问到、并且开了 cloud_images 时才交给 Claude 看
Add-Type -AssemblyName System.Security, System.Drawing
if (-not $script:AttData) { $script:AttData = Join-Path (Split-Path $PSScriptRoot -Parent) 'data' }
$script:AttEntropy = [Text.Encoding]::UTF8.GetBytes('secretary-v0.1')
function AttP([string]$s) { if ($null -eq $s) { $s = '' }; [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($s), $script:AttEntropy, 'CurrentUser')) }
function AttU([string]$b) { if (-not $b) { return '' }; try { [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($b), $script:AttEntropy, 'CurrentUser')) } catch { '' } }
function Att-File { Join-Path $script:AttData 'attachments.jsonl' }
function Att-ImgDir { $d = Join-Path $script:AttData 'images'; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }; $d }
function New-AttId { 'a' + (Get-Date).ToString('yyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6) }

# —— 文件名识别：消息里的“名字.扩展名”，可带大小（1.2M / 356KB）；微信会把太长的名字中间省略成 …
$script:FileExtRx = 'pdf|docx?|xlsx?|xlsm|pptx?|txt|csv|md|rtf|zip|rar|7z|tar|gz|png|jpe?g|gif|bmp|webp|heic|tiff?|mp3|wav|m4a|flac|mp4|mov|avi|mkv|apk|exe|msi|dmg|psd|ai|dwg|sketch|fig|key|pages|numbers|epub|json|xml|html?|py|js|ts|ps1|sql'
function Get-FileRef([string]$text) {
  if (-not $text) { return $null }
  $t = $text -replace '^\[图片\]\s*', ''
  $m = [regex]::Match($t, "([^\s/\\:*?`"<>|]{1,160}?(?:…|\.\.\.)?[^\s/\\:*?`"<>|]{0,40}\.(?:$script:FileExtRx))(?![A-Za-z0-9])", 'IgnoreCase')
  if (-not $m.Success) { return $null }
  $sz = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*(B|K|KB|M|MB|G|GB)(?![A-Za-z])', 'IgnoreCase')
  $bytes = $null; if ($sz.Success) { $u = $sz.Groups[2].Value.ToUpper()[0]; $mul = switch ($u) { 'B' { 1 } 'K' { 1KB } 'M' { 1MB } 'G' { 1GB } }; $bytes = [long]([double]$sz.Groups[1].Value * $mul) }
  [pscustomobject]@{ name = $m.Groups[1].Value.Trim(); bytes = $bytes }
}
# 查找范围：用户的“下载”文件夹 + 微信的文件夹（4.x：文档\xwechat_files\<账号>\msg\file；3.x：文档\WeChat Files\<账号>\FileStorage\File）
function Get-FileRoots([string]$app) {
  $docs = [Environment]::GetFolderPath('MyDocuments'); $r = New-Object System.Collections.Generic.List[string]
  if ($script:AttOnlyExtra) { foreach ($x in $script:AttExtraRoots) { if (Test-Path $x) { $r.Add($x) } }; return $r }   # 测试用：只在测试文件夹里找
  if (-not $app -or $app -eq '微信') {
    foreach ($p in @((Join-Path $docs 'xwechat_files'), (Join-Path $docs 'WeChat Files'))) {
      if (Test-Path $p) { foreach ($acc in Get-ChildItem $p -Directory -ErrorAction SilentlyContinue) { foreach ($s in 'msg\file', 'FileStorage\File') { $q = Join-Path $acc.FullName $s; if (Test-Path $q) { $r.Add($q) } } } }
    }
  }
  $dl = Join-Path $env:USERPROFILE 'Downloads'; if (Test-Path $dl) { $r.Add($dl) }
  if ($script:AttExtraRoots) { foreach ($x in $script:AttExtraRoots) { if (Test-Path $x) { $r.Add($x) } } }   # 测试用
  $r
}
# 按名字找本机文件：先完全同名，再允许重名后缀“名字(1).pdf”，省略号处当通配；有大小时选大小最接近的，否则选最新的
function Find-LocalFile([string]$name, $bytes, [string]$app) {
  $ext = [IO.Path]::GetExtension($name); $base = [IO.Path]::GetFileNameWithoutExtension($name)
  $pats = if ($name -match '…|\.\.\.') { @(($base -replace '…|\.\.\.', '*') + $ext) } else { @($name, "$base(*)$ext", "$base (*)$ext") }
  $cand = foreach ($root in Get-FileRoots $app) { foreach ($p in $pats) { Get-ChildItem -LiteralPath $root -Recurse -File -Filter $p -ErrorAction SilentlyContinue -Depth 3 } }
  $cand = @($cand | Sort-Object FullName -Unique); if (-not $cand.Count) { return $null }
  if ($bytes) { $cand = @($cand | Sort-Object { [Math]::Abs($_.Length - $bytes) / [Math]::Max(1, $bytes) }, { -$_.LastWriteTime.Ticks }) ; if ([Math]::Abs($cand[0].Length - $bytes) / [Math]::Max(1, $bytes) -gt 0.15) { return $null } }
  else { $cand = @($cand | Sort-Object LastWriteTime -Descending) }
  $cand[0]
}
# 指纹：大小 + 前 1MB 的 SHA-256（只用来认出“是不是同一个文件”）
function Get-QuickHash([string]$path) {
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite'); try { $buf = New-Object byte[] ([Math]::Min(1MB, $fs.Length)); [void]$fs.Read($buf, 0, $buf.Length); $len = $fs.Length } finally { $fs.Dispose() }
  $h = [Security.Cryptography.SHA256]::Create().ComputeHash($buf); "$len-" + [BitConverter]::ToString($h).Replace('-', '').Substring(0, 16)
}

# —— 图片：缩放 + JPEG + DPAPI 加密 ——
function Get-Jpeg([Drawing.Bitmap]$src, [int]$maxSide, [long]$q) {
  $k = [Math]::Min(1.0, $maxSide / [double][Math]::Max($src.Width, $src.Height)); $w = [Math]::Max(1, [int]($src.Width * $k)); $h = [Math]::Max(1, [int]($src.Height * $k))
  $b = New-Object Drawing.Bitmap $w, $h; $g = [Drawing.Graphics]::FromImage($b); $g.InterpolationMode = 'HighQualityBicubic'; $g.Clear([Drawing.Color]::White); $g.DrawImage($src, 0, 0, $w, $h); $g.Dispose()
  $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
  $ep = New-Object Drawing.Imaging.EncoderParameters 1; $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), $q
  $ms = New-Object IO.MemoryStream; $b.Save($ms, $enc, $ep); $b.Dispose(); [pscustomobject]@{ bytes = $ms.ToArray(); w = $w; h = $h }
}
function Write-AttRecord($rec) { [IO.File]::AppendAllLines((Att-File), [string[]]@(($rec | ConvertTo-Json -Compress)), (New-Object Text.UTF8Encoding $false)) }
# 存一张截下来的图片；$meta = @{ app; conv; sender; msg_key; shown; source }，返回附件记录（未加密的字段：id、类型、尺寸、字节数）
function Save-AttImage([Drawing.Bitmap]$bmp, $meta) {
  $id = New-AttId; $dir = Att-ImgDir
  $full = Get-Jpeg $bmp 1600 85; $th = Get-Jpeg $bmp 240 75
  [IO.File]::WriteAllBytes((Join-Path $dir "$id.img"), [Security.Cryptography.ProtectedData]::Protect($full.bytes, $script:AttEntropy, 'CurrentUser'))
  [IO.File]::WriteAllBytes((Join-Path $dir "$id.thumb"), [Security.Cryptography.ProtectedData]::Protect($th.bytes, $script:AttEntropy, 'CurrentUser'))
  $rec = [ordered]@{ id = $id; ts = (Get-Date).ToString('s'); kind = 'image'; mode = 'crop'; app = [string]$meta.app; conv = AttP $meta.conv; sender = AttP $meta.sender; msg_key = [string]$meta.msg_key
                     shown = AttP $meta.shown; source = [string]$meta.source; w = $full.w; h = $full.h; srcW = $bmp.Width; srcH = $bmp.Height; bytes = $full.bytes.Length + $th.bytes.Length }
  Write-AttRecord $rec; $rec
}
# 记一个文件：本机找得到就记位置，找不到也记下名字（mode = missing，之后可以再找）
function Save-AttFile($ref, $meta) {
  $id = New-AttId; $f = $null; try { $f = Find-LocalFile $ref.name $ref.bytes $meta.app } catch {}
  $rec = [ordered]@{ id = $id; ts = (Get-Date).ToString('s'); kind = 'file'; mode = $(if ($f) { 'local' } else { 'missing' }); app = [string]$meta.app; conv = AttP $meta.conv; sender = AttP $meta.sender; msg_key = [string]$meta.msg_key
                     name = AttP $ref.name; shownBytes = $ref.bytes; path = $(if ($f) { AttP $f.FullName } else { '' }); size = $(if ($f) { $f.Length } else { $null }); mtime = $(if ($f) { $f.LastWriteTime.ToString('s') } else { '' }); qhash = $(if ($f) { Get-QuickHash $f.FullName } else { '' }) }
  Write-AttRecord $rec; $rec
}

# —— 读记录（同一个 id 后写的覆盖先写的：清除图片、重新找到文件都追加新版本）——
function Get-AttRecords {
  $f = Att-File; if (-not (Test-Path $f)) { return @() }
  $by = [ordered]@{}; foreach ($l in [IO.File]::ReadLines($f)) { try { $o = $l | ConvertFrom-Json; $by[$o.id] = $o } catch {} }
  @($by.Values)
}
function Get-AttRecord([string]$id) { Get-AttRecords | Where-Object id -eq $id | Select-Object -First 1 }
# 文件现在的状态：在原处 / 改过 / 挪走了（挪走时按名字再找一次，找到就更新位置）
function Test-AttFile($rec) {
  if ($rec.kind -ne 'file') { return $null }
  $p = AttU $rec.path
  if ($p -and (Test-Path -LiteralPath $p)) { $fi = Get-Item -LiteralPath $p; if ($fi.Length -eq $rec.size -and (Get-QuickHash $p) -eq $rec.qhash) { return [pscustomobject]@{ state = '在原处'; path = $p } } else { return [pscustomobject]@{ state = '文件改过'; path = $p } } }
  $f = $null; try { $f = Find-LocalFile (AttU $rec.name) $(if ($rec.size) { $rec.size } else { $rec.shownBytes }) $rec.app } catch {}
  if ($f -and (-not $rec.qhash -or (Get-QuickHash $f.FullName) -eq $rec.qhash)) {
    $n = [ordered]@{}; foreach ($pr in $rec.PSObject.Properties) { $n[$pr.Name] = $pr.Value }
    $n.mode = 'local'; $n.path = AttP $f.FullName; $n.size = $f.Length; $n.mtime = $f.LastWriteTime.ToString('s'); $n.qhash = Get-QuickHash $f.FullName; Write-AttRecord $n
    return [pscustomobject]@{ state = $(if ($p) { '挪到了新位置' } else { '找到了' }); path = $f.FullName }
  }
  [pscustomobject]@{ state = $(if ($p) { '已移走' } else { '本机没找到' }); path = '' }
}
# 解密一张图片（-Thumb 取缩略图）；已清除返回 $null
function Read-AttImage([string]$id, [switch]$Thumb) {
  $p = Join-Path (Att-ImgDir) $(if ($Thumb) { "$id.thumb" } else { "$id.img" }); if (-not (Test-Path $p)) { return $null }
  [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($p), $script:AttEntropy, 'CurrentUser')
}
# 设置页的“存储”一行
function Get-AttStorage {
  $recs = @(Get-AttRecords); $dir = Join-Path $script:AttData 'images'
  $bytes = 0; if (Test-Path $dir) { $bytes = (Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
  [pscustomobject]@{ images = @($recs | Where-Object { $_.kind -eq 'image' -and $_.mode -eq 'crop' }).Count; files = @($recs | Where-Object kind -eq 'file').Count; filesFound = @($recs | Where-Object { $_.kind -eq 'file' -and $_.mode -eq 'local' }).Count; bytes = [long]$bytes; cap = [long]$script:AttImgCap }
}
# 清除保存的图片（用户在设置里点的）：删掉截图文件，记录标成“已清除”；文件位置记录保留（不占空间）
function Clear-AttImages {
  $n = 0; foreach ($r in Get-AttRecords | Where-Object { $_.kind -eq 'image' -and $_.mode -eq 'crop' }) {
    foreach ($s in 'img', 'thumb') { $p = Join-Path (Att-ImgDir) "$($r.id).$s"; if (Test-Path $p) { Remove-Item -LiteralPath $p -Force } }
    $x = [ordered]@{}; foreach ($pr in $r.PSObject.Properties) { $x[$pr.Name] = $pr.Value }; $x.mode = 'cleared'; $x.bytes = 0; Write-AttRecord $x; $n++
  }
  $n
}
# 截图最多占 1 GB：超了就从最旧的截图删起，删到 1 GB 以下（记录留着，标成「太旧，已腾地方」）。只动 images 里的截图，不碰消息、聊天记录、存档和记忆
$script:AttImgCap = 1GB
function Limit-AttImages([long]$cap = $script:AttImgCap) {
  $dir = Join-Path $script:AttData 'images'; if (-not (Test-Path $dir)) { return 0 }
  $total = [long](Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; if ($total -le $cap) { return 0 }
  $n = 0
  foreach ($r in @(Get-AttRecords | Where-Object { $_.kind -eq 'image' -and $_.mode -eq 'crop' } | Sort-Object { [string]$_.ts })) {
    if ($total -le $cap) { break }
    foreach ($s in 'img', 'thumb') { $p = Join-Path $dir "$($r.id).$s"; if (Test-Path -LiteralPath $p) { $total -= (Get-Item -LiteralPath $p).Length; Remove-Item -LiteralPath $p -Force } }
    $x = [ordered]@{}; foreach ($pr in $r.PSObject.Properties) { $x[$pr.Name] = $pr.Value }; $x.mode = 'pruned'; $x.bytes = 0; Write-AttRecord $x; $n++
  }
  $n
}