# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_文件.ps1 — 文件从哪来、讲的是什么：「把 A 上次发给我的关于 C 的文件发给 C」
# 来源：秘书读聊天时已经记下的文件卡片（attachments.jsonl：谁、哪个聊天、什么时候、文件名、本机位置）。
# 这里再补一份「内容索引」（data\files_index.jsonl，DPAPI 加密，只在本机）：类型、关键词、前约 2000 字、用户确认过的主题。
# 读内容全部在本机：txt/md/csv 直接读；docx/xlsx/pptx 读包里的 XML；PDF 用 Windows 自带的 PDF 渲染 + OCR（前几页）；图片用 OCR。
# 不下载任何东西；找文件时只把最可能的 2–3 个文件的短摘录（每个 ≤500 字）交给模型判断。
# 没在本机找到原文件的（没下载、重名对不上）记成「只有卡片」。
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem, System.Runtime.WindowsRuntime, System.Drawing
if (-not $script:FileIdxFile) { $script:FileIdxFile = Join-Path $script:V2Data 'files_index.jsonl' }
if (-not $script:FileStatsFile) { $script:FileStatsFile = Join-Path $script:V2Data 'file_pick_stats.json' }
function Get-FileIndex { $h = @{}; if (Test-Path $script:FileIdxFile) { foreach ($l in [IO.File]::ReadAllLines($script:FileIdxFile)) { if ($l) { try { $o = (MemU $l) | ConvertFrom-Json; $h[$o.id] = $o } catch {} } } }; $h }
function Save-FileIndex($h) { [IO.File]::WriteAllLines($script:FileIdxFile, [string[]]@($h.Values | ForEach-Object { MemP ($_ | ConvertTo-Json -Depth 5 -Compress) }), (New-Object Text.UTF8Encoding $false)) }

# —— 读出文件里的文字（本机）——
function Get-ZipXmlText([string]$path, [string]$pattern) {
  $za = [IO.Compression.ZipFile]::OpenRead($path); $sb = New-Object Text.StringBuilder
  try { foreach ($e in ($za.Entries | Where-Object { $_.FullName -match $pattern } | Sort-Object FullName)) { $sr = New-Object IO.StreamReader ($e.Open()); $x = $sr.ReadToEnd(); $sr.Dispose()
      [void]$sb.Append((($x -replace '</w:p>|</a:p>|</si>|</row>', "`n") -replace '<[^>]+>', '')); if ($sb.Length -gt 20000) { break } } } finally { $za.Dispose() }
  [Net.WebUtility]::HtmlDecode($sb.ToString())
}
function Get-OcrText([Drawing.Bitmap]$bmp) { if (-not (Get-Command Invoke-Ocr -ErrorAction SilentlyContinue)) { return '' }; (@(Get-Lines (Invoke-Ocr $bmp)) | Sort-Object y | ForEach-Object 文本) -join "`n" }
$script:AsTaskAction = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1   # 没有返回值的异步操作（渲染 PDF 页）
function Get-PdfText([string]$path, [int]$pages = 3) {
  if (-not (Get-Command Await -ErrorAction SilentlyContinue)) { return '' }
  $null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]; $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $sf = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
  $doc = Await ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($sf)) ([Windows.Data.Pdf.PdfDocument])
  $sb = New-Object Text.StringBuilder
  for ($i = 0; $i -lt [Math]::Min($pages, $doc.PageCount); $i++) {
    $pg = $doc.GetPage($i); $ras = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
    $opt = New-Object Windows.Data.Pdf.PdfPageRenderOptions; $opt.DestinationWidth = [uint32]1600
    $act = $pg.RenderToStreamAsync($ras, $opt); $tk = $script:AsTaskAction.Invoke($null, @($act)); $tk.Wait(-1) | Out-Null
    $st = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($ras.GetInputStreamAt(0)); $bmp = New-Object Drawing.Bitmap $st
    try { [void]$sb.AppendLine((Get-OcrText $bmp)) } finally { $bmp.Dispose(); $st.Dispose(); $pg.Dispose() }
  }
  $sb.ToString()
}
function Get-FileText([string]$path) {
  $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
  try {
    switch -regex ($ext) {
      '^\.(txt|md|csv|log|json)$' { return ([IO.File]::ReadAllText($path)) }
      '^\.docx$' { return (Get-ZipXmlText $path '^word/document\.xml$') }
      '^\.xlsx$' { return (Get-ZipXmlText $path '^xl/sharedStrings\.xml$') }
      '^\.pptx$' { return (Get-ZipXmlText $path '^ppt/slides/slide\d+\.xml$') }
      '^\.pdf$' { return (Get-PdfText $path) }
      '^\.(png|jpe?g|bmp|gif)$' { $b = New-Object Drawing.Bitmap $path; try { return (Get-OcrText $b) } finally { $b.Dispose() } }
    }
  } catch {}
  ''
}
# 关键词：中文按两个字一组、英文按单词；去掉常见虚词，取出现最多的 40 个
$script:StopBi = @('我们', '你们', '他们', '这个', '那个', '一个', '没有', '可以', '就是', '还是', '已经', '因为', '所以', '如果', '但是', '以及', '进行', '相关', '的是', '了一')
function Get-Keywords([string]$text, [int]$max = 40) {
  $cnt = @{}
  foreach ($m in [regex]::Matches($text, '[一-鿿]+')) { $s = $m.Value; for ($i = 0; $i -lt $s.Length - 1; $i++) { $b = $s.Substring($i, 2); if ($script:StopBi -notcontains $b) { $cnt[$b] = 1 + [int]$cnt[$b] } } }
  foreach ($m in [regex]::Matches($text.ToLowerInvariant(), '[a-z][a-z0-9]{2,}')) { $cnt[$m.Value] = 1 + [int]$cnt[$m.Value] }
  @($cnt.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $max | ForEach-Object { $_.Key })
}
function Get-FileType([string]$name) { switch -regex ([IO.Path]::GetExtension($name).ToLowerInvariant()) { '^\.(docx?|txt|md|pdf|rtf)$' { 'doc' } '^\.(xlsx?|csv)$' { 'sheet' } '^\.(pptx?)$' { 'slides' } '^\.(png|jpe?g|gif|bmp)$' { 'image' } default { 'other' } } }

