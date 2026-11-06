# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 找文件测试：30 个虚构文件、6 个发件人（含名字和内容不符、重名、没下载的卡片、扫描版 PDF），全部在临时文件夹；不读真实文件、不发送
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $root = Split-Path $v2 -Parent
. "$root\lib_识别.ps1"; . "$v2\lib_v2.ps1"
$T = Join-Path $env:TEMP 'secretary_files_test'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\files" | Out-Null
$script:AttData = $T; $script:PeopleFile = "$T\people.jsonl"; $script:FileIdxFile = "$T\files_index.jsonl"; $script:FileStatsFile = "$T\stats.json"
. "$v2\lib_文件.ps1"; $script:FileIdxFile = "$T\files_index.jsonl"; $script:FileStatsFile = "$T\stats.json"
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
Add-Type -AssemblyName System.Drawing
# —— 造文件 ——
function W-Zip([string]$path, $entries) { $fs = [IO.File]::Create($path); $za = New-Object IO.Compression.ZipArchive ($fs, [IO.Compression.ZipArchiveMode]::Create); foreach ($k in $entries.Keys) { $e = $za.CreateEntry($k); $w = New-Object IO.StreamWriter ($e.Open(), (New-Object Text.UTF8Encoding $false)); $w.Write($entries[$k]); $w.Dispose() }; $za.Dispose(); $fs.Dispose() }
function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }
function New-Png([string]$path, [string]$text) { $b = New-Object Drawing.Bitmap 900, 220; $g = [Drawing.Graphics]::FromImage($b); $g.Clear([Drawing.Color]::White); $g.TextRenderingHint = 'AntiAliasGridFit'; $g.DrawString($text, (New-Object Drawing.Font 'Microsoft YaHei', 28), [Drawing.Brushes]::Black, 20, 60); $g.Dispose(); $b.Save($path, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose() }
# 扫描版 PDF：一页只有一张图（JPEG），没有文字层
function New-ScanPdf([string]$path, [string]$text) {
  $b = New-Object Drawing.Bitmap 1240, 1754; $g = [Drawing.Graphics]::FromImage($b); $g.Clear([Drawing.Color]::White); $g.TextRenderingHint = 'AntiAliasGridFit'; $g.DrawString($text, (New-Object Drawing.Font 'Microsoft YaHei', 36), [Drawing.Brushes]::Black, (New-Object Drawing.RectangleF 80, 120, 1080, 1500)); $g.Dispose()
  $ms = New-Object IO.MemoryStream; $b.Save($ms, [Drawing.Imaging.ImageFormat]::Jpeg); $jpg = $ms.ToArray(); $b.Dispose()
  $enc = [Text.Encoding]::ASCII; $out = New-Object IO.MemoryStream; $offs = @{}
  $put = { param([string]$s) $bb = $enc.GetBytes($s); $out.Write($bb, 0, $bb.Length) }
  & $put "%PDF-1.4`n"
  $offs[1] = $out.Position; & $put "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj`n"
  $offs[2] = $out.Position; & $put "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj`n"
  $offs[3] = $out.Position; & $put "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >> endobj`n"
  $offs[4] = $out.Position; & $put "4 0 obj << /Type /XObject /Subtype /Image /Width 1240 /Height 1754 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length $($jpg.Length) >> stream`n"; $out.Write($jpg, 0, $jpg.Length); & $put "`nendstream endobj`n"
  $c = "q 595 0 0 842 0 0 cm /Im0 Do Q"; $offs[5] = $out.Position; & $put "5 0 obj << /Length $($c.Length) >> stream`n$c`nendstream endobj`n"
  $x = $out.Position; & $put "xref`n0 6`n0000000000 65535 f `n"; foreach ($i in 1..5) { & $put ("{0:D10} 00000 n `n" -f $offs[$i]) }
  & $put "trailer << /Size 6 /Root 1 0 R >>`nstartxref`n$x`n%%EOF"; [IO.File]::WriteAllBytes($path, $out.ToArray())
}
function New-File([string]$name, [string]$text, [string]$dir) {
  $p = Join-Path $dir $name; New-Item -ItemType Directory -Force $dir | Out-Null
  switch -regex ([IO.Path]::GetExtension($name)) {
    '\.docx' { W-Zip $p @{ '[Content_Types].xml' = '<Types/>'; 'word/document.xml' = "<w:document><w:body><w:p><w:r><w:t>$(Esc $text)</w:t></w:r></w:p></w:body></w:document>" } }
    '\.xlsx' { W-Zip $p @{ '[Content_Types].xml' = '<Types/>'; 'xl/sharedStrings.xml' = "<sst>$((($text -split '，') | ForEach-Object { "<si><t>$(Esc $_)</t></si>" }) -join '')</sst>" } }
    '\.pptx' { W-Zip $p @{ '[Content_Types].xml' = '<Types/>'; 'ppt/slides/slide1.xml' = "<p:sld><a:p><a:r><a:t>$(Esc $text)</a:t></a:r></a:p></p:sld>" } }
    '\.pdf' { New-ScanPdf $p $text }
    '\.png' { New-Png $p $text }
    default { [IO.File]::WriteAllText($p, $text) }
  }
  Get-Item $p
}
# 发件人：4 个单聊 + 群「项目群」里的 2 个人
$corpus = @(
  @('张三', '张三', '会议纪要.docx', '和明远确认了合同条款，明远下周一回复最终版本'), @('张三', '张三', '周报.docx', '华东项目进度正常，华东项目下周验收'),
  @('张三', '张三', '报价单.xlsx', '陈总报价，单价，数量，合计'), @('张三', '张三', '照片1.png', '团建安排 周六爬山'),
  @('张三', '张三', '资料.pdf', '预算审批表 第三季度预算 需要财务签字'),
  @('李四', '李四', '合同草稿.docx', '与陈总的合作合同草稿，付款方式'), @('李四', '李四', '报价单.xlsx', '华东项目报价，华东项目，设备清单'),
  @('李四', '李四', '发票.png', '发票 金额 三千元'), @('李四', '李四', '方案.pptx', '明远培训方案 明远负责第二部分'), @('李四', '李四', '说明.txt', '预算说明：明年预算增加'),
  @('王五', '王五', '明远名片.png', '王明远 销售经理'), @('王五', '王五', '年度计划.docx', '华东项目年度计划'), @('王五', '王五', '数据.xlsx', '陈总销售数据，陈总，季度'),
  @('王五', '王五', '会议纪要.docx', '预算会议：预算削减百分之十，预算下月执行'), @('王五', '王五', '截图.png', '团建报名表'),
  @('赵六', '赵六', '设计稿.pptx', '陈总要的设计稿 第二版'), @('赵六', '赵六', '需求.docx', '明远提的需求：明远希望增加导出功能'),
  @('赵六', '赵六', '合同.pdf', '__CARD_ONLY__'), @('赵六', '赵六', '清单.csv', '团建物品清单,帐篷,水'), @('赵六', '赵六', '笔记.md', '华东项目会议笔记'),
  @('项目群', '钱七', '排期.xlsx', '华东项目排期，华东项目，里程碑'), @('项目群', '钱七', '汇报.pptx', '预算汇报 预算执行情况'), @('项目群', '钱七', '纪要.txt', '明远在会上说下周交付，明远负责测试'),
  @('项目群', '钱七', '扫描件.pdf', '陈总签字的授权书 陈总同意'), @('项目群', '钱七', '图.png', '发票 报销单'),
  @('项目群', '孙八', '文档.docx', '团建方案：团建去海边'), @('项目群', '孙八', '表格.xlsx', '明远报销，明远，差旅'), @('项目群', '孙八', '新建文本.txt', '陈总的联系方式和地址'),
  @('项目群', '孙八', '演示.pptx', '华东项目演示文稿'), @('项目群', '孙八', '附件.pdf', '预算附件 预算明细'))
$i = 0; $truth = @{}
foreach ($c in $corpus) {
  $i++; $ts = (Get-Date).AddDays(-30 + $i).ToString('s')
  if ($c[3] -eq '__CARD_ONLY__') { $path = ''; $size = $null } else { $fi = New-File $c[2] $c[3] "$T\files\$i"; $path = $fi.FullName; $size = $fi.Length }
  $id = "att$i"; $truth["$($c[1])|$($c[2])"] = $id
  Write-AttRecord ([ordered]@{ id = $id; ts = $ts; kind = 'file'; mode = $(if ($path) { 'local' } else { 'missing' }); app = '微信'; conv = (AttP $c[0]); sender = (AttP $(if ($c[0] -eq $c[1]) { '对方' } else { $c[1] })); msg_key = ''; name = (AttP $c[2]); shownBytes = ''; path = $(if ($path) { AttP $path } else { '' }); size = $size; mtime = ''; qhash = '' })
}
# 虚构的人：Leo明远（用户确认过「明远」）；单聊和群
$script:Src = @{ chats = @(@{ app = '微信'; title = 'Leo明远'; last = '2026-10-31T20:00:00' }, @{ app = '微信'; title = '张三'; last = '' }, @{ app = '微信'; title = '李四'; last = '' }, @{ app = '微信'; title = '王五'; last = '' }, @{ app = '微信'; title = '赵六'; last = '' }, @{ app = '微信'; title = '项目群'; last = '' })
  senders = @(@{ app = '微信'; name = '钱七'; group = '项目群'; last = '' }, @{ app = '微信'; name = '孙八'; group = '项目群'; last = '' }) }
function Get-PeopleSources { $script:Src }
[void](Add-PersonAlias '微信' 'Leo明远' '明远' 'user_confirmed')
$sw = [Diagnostics.Stopwatch]::StartNew(); $n = Update-FileIndex 100; $ims = $sw.ElapsedMilliseconds
$idx = Get-FileIndex
"— 建索引 —"
Assert ($n -eq 30 -and $idx.Count -eq 30) "30 file cards indexed ($ims ms)"
Assert ($idx['att18'].state -eq 'card_only') "un-downloaded file card marked 「只有卡片」"
try { $pt = Get-PdfText (Get-ChildItem "$T\files\5" -Filter *.pdf).FullName; "     pdf text length $($pt.Length)" } catch { "     pdf error: $($_.Exception.GetType().Name) $($_.Exception.Message)" }
Assert (@($idx['att5'].keywords) -contains '预算') "scanned PDF read with local OCR (keywords include 预算)"
Assert (@($idx['att4'].keywords) -contains '团建') "image read with local OCR"
Assert (([IO.File]::ReadAllText($script:FileIdxFile)) -notmatch '预算|明远') "index file is encrypted"
"— 「A 上次发给我的关于 C 的文件」—"
$q = @(@('张三', '明远', '张三|会议纪要.docx'), @('张三', '预算', '张三|资料.pdf'), @('李四', '明远', '李四|方案.pptx'), @('李四', '华东项目', '李四|报价单.xlsx'),
  @('王五', '预算', '王五|会议纪要.docx'), @('赵六', '明远', '赵六|需求.docx'), @('钱七', '明远', '钱七|纪要.txt'), @('钱七', '陈总', '钱七|扫描件.pdf'),
  @('孙八', '明远', '孙八|表格.xlsx'), @('孙八', '团建', '孙八|文档.docx'), @('王五', '陈总', '王五|数据.xlsx'), @('赵六', '合同', '赵六|合同.pdf'), @('Leo明远', '', ''), @('李四', '团建', ''))
$top1 = 0; $clear = 0; $clearWrong = 0; $answerable = 0
foreach ($x in $q) {
  $r = Find-Files $x[0] $x[1] '' 'last' ''; $want = if ($x[2]) { $truth[$x[2]] } else { $null }; $got = if ($r.top.Count) { $r.top[0].f.id } else { $null }
  if ($want) { $answerable++; if ($got -eq $want) { $top1++ }; if ($r.clear) { $clear++; if ($got -ne $want) { $clearWrong++ } } }
  "     $($x[0]) / $(if ($x[1]) { $x[1] } else { '-' }) → $(if ($got) { $idx[$got].name } else { '（没有）' })$(if ($r.clear) { '  [直接给]' } else { '  [问]' })$(if ($want -and $got -ne $want) { "  ✗ 应为 $($idx[$want].name)" })"
}
$acc = [Math]::Round(100.0 * $top1 / $answerable); $askRate = [Math]::Round(100.0 * ($answerable - $clear) / $answerable)
"     top-1 accuracy $top1/$answerable ($acc%); shown directly $clear, asked $($answerable - $clear) (ask rate $askRate%); shown directly but wrong: $clearWrong"
Assert ($acc -ge 90) "top-1 accuracy ≥ 90% ($acc%)"
Assert ($clearWrong -eq 0) "never confidently wrong (a direct pick is always right; otherwise it asks)"
$r = Find-Files 'Leo明远' '' '' 'last' ''; Assert (-not $r.top.Count) "nothing from that person → empty (says so plainly)"
$r = Find-Files '李四' '团建' '' 'last' ''; Assert (-not $r.clear) "李四 never sent anything about 团建 → not shown as a confident match (asks)"
"— 选过一次就记住 —"
$r = Find-Files '王五' '明远' '' 'last' ''; Add-FileTopic 'att12' '明远'
$r2 = Find-Files '王五' '明远' '' 'last' ''; Assert ($r2.clear -and $r2.top[0].f.id -eq 'att12') "after the user picks 「年度计划」 as the 明远 file, it's offered directly next time"
$pg = Get-FilePage; Assert (@($pg.links).Count -eq 1 -and $pg.links[0].topics -contains '明远') "Settings → 记忆 lists the file ↔ topic link"
Remove-FileTopic 'att12' '明远'; Assert (-not @((Get-FilePage).links).Count) "link can be deleted"
Add-FileStat 'offered'; Add-FileStat 'accepted'; Add-FileStat 'asked'; Add-FileStat 'none'; $st = Get-FileStats
Assert ($st.offered -eq 1 -and $st.accepted -eq 1 -and $st.asked -eq 1 -and $st.none -eq 1) "honest counters work (first pick accepted / asked / 都不是)"
"— 对话里：「把张三上次发给我的关于明远的文件发给明远」（两条 AI 路径；到确认卡为止，不发送）—"
. "$v2\lib_账号.ps1"
$script:ChatFile = "$T\chat.jsonl"; $script:ChatArchive = "$T\chat_archive.jsonl"; $script:SummaryFile = "$T\summary.txt"; $script:ActDir = "$T\actions"; New-Item -ItemType Directory -Force $script:ActDir | Out-Null
function Get-ConvNames { @($script:Src.chats | ForEach-Object { $_.title }) }
$ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-HistoryMessages', 'Start-Turn', 'Send-TurnRequest', 'Poll-Turn', 'Finish-Turn', 'Start-Claude', 'Read-Claude', 'Get-ApiKey', 'On-PersonChoice' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
foreach ($as in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -in '$stepNames', '$http' }, $false)) { . ([scriptblock]::Create($as.Extent.Text)) }
$usageFile = "$T\usage.json"; $script:Usage = [pscustomobject]@{ calls = 0; input = 0; output = 0; cacheRead = 0; usd = 0.0 }; $script:Posted = New-Object System.Collections.ArrayList
function Post($o) { [void]$script:Posted.Add($o) }; function Show-Notice($t) {}; function Write-MemUsed {}; function Write-ErrorLog {}; function Start-Compaction {}; function Post-MiniRaw {}
$realGetSwitch = ${function:Get-Switch}; function Get-Switch([string]$k) { if ($k -eq 'send_messages') { return $true }; & $realGetSwitch $k }
function Wait-Turn { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($script:Turn -and $sw.Elapsed.TotalSeconds -lt 150) { Start-Sleep -Milliseconds 200; try { Poll-Turn } catch { if ($script:Turn) { Finish-Turn $null '这一步出错了' } } } }
$script:ModelFixture='files'; . "$PSScriptRoot\lib_mock_model.ps1"
foreach ($mode in 'local', 'account') {
  if ($mode -eq 'account' -and -not (Test-SignedIn)) { "     account path skipped"; continue }
  if ($mode -eq 'account') { function Get-AIMode { 'account' } } else { function Get-AIMode { 'local' } }
  Remove-Item "$T\chat*.jsonl" -ErrorAction SilentlyContinue; $script:Posted.Clear()
  $q = '把张三上次发给我的关于明远的文件发给明远'; [void](Add-ChatItem @{ role = 'me'; text = $q }); $sw = [Diagnostics.Stopwatch]::StartNew(); Start-Turn $q; Wait-Turn
  $sc = @($script:Posted | Where-Object { $_.type -eq 'item' -and $_.item.card.kind -eq 'send' } | ForEach-Object { $_.item.card })
  Assert ($sc.Count -eq 1 -and $sc[0].who -eq 'Leo明远' -and $sc[0].file -eq '会议纪要.docx' -and $sc[0].fileMeta -match '来自 张三' -and $sc[0].fileMeta -match '明远' -and $sc[0].status -eq 'open') "[$mode] finds 会议纪要.docx (name says nothing about 明远) from 张三 → OPEN card to Leo明远 with 「来自 张三 · 日期 · 内容讲的是「明远」」 ($([int]$sw.Elapsed.TotalSeconds) s)"
  if (-not $sc.Count) { "     cards: $(@($script:Posted | Where-Object { $_.type -eq 'item' -and $_.item.card } | ForEach-Object { $_.item.card.kind }) -join ','); steps: $(@($script:Posted | Where-Object { $_.type -eq 'item' } | ForEach-Object { $_.item.steps } | ForEach-Object { $_.text }) -join '、')" }
}
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $script:ok / $script:tot passed"
