# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 稳定性改动的测试（全在临时文件夹 / 本机假服务器上，不碰真数据、不碰微信）
# a 每一步计时、慢了歇一会儿、出错不影响下一步；b 定时发送不会一直挂着「已开始」；c 服务器连不上：一句人话 + 退让；d 微信连续读空提醒一次；e 日志只留 30 天 / 2 MB；f 过去 24 小时的健康数字
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $root0 = Split-Path $v2 -Parent
. "$v2\lib_v2.ps1"; . "$v2\lib_账号.ps1"
$T = Join-Path $env:TEMP 'secretary_stability'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\v2\actions", "$T\root\data", "$T\root\v0.2\data" | Out-Null
$script:V2Data = "$T\v2"; $script:ActDir = "$T\v2\actions"; $script:DataDir = "$T\root\data"; $script:ChatFile = "$T\v2\chat.jsonl"; $script:ChatArchive = "$T\v2\chat_archive.jsonl"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Step', 'Close-StuckScheduled' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$script:Logged = New-Object System.Collections.ArrayList; function Write-ErrorLog($e, $w, $n) { [void]$script:Logged.Add($w) }; function Show-Problem($t) { }; function Post($o) { }
$script:StepStats = @{}; $script:stepWarned = @{}
# a) 每一步
$ran = 0; Step '会出错的' { throw 'x' }; Step '下一步' { $script:ran = 1 }
Check 'a step that throws is logged and the next step still runs' ($script:Logged -contains 'poll:会出错的' -and $script:ran -eq 1 -and $script:StepStats['会出错的'].errors -eq 1)
1..3 | ForEach-Object { Step '很慢的' { Start-Sleep -Milliseconds 1600 } }
Check 'a slow step is logged each time' (@($script:Logged | Where-Object { $_ -eq 'slow:很慢的' }).Count -eq 3)
$sw = [Diagnostics.Stopwatch]::StartNew(); Step '很慢的' { Start-Sleep -Milliseconds 1600 }; Check 'after 3 slow runs it rests for a minute (skipped instantly)' ($sw.ElapsedMilliseconds -lt 300 -and $script:Logged -contains 'backoff:很慢的')
1..3 | ForEach-Object { Step '对话' { Start-Sleep -Milliseconds 1600 } }; $sw.Restart(); Step '对话' { }; Check 'the chat step is never rested' ($script:StepStats['对话'].until -le (Get-Date))
# b) 定时发送收尾
$script:Sending = @{}
$it = Add-ChatItem @{ role = 'ai'; card = @{ kind = 'send'; status = 'sending'; who = 'x'; text = 'y' } }; $a = New-SendAction 'x' 'y' ''; $a.status = 'confirmed'; Save-Action $a
Add-Scheduled $a.id (Get-Date).AddMinutes(-5) $it.id; Set-ScheduledStatus $a.id 'started'
Close-StuckScheduled; $j = @(Get-Scheduled | Where-Object actionId -eq $a.id)[0]; $c = (Get-ChatItems | Where-Object id -eq $it.id).card
Check "a started job with no sender left -> marked failed, card says so with retry ($($j.status))" ($j.status -eq 'failed' -and $c.status -eq 'closed' -and $c.failed -and (@($c.result)[0].text -match '重试') -and (Get-Action $a.id).status -eq 'failed')
$a2 = New-SendAction 'x' 'y' ''; Add-Scheduled $a2.id (Get-Date).AddMinutes(-5) $it.id; Set-ScheduledStatus $a2.id 'started'; [IO.File]::WriteAllText((Join-Path $script:ActDir "$($a2.id).result.json"), (Protect (@{ ok = $true } | ConvertTo-Json -Compress)))
Close-StuckScheduled; Check 'a started job whose result says sent -> marked done' ((@(Get-Scheduled | Where-Object actionId -eq $a2.id)[0]).status -eq 'done')
$a3 = New-SendAction 'x' 'y' ''; Add-Scheduled $a3.id (Get-Date).AddMinutes(-5) $it.id; Set-ScheduledStatus $a3.id 'started'; $script:Sending[$a3.id] = $it
Close-StuckScheduled; Check 'a job whose sender is still working is left alone' ((@(Get-Scheduled | Where-Object actionId -eq $a3.id)[0]).status -eq 'started')
# c) 服务器连不上
function Get-ServerCfg { @{ base = $script:TestBase } }
$script:TestBase = 'https://127.0.0.1:9'; $script:SrvDown = @{ until = [datetime]::MinValue; step = 0 }
$r = Invoke-Api 'GET' '/v1/meta'; Check "unreachable -> one plain line ($($r.error.message))" ($r.status -eq 0 -and $r.error.message -eq '暂时连不上服务器，稍后自动重试')
$sw.Restart(); $r2 = Invoke-Api 'GET' '/v1/meta'; Check "then backs off without touching the network ($($sw.ElapsedMilliseconds) ms)" ($r2.status -eq 0 -and $sw.ElapsedMilliseconds -lt 100)
$hl = New-Object Net.HttpListener; $hl.Prefixes.Add('http://127.0.0.1:18731/'); $hl.Start(); $job = Start-Job -ScriptBlock { $l = New-Object Net.HttpListener; } ; Remove-Job $job -Force
$script:TestBase = 'http://127.0.0.1:18731'; $script:SrvDown = @{ until = [datetime]::MinValue; step = 0 }
$task = $hl.GetContextAsync(); $call = [powershell]::Create().AddScript({ param($b) Add-Type -AssemblyName System.Net.Http; $c = New-Object Net.Http.HttpClient; $c.GetAsync("$b/v1/meta").Result.StatusCode }).AddArgument($script:TestBase)
$rs = $null; $ctxDone = $false
$ar = [powershell]::Create(); [void]$ar.AddScript({ param($t) $ctx = $t.Result; $ctx.Response.StatusCode = 530; $ctx.Response.Close() }).AddArgument($task); $h1 = $ar.BeginInvoke()
$r3 = Invoke-Api 'GET' '/v1/meta'; [void]$ar.EndInvoke($h1); $hl.Stop()
Check "server answers 530 -> the same plain line, no raw error ($($r3.error.message))" ($r3.status -eq 0 -and $r3.error.message -eq '暂时连不上服务器，稍后自动重试')
Check 'raw server errors shown to you are turned into the plain line' ((Format-UserError 'HTTP 530 origin unreachable') -eq '暂时连不上服务器，稍后自动重试')
# d) 微信连续读空
$w = [Management.Automation.Language.Parser]::ParseFile("$root0\12_值守.ps1", [ref]$null, [ref]$null); foreach ($fn in $w.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Update-WxEmptyCheck' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$root = "$T\root"; $stats = @{}; $script:WxEmpty = 0; $script:WxEmptyWarned = $null
$empty = @{ 列表 = @(); 消息 = @() }; $ok = @{ 列表 = @(1, 2, 3); 消息 = @(1) }
$warned = @(1..4 | ForEach-Object { Update-WxEmptyCheck $empty }) + @(Update-WxEmptyCheck $ok) + @(1..4 | ForEach-Object { Update-WxEmptyCheck $empty })
Check 'empty reads that recover in between -> no notice' (-not ($warned -contains $true))
$fifth = Update-WxEmptyCheck $empty; Check '5 empty reads in a row -> one quiet notice' ($fifth -and (Test-Path "$T\root\v0.2\data\notice_pill.json"))
$again = @(1..5 | ForEach-Object { Update-WxEmptyCheck $empty }); Check 'not repeated within 6 hours' (-not ($again -contains $true))
# e) 日志
$lf = "$T\v2\errors.log"; $old = (Get-Date).AddDays(-40).ToString('s'); $new = (Get-Date).ToString('s'); [IO.File]::WriteAllLines($lf, [string[]]@("$old [x] old", "$new [x] new", "no date line"))
$big = "$T\v2\send_trace.jsonl"; [IO.File]::WriteAllLines($big, [string[]](1..30000 | ForEach-Object { '{"ts":"' + $new + '","id":"a","msg":"' + ('x' * 80) + '"}' }))
[IO.File]::WriteAllText("$T\v2\chat.jsonl", ('{"ts":"' + $old + '"}'))
$n = Limit-Logs; $after = Get-Content $lf
Check "old log lines (over 30 days) removed, recent kept ($n lines trimmed)" ($after -notcontains "$old [x] old" -and $after -contains "$new [x] new" -and $after -contains 'no date line')
Check "a log over 2 MB is cut back to 2 MB, newest kept ($([int]((Get-Item $big).Length / 1KB)) KB)" ((Get-Item $big).Length -le 2MB -and (Get-Content $big -Tail 1) -match $new)
Check 'chat history is never touched' ((Get-Content "$T\v2\chat.jsonl" -Raw) -match $old)
# f) 健康状况
[IO.File]::WriteAllLines("$T\root\data\messages.jsonl", [string[]]@(('{"ts":"' + $new + '"}'), ('{"ts":"' + $new + '"}'), ('{"ts":"' + $old + '"}')))
[IO.File]::WriteAllLines($big, [string[]]@(('{"ts":"' + $new + '","kind":"fg","ok":true,"msg":"已发出"}'), ('{"ts":"' + $new + '","kind":"fg","ok":false,"msg":"用户输入"}'), ('{"ts":"' + $old + '","kind":"fg","ok":false,"msg":"x"}')))
[IO.File]::WriteAllLines($lf, [string[]]@("$new [poll:对话] boom", "$new [vd] info", "$old [poll:对话] old"))
$h = Get-Health; Check "24-hour health: read $($h.read), tried $($h.tried), sent $($h.sent), errors $($h.errors)" ($h.read -eq 2 -and $h.tried -eq 2 -and $h.sent -eq 1 -and $h.errors -eq 1)
Check "reasons listed by kind ($((@($h.why) | ForEach-Object { "$($_.kind):$($_.reason)" }) -join ', '))" (@($h.why | Where-Object { $_.reason -eq '用户输入' }).Count -eq 1 -and @($h.why | Where-Object { $_.reason -eq 'poll:对话' }).Count -eq 1)
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"stability_test: $pass pass, $fail fail"