# —— 补索引：每个文件卡片记录（kind=file）读一次内容；本机没有原文件的记成「只有卡片」——
function Update-FileIndex([int]$max = 50) {
  $idx = Get-FileIndex; $n = 0
  foreach ($r in @(Get-AttRecords | Where-Object { $_.kind -eq 'file' })) {
    $path = AttU $r.path; $old = $idx[$r.id]
    if ($old -and $old.path -eq $path) { continue }
    if ($n -ge $max) { break }; $n++
    $name = AttU $r.name; $text = if ($path -and (Test-Path -LiteralPath $path)) { Get-FileText $path } else { '' }
    $idx[$r.id] = [pscustomobject]@{ id = $r.id; name = $name; app = [string]$r.app; chat = (AttU $r.conv); sender = (AttU $r.sender); ts = [string]$r.ts; path = $path; size = $r.size
      state = $(if ($path -and (Test-Path -LiteralPath $path)) { 'local' } else { 'card_only' }); type = (Get-FileType $name); keywords = @(Get-Keywords "$name`n$text"); excerpt = $(if ($text.Length -gt 2000) { $text.Substring(0, 2000) } else { $text })
      topics = @($(if ($old) { @($old.topics) } else { @() })) }
  }
  if ($n) { Save-FileIndex $idx }; $n
}

