# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 认人测试：全部用虚构的联系人（不读真实聊天、不发送、不碰微信）；人和称呼存在临时文件里
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . "$v2\lib_账号.ps1"
$T = Join-Path $env:TEMP 'secretary_people_test'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null
$script:PeopleFile = "$T\people.jsonl"; $script:ChatFile = "$T\chat.jsonl"; $script:ChatArchive = "$T\chat_archive.jsonl"; $script:SummaryFile = "$T\summary.txt"; $script:ActDir = "$T\actions"; New-Item -ItemType Directory -Force $script:ActDir | Out-Null
$cfgText = { if (Test-Path -LiteralPath $script:CfgPath) { [IO.File]::ReadAllText($script:CfgPath) } else { '<no config file>' } }; $cfgBefore = & $cfgText
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
# 虚构的名字来源：单聊 Leo明远（最近）、王明远（较早）、文件传输助手；群「测试群」里的发送人 周明远
$script:Src = @{ chats = @(@{ app = '微信'; title = 'Leo明远'; last = '2026-10-31T20:00:00' }, @{ app = '微信'; title = '王明远'; last = '2026-10-20T10:00:00' }, @{ app = '微信'; title = '文件传输助手'; last = '' })
                 senders = @(@{ app = '微信'; name = '周明远'; group = '测试群'; last = '2026-10-31T19:00:00' }) }
function Get-PeopleSources { $script:Src }; function Get-ConvNames { @($script:Src.chats | ForEach-Object { $_.title }) }   # 对话测试里模型看到的也只是虚构的会话名
"— 认人规则 —"
$r = Resolve-Person 'Leo明远'; Assert ($r.status -eq 'direct' -and $r.chat.title -eq 'Leo明远') "exact chat title → used directly"
$save = $script:Src.chats; $script:Src.chats = @($save | Where-Object { $_.title -ne '王明远' })
$r = Resolve-Person '明远'; Assert ($r.status -eq 'ask' -and @($r.cands).Count -eq 1 -and $r.cands[0].title -eq 'Leo明远') "only one fuzzy candidate → still ASKS the first time"
$script:Src.chats = $save
$r = Resolve-Person '明远'; $ts = @($r.cands | ForEach-Object { $_.title })
Assert ($r.status -eq 'ask' -and ($ts -contains 'Leo明远') -and ($ts -contains '王明远') -and $ts[0] -eq 'Leo明远') "collision (Leo明远 / 王明远) → asks with both, most recent first"
$r = Resolve-Person 'mingyuan'; Assert ($r.status -eq 'ask' -and (@($r.cands | ForEach-Object { $_.title }) -contains 'Leo明远')) "pinyin 「mingyuan」 → candidate found, asks"
[void](Add-PersonAlias '微信' 'Leo明远' '明远' 'user_confirmed')
$r = Resolve-Person '明远'; Assert ($r.status -eq 'direct' -and $r.chat.title -eq 'Leo明远' -and $r.why -eq 'alias') "after the user picked once: 明远 → Leo明远 directly (even though 王明远 exists)"
"— 建议「是同一个人吗」—"
$sg = @(Get-PeopleSuggestions); Assert (@($sg | Where-Object { $_.name -eq '周明远' -and $_.title -eq 'Leo明远' }).Count -eq 1) "AI notices 周明远 (group) may be Leo明远 → only a suggestion"
$r = Resolve-Person '周明远'; Assert ($r.status -ne 'direct') "suggestion is never auto-linked (周明远 not resolved directly yet)"
Set-PeopleNotSame '周明远' '微信' 'Leo明远'
Assert (-not @(Get-PeopleSuggestions | Where-Object { $_.name -eq '周明远' -and $_.title -eq 'Leo明远' }).Count) "「不是」 is remembered: not asked again"
$x = Set-PeopleSame '周明远' 'Leo明远'
$r = Resolve-Person '周明远'; Assert ($x.ok -and $x.text -match '记住了' -and $r.status -eq 'direct' -and $r.chat.title -eq 'Leo明远') "「周明远就是Leo明远」 → saved with a one-line confirmation, then resolves directly"
"— 设置里删掉称呼 —"
$p = @(Get-People)[0]; Remove-PersonAlias $p.id '明远'
$r = Resolve-Person '明远'; Assert ($r.status -eq 'ask') "deleting the alias in Settings brings the question back"
$pg = Get-PeoplePage; Assert (@($pg.people).Count -eq 1 -and @($pg.people[0].aliases).Count -eq 1) "人和称呼 page lists the person with the remaining alias (周明远)"
$raw = [IO.File]::ReadAllText($script:PeopleFile); Assert ($raw -notmatch '明远') "people.jsonl is encrypted (no names readable in the file)"
"— 长期记忆里已有的人 —"
function Get-Memories { @([pscustomobject]@{ id = 'm1'; type = 'person'; people = @('示例人A'); text = '示例人A 是同事' }, [pscustomobject]@{ id = 'm2'; type = 'fact'; people = @(); text = 'x' }) }
$n = Sync-PeopleFromMemory; $n2 = Sync-PeopleFromMemory
Assert ($n -eq 1 -and $n2 -eq 0 -and @(Get-People | Where-Object { @($_.memIds) -contains 'm1' }).Count -eq 1) "existing memory people linked to a person record once (no duplicates, memory itself unchanged)"
Remove-Item function:\Get-Memories

