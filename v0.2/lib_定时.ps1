# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
. (Join-Path $PSScriptRoot 'lib_动作.ps1')
# lib_定时.ps1 — 定时替你发一条（比如「11 点提醒 Leo明远 交周报」）：你在卡片上点了「好，到点替你发」才会定下来。
# 存在 data\scheduled.jsonl（每行加密：编号、发送动作编号、什么时候、卡片编号、状态），秘书重启、电脑重启后都还在。
# 到点后走和平时一样的发送（核对聊天名、核对字、锁屏检查、等你停手……），只发卡片上批准的那段字；过点超过 30 分钟就先问你还要不要发。
function Get-SchedPath { Join-Path $script:V2Data 'scheduled.jsonl' }
function Get-Scheduled { $f = Get-SchedPath; if (-not (Test-Path $f)) { return @() }; @(Get-Content $f -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { (Unprotect $_) | ConvertFrom-Json } catch {} } | Where-Object { $_ }) }
function Save-Scheduled($jobs) { $lines = @($jobs | ForEach-Object { Protect ($_ | ConvertTo-Json -Depth 8 -Compress) }); Write-ActionAtomic (Get-SchedPath) (($lines -join [Environment]::NewLine) + $(if ($lines.Count) { [Environment]::NewLine } else { '' })) }
function Add-Scheduled([string]$actionId, [datetime]$at, [string]$itemId) {
  $jobs = @(Get-Scheduled | Where-Object { $_.actionId -ne $actionId }); $jobs += [pscustomobject]@{ actionId = $actionId; at = ([DateTimeOffset]$at).ToString('o'); itemId = $itemId; status = 'scheduled'; execution_state = 'queued'; created = (Get-Date).ToString('s') }; Save-Scheduled $jobs }
function Set-ScheduledStatus([string]$actionId, [string]$status) { $jobs = @(Get-Scheduled); foreach ($j in $jobs) { if ($j.actionId -eq $actionId) { $j.status = $status; $st = switch ($status) { 'started' { 'running' } 'done' { 'succeeded' } 'unknown' { 'unknown' } { $_ -in 'failed','cancelled' } { 'failed' } default { 'queued' } }; Set-ActionField $j 'execution_state' $st } }; Save-Scheduled $jobs }
# 「11:00」「23:00」「2026-11-02 11:00」都认；只给了时刻且已经过了，就算明天
function Resolve-SchedTime([string]$s, [datetime]$now = (Get-Date)) {
  $s = ([string]$s).Trim(); $d = [datetime]::MinValue
  if ($s -match '^\d{4}-\d{1,2}-\d{1,2}[ T]\d{1,2}:\d{2}') { if ([datetime]::TryParse($s, [ref]$d)) { return $d } }
  if ($s -match '^(\d{1,2})[:：](\d{2})$') { $d = $now.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2]); if ($d -le $now) { $d = $d.AddDays(1) }; return $d }
  $null }
function Format-SchedTime([datetime]$d, [datetime]$now = (Get-Date)) { $day = if ($d.Date -eq $now.Date) { '今天' } elseif ($d.Date -eq $now.Date.AddDays(1)) { '明天' } elseif ($d.Date -eq $now.Date.AddDays(2)) { '后天' } else { $d.ToString('MM-dd') }; $part = if ($d.Hour -lt 5) { '凌晨' } elseif ($d.Hour -lt 12) { '上午' } elseif ($d.Hour -lt 13) { '中午' } elseif ($d.Hour -lt 18) { '下午' } else { '晚上' }; $w = if ($day -eq '今天' -and $part -eq '晚上') { '今晚' } else { "$day$part" }; "$w $($d.ToString('HH:mm'))（$($d.ToString('yyyy-MM-dd')) 本机时间）" }