# —— 找文件：发件人（经认人）、关于什么（连同这个人的所有称呼）、类型、时间、文件名线索 ——
function Get-NameVariants([string]$q) {
  if (-not $q) { return @() }; $out = @($q)
  $r = Resolve-Person $q; $title = if ($r.status -eq 'direct') { $r.chat.title } else { $null }
  foreach ($p in Get-People) { if (@($p.aliases | Where-Object { (NormName $_.text) -eq (NormName $q) }).Count -or ($title -and @($p.chats | Where-Object { $_.title -eq $title }).Count)) { $out += @($p.aliases | ForEach-Object { $_.text }); $out += @($p.chats | ForEach-Object { $_.title }) } }
  if ($title) { $out += $title }; $bare = Strip-Latin $q; if ($bare -and $bare.Length -ge 2) { $out += $bare }
  @($out | Where-Object { $_ } | Select-Object -Unique)
}
function Test-FromSender($f, $senderNames) {
  if (-not $senderNames.Count) { return $true }
  foreach ($n in $senderNames) { $nn = NormName $n; if ((NormName $f.sender) -eq $nn -or ((NormName $f.chat) -eq $nn -and $f.sender -notin '我')) { return $true } }
  $false
}
function Find-Files([string]$sender, [string]$about, [string]$type, [string]$when, [string]$nameHint) {
  [void](Update-FileIndex)
  $files = @((Get-FileIndex).Values | Where-Object { $_.sender -ne '我' })
  $sn = @(Get-NameVariants $sender); $an = @(Get-NameVariants $about)
  if ($sender) { $files = @($files | Where-Object { Test-FromSender $_ $sn }) }
  if ($type) { $files = @($files | Where-Object { $_.type -eq $type }) }
  if ($when -match '^(\d{4}-\d{2}-\d{2})?\.\.(\d{4}-\d{2}-\d{2})?$') { $a = $Matches[1]; $b = $Matches[2]; $files = @($files | Where-Object { (-not $a -or $_.ts -ge $a) -and (-not $b -or $_.ts -le "$b`T23:59:59") }) }
  $newest = ($files | Measure-Object -Property ts -Maximum).Maximum
  $scored = foreach ($f in $files) {
    $s = 0.0; $why = @()
    foreach ($t in @($f.topics)) { if ($an | Where-Object { (NormName $_) -eq (NormName $t.text) }) { $s += 10; $why += '你确认过' } }
    $hay = "$($f.name)`n$($f.excerpt)"; $kw = @($f.keywords)
    foreach ($a in $an) { $na = $a -replace '\s', ''; if ($na.Length -lt 2) { continue }
      $c = ([regex]::Matches($hay, [regex]::Escape($na))).Count; if ($c) { $s += [Math]::Min(6, 2 + $c); $why += "内容提到「$na」" }
      elseif ($na -match '[一-鿿]{2,}' -and ($kw -contains $na.Substring($na.Length - 2))) { $s += 1; $why += '关键词相近' } }
    if ($nameHint -and $f.name -like "*$nameHint*") { $s += 3; $why += '文件名像' }
    if ($f.ts -eq $newest -and $when -match '^last') { $s += 0.5 }
    $age = try { ((Get-Date) - [datetime]$f.ts).TotalDays } catch { 999 }; $s += [Math]::Max(0, 1 - $age / 60)   # 越新越靠前（最多 +1）
    if ($f.state -ne 'local') { $s -= 0.3 }
    [pscustomobject]@{ f = $f; score = [Math]::Round($s, 2); why = @($why | Select-Object -Unique) }
  }
  $top = @($scored | Sort-Object score -Descending | Select-Object -First 3)
  $clear = ($top.Count -ge 1 -and $about -and $top[0].score -ge 3 -and ($top.Count -eq 1 -or $top[0].score -ge 2 * [Math]::Max(0.5, $top[1].score)))
  if ($top.Count -ge 1 -and ($top[0].why -contains '你确认过') -and -not ($top.Count -gt 1 -and ($top[1].why -contains '你确认过'))) { $clear = $true }   # 你确认过的那个文件：直接给
  if (-not $about -and $top.Count -ge 1 -and $when -match '^last' -and ($top.Count -eq 1 -or $top[0].f.ts -gt $top[1].f.ts)) { $clear = $true }
  @{ top = $top; clear = [bool]$clear; senderNames = $sn; aboutNames = $an }
}
# 用户在选择卡上选了某个文件：记住「这个文件讲的是 C」
function Add-FileTopic([string]$id, [string]$topic) {
  $idx = Get-FileIndex; $f = $idx[$id]; if (-not $f) { return }
  if (-not (@($f.topics) | Where-Object { (NormName $_.text) -eq (NormName $topic) })) { $f.topics = @(@($f.topics) + [pscustomobject]@{ text = $topic; source = 'user_confirmed'; created = (Get-Date).ToString('s') }) }
  Save-FileIndex $idx
}
function Remove-FileTopic([string]$id, [string]$topic) { $idx = Get-FileIndex; $f = $idx[$id]; if ($f) { $f.topics = @(@($f.topics) | Where-Object { $_.text -ne $topic }); Save-FileIndex $idx } }
# —— 老实的统计：第一次给的对不对（用户没改就点了发送）、问了几次、选了「都不是」几次 ——
function Get-FileStats { if (Test-Path $script:FileStatsFile) { try { return (Get-Content $script:FileStatsFile -Raw | ConvertFrom-Json) } catch {} }; [pscustomobject]@{ offered = 0; accepted = 0; changed = 0; asked = 0; picked = 0; none = 0 } }
function Add-FileStat([string]$k) { $s = Get-FileStats; $s | Add-Member $k ([int]$s.$k + 1) -Force; [IO.File]::WriteAllText($script:FileStatsFile, ($s | ConvertTo-Json -Compress)) }
function Get-FilePage {
  $idx = Get-FileIndex
  @{ links = @($idx.Values | Where-Object { @($_.topics).Count } | ForEach-Object { @{ id = $_.id; name = $_.name; from = $(if ($_.sender -and $_.sender -ne '对方') { $_.sender } else { $_.chat }); topics = @($_.topics | ForEach-Object { $_.text }) } }); stats = (Get-FileStats); count = $idx.Count }
}