"— 对话里（两条 AI 路径各一次；到确认卡为止，不发送）—"
$ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-HistoryMessages', 'Start-Turn', 'Send-TurnRequest', 'Poll-Turn', 'Finish-Turn', 'Start-Claude', 'Read-Claude', 'Get-ApiKey', 'On-PersonChoice', 'Convert-BackgroundValue' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text.Replace('$PSScriptRoot','$script:TestAppRoot'))) }
foreach ($as in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -in '$stepNames', '$http' }, $false)) { . ([scriptblock]::Create($as.Extent.Text)) }
$usageFile = "$T\usage.json"; $script:Usage = [pscustomobject]@{ calls = 0; input = 0; output = 0; cacheRead = 0; usd = 0.0 }
$script:Posted = New-Object System.Collections.ArrayList
function Post($o) { [void]$script:Posted.Add($o) }; function Show-Notice($t) {}; function Write-MemUsed {}; function Write-ErrorLog {}; function Start-Compaction {}; function Post-MiniRaw {}
$realGetSwitch = ${function:Get-Switch}; function Get-Switch([string]$k) { if ($k -eq 'send_messages') { return $true }; & $realGetSwitch $k }   # 只在测试里当作打开，不改设置
. "$PSScriptRoot\lib_test_workers.ps1"
function Wait-Turn { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($script:Turn -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 200; try { Step-SecWork; Poll-Turn } catch { if ($script:Turn) { Finish-Turn $null '这一步出错了' } } } }
$script:ModelFixture='people'; . "$PSScriptRoot\lib_mock_model.ps1"
foreach ($mode in 'local', 'account') {
  if ($mode -eq 'account' -and -not (Test-SignedIn)) { "     account path skipped (not signed in)"; continue }
  if ($mode -eq 'account') { function Get-AIMode { 'account' } } else { function Get-AIMode { 'local' } }
  Remove-Item $script:PeopleFile, "$T\chat*.jsonl" -ErrorAction SilentlyContinue
  $script:Posted.Clear(); $q = '给明远发条消息说明天见'; [void](Add-ChatItem @{ role = 'me'; text = $q }); Start-Turn $q; Wait-Turn
  $pc = @($script:Posted | Where-Object { $_.type -eq 'item' -and $_.item.card -and $_.item.card.kind -eq 'person' } | ForEach-Object { $_.item })
  $titles = if ($pc.Count) { @($pc[0].card.cands | ForEach-Object { $_.title }) } else { @() }
  Assert ($pc.Count -eq 1 -and ($titles -contains 'Leo明远') -and ($titles -contains '王明远') -and -not @($script:Posted | Where-Object { $_.type -eq 'item' -and $_.item.card.kind -eq 'send' }).Count) "[$mode] 「给明远发…」 → asks 「你说的「明远」是哪一位？」 with both candidates, no send card yet"
  if (-not $pc.Count) { continue }
  $script:Posted.Clear(); $k = [array]::IndexOf($titles, 'Leo明远') + 1; On-PersonChoice $pc[0] $k ''; Wait-Turn
  $mem = @($script:Posted | Where-Object { $_.type -eq 'item' -and $_.item.card.kind -eq 'person' -and $_.item.card.result[0].text -match '记住了：明远 = Leo明远' }).Count
  $sc = @($script:Posted | Where-Object { $_.type -eq 'item' -and $_.item.card.kind -eq 'send' } | ForEach-Object { $_.item.card })
  Assert ($mem -and $sc.Count -eq 1 -and $sc[0].who -eq 'Leo明远' -and $sc[0].said -eq '明远' -and $sc[0].status -eq 'open') "[$mode] pick → 「记住了：明远 = Leo明远」 → continues to an OPEN send card 「发给 Leo明远（你说的「明远」）」 (not sent)"
  $script:Posted.Clear(); Start-Turn '给明远发条消息说后天见'; Wait-Turn
  $sc2 = @($script:Posted | Where-Object { $_.type -eq 'item' -and $_.item.card.kind -eq 'send' } | ForEach-Object { $_.item.card })
  Assert ($sc2.Count -eq 1 -and $sc2[0].who -eq 'Leo明远' -and -not @($script:Posted | Where-Object { $_.item.card.kind -eq 'person' }).Count) "[$mode] second time: no question, straight to the confirm card for Leo明远"
}
Assert ((& $cfgText) -eq $cfgBefore) "settings unchanged"
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $script:ok / $script:tot passed"

Stop-SecWorkers
if($script:ok -ne $script:tot){exit 1}