# 时区：默认本机；只有明确说了别的时区（北京时间、国内时间、东八区、美东、美西、ET/PT/UTC……）才按那个时区算。认不出的时区名返回 $null（让 AI 重新问清楚）
$script:ZoneMap = [ordered]@{ '北京时间|国内时间|东八区|中国时间|北京|上海|CST\(China\)|UTC\+8|GMT\+8' = 'China Standard Time'; '美东|东部时间|纽约|\bET\b|\bEST\b|\bEDT\b' = 'Eastern Standard Time'; '美西|西部时间|洛杉矶|旧金山|\bPT\b|\bPST\b|\bPDT\b' = 'Pacific Standard Time'; '美中|芝加哥|\bCT\b' = 'Central Standard Time'; '日本|东京' = 'Tokyo Standard Time'; '\bUTC\b|\bGMT\b|格林' = 'UTC' }
function Resolve-Zone([string]$z) { if (-not $z -or -not $z.Trim()) { return [TimeZoneInfo]::Local }; foreach ($k in $script:ZoneMap.Keys) { if ($z -match $k) { return [TimeZoneInfo]::FindSystemTimeZoneById($script:ZoneMap[$k]) } }; $null }
# 返回 @{ local = 本机时间; utc; zoneLabel; wall = 那个时区的钟点 } ；只给钟点且那个时区里今天已经过了，就算下一次（明天）
function Resolve-SchedAt([string]$s, [string]$zone, [datetime]$nowLocal = (Get-Date)) {
  $tz = Resolve-Zone $zone; if (-not $tz) { return $null }
  $nowUtc = $nowLocal.ToUniversalTime(); $nowZ = [TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $tz)
  $s = ([string]$s).Trim(); $wall = $null; $d = [datetime]::MinValue
  if ($s -match '^\d{4}-\d{1,2}-\d{1,2}[ T]\d{1,2}:\d{2}') { if ([datetime]::TryParse($s, [ref]$d)) { $wall = $d } }
  elseif ($s -match '^(\d{1,2})[:：](\d{2})$') { $wall = $nowZ.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2]); if ($wall -le $nowZ) { $wall = $wall.AddDays(1) } }
  if (-not $wall) { $wall = Resolve-CnTime $s $nowZ }
  if (-not $wall) { return $null }
  $utc = [TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($wall, [DateTimeKind]::Unspecified), $tz)
  @{ local = $utc.ToLocalTime(); utc = $utc; wall = $wall; zoneLabel = $(if ($tz.Id -eq [TimeZoneInfo]::Local.Id) { '' } else { $zone.Trim() }) } }
function Format-SchedAt($x, [datetime]$now = (Get-Date)) {
  $loc = Format-SchedTime $x.local $now
  if ($x.zoneLabel) { "$($x.zoneLabel) $($x.wall.ToString('MM-dd HH:mm'))（本机 $loc）" } else { $loc } }
# 中文说法的时间：「11点」「今晚11点」「明天上午9点半」「下午3点15」「后天8点」「23:00」。规则：
#   明说的词优先（上午/早上→上午，中午，下午/晚上/今晚/傍晚→下午；今天/明天/后天→那一天；13 点及以上照原样）；
#   光说「11点」（没有上午下午、也没说哪天）→ 按 12 小时制，11:00 和 23:00 里离现在最近的那个将来时刻；说了哪天没说上下午 → 上午
function ConvertFrom-CnNum([string]$s) { if ($s -match '^\d+$') { return [int]$s }; $m = @{ '零' = 0; '〇' = 0; '一' = 1; '二' = 2; '两' = 2; '三' = 3; '四' = 4; '五' = 5; '六' = 6; '七' = 7; '八' = 8; '九' = 9 }
  if ($s -eq '十') { return 10 }; if ($s -match '^十(.)$') { return 10 + $m[$Matches[1]] }; if ($s -match '^(.)十(.)?$') { return $m[$Matches[1]] * 10 + $(if ($Matches[2]) { $m[$Matches[2]] } else { 0 }) }; if ($m.ContainsKey($s)) { return $m[$s] }; $null }
function Resolve-CnTime([string]$said, [datetime]$now) {
  $s = ($said -replace '\s', ''); $n = '[0-9零〇一二两三四五六七八九十]+'
  if ($s -notmatch "($n)[点:：时](半|($n)分?|(\d{2}))?") { return $null }
  $h = ConvertFrom-CnNum $Matches[1]; $mi = 0; if ($Matches[2] -eq '半') { $mi = 30 } elseif ($Matches[3]) { $mi = ConvertFrom-CnNum $Matches[3] } elseif ($Matches[4]) { $mi = [int]$Matches[4] }
  if ($null -eq $h -or $h -gt 24 -or $null -eq $mi -or $mi -gt 59) { return $null }
  $dayOff = if ($s -match '后天') { 2 } elseif ($s -match '明天|明早|明晚') { 1 } elseif ($s -match '今天|今晚|今早') { 0 } else { $null }
  $pm = $s -match '下午|晚上|今晚|明晚|傍晚|夜里'; $am = $s -match '上午|早上|早晨|明早|今早|凌晨'; $noon = $s -match '中午'
  if ($h -ge 13 -or $h -eq 0) { $hh = $h % 24 } elseif ($pm) { $hh = $(if ($h -lt 12) { $h + 12 } else { 12 }) } elseif ($noon) { $hh = $(if ($h -le 2) { $h + 12 } else { $h }) } elseif ($am) { $hh = $(if ($h -eq 12) { 0 } else { $h }) }
  elseif ($null -ne $dayOff) { $hh = $h }   # 说了哪天、没说上下午：上午
  else {   # 光说「X点」：X 点和 X+12 点里离现在最近的将来时刻
    $c1 = $now.Date.AddHours($h % 12).AddMinutes($mi); $c2 = $c1.AddHours(12); foreach ($c in $c1, $c2, $c1.AddDays(1)) { if ($c -gt $now) { return $c } } }
  $d = $now.Date.AddDays($(if ($null -ne $dayOff) { $dayOff } else { 0 })).AddHours($hh).AddMinutes($mi)
  if ($null -eq $dayOff -and $d -le $now) { $d = $d.AddDays(1) }
  $d }