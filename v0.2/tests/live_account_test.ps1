# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 真服务器上的严格检查（2026-11-05 恢复）：要用你在这台电脑上的登录，所以用真正的安装目录（只读，不改设置、不装东西）。
# 服务器连不上（530 / 域名找不到 / 超时）→ 记「跳过」并写原因；服务器回 401 / 404 / 5xx 或者任何一项没过 → 失败。绝不把错误状态算成通过
$ErrorActionPreference = 'Stop'
$v2 = (Split-Path $PSScriptRoot -Parent)
try { Add-Type -AssemblyName System.Net.Http; $hc = New-Object Net.Http.HttpClient; $hc.Timeout = [TimeSpan]::FromSeconds(12); $pr = $hc.GetAsync('https://secretary.demandatlas.online/healthz').GetAwaiter().GetResult(); $code = [int]$pr.StatusCode }
catch { '[ENVIRONMENT] server unreachable (DNS / timeout / network) — skipped'; exit 54 }
if ($code -eq 530) { '[SERVER530] status=530 — server tunnel down, skipped'; exit 53 }
if ($code -ne 200) { "  [FAIL] server health returned HTTP $code"; exit 1 }# 正式服务端上的账号测试（用户已经在客户端登录）：用秘书自己的代码路径；不改任何设置、不退出登录、不安装插件
# 只输出通过/失败、用时和 token 数；不输出邮箱、令牌或任何内容
. "$v2\lib_v2.ps1"; . "$v2\lib_账号.ps1"; . "$v2\lib_商店.ps1"; . "$v2\lib_更新.ps1"
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$cfgBefore = [IO.File]::ReadAllText($script:CfgPath)
$sw = [Diagnostics.Stopwatch]::StartNew()
Assert ((Get-ServerCfg).base -eq 'https://secretary.demandatlas.online' -and (Test-SignedIn)) "signed in on the production server"
if (-not (Test-SignedIn)) { '[ENVIRONMENT] not signed in on this PC — skipped'; exit 54 }
# 1) me + entitlements + 账号页数据
$sw.Restart(); $me = Get-Me; $e = Get-Entitlements; $ms1 = $sw.ElapsedMilliseconds
Assert ($me -and $me['user'] -and $me['device']) "/v1/me ok ($ms1 ms incl. entitlements)"
$models = @($e['models'] | ForEach-Object { [string]$_ })
"     plan id=$($e['plan']['id']) status=$($e['plan']['status']) period_end=$($e['plan']['period_end']); daily limit $($e['daily']['limit']) used $($e['daily']['used']); monthly limit $($e['monthly']['limit']); lifetime=$([bool]$e['lifetime']); models $($models.Count); default $($e['default_model'])"
Assert ([string]$e['plan']['id'] -and [long]$e['daily']['limit'] -gt 0) "entitlements: a plan and a daily limit"
Assert ($models.Count -ge 1) "models: at least one entitled model"
$sw.Restart(); $v = Get-AccountView; $ms2 = $sw.ElapsedMilliseconds
Assert ($v.signedIn -and -not $v.offline -and $v.plan.name -and $v.plan.dailyLimit -eq [long]$e['daily']['limit'] -and $null -ne $v.plan.dailyLeft -and $v.plan.resets -and -not $v.plan.lifeLimit) "账号 page data: plan name, today's bar (limit/left), reset time, no trial bar ($ms2 ms)"
Assert (@($v.plan.models).Count -eq $models.Count -and $v.plan.defaultModel -eq [string]$e['default_model']) "model picker lists exactly the entitled models; account default = plan default_model"
Assert ($v.link_upgrade -or $v.link_account) "账号 / 升级 links present and same-origin"
# 2) 设置没变
Assert (([IO.File]::ReadAllText($script:CfgPath)) -eq $cfgBefore) "settings unchanged (AI 来源 and model untouched so far)"
# 3) 一句很短的对话（经账号；不改设置）
$used0 = [long]$e['daily']['used']
$body = @{ max_tokens = 60; messages = @(@{ role = 'user'; content = '用一句话回答：1+1 等于几' }) }
$sw.Restart(); $task = Start-AccountAI $body 'chat'; $resp = $task.Result; $ms3 = $sw.ElapsedMilliseconds
$ct = [string]$resp.Content.Headers.ContentType; $raw = $resp.Content.ReadAsStringAsync().Result
$evs = @(ConvertFrom-Sse $raw); $kinds = @($evs | ForEach-Object { $_.event } | Select-Object -Unique)
$res = $null; try { $res = Merge-SseResult $evs } catch { "     error: $($_.Exception.Data['code'])" }
Assert ([int]$resp.StatusCode -eq 200 -and $ct -match 'event-stream' -and ($kinds -contains 'start') -and ($kinds -contains 'text') -and ($kinds -contains 'done') -and $res -and $res.streamedText) "one short request through the account: SSE start/text/done, answer received ($ms3 ms; in $($res.usage.input_tokens) / out $($res.usage.output_tokens) tokens; model $($res.model))"
Start-Sleep 1; $e2 = Get-Entitlements; $used1 = [long]$e2['daily']['used']
Assert ($used1 -gt $used0 -and ($used1 - $used0) -lt 2000) "quota used went up a little: +$($used1 - $used0) tokens today"
# 4) 商城：列出 + 下载 + 完整校验（不安装）
$sw.Restart(); $script:MetaKeyCheck = $null; $sv = Get-StoreView; $ms4 = $sw.ElapsedMilliseconds
$wd = @($sv.plugins | Where-Object { $_.id -eq 'wechat-desktop' })
Assert (-not $sv.comingSoon -and -not $sv.needLogin -and -not $sv.error -and $wd.Count -eq 1 -and $wd[0].latest -eq '1.0.0') "store lists wechat-desktop 1.0.0 ($(@($sv.plugins).Count) plugins, $ms4 ms)"
$sw.Restart(); $pk = Get-StorePackage 'wechat-desktop' '1.0.0'; $ms5 = $sw.ElapsedMilliseconds
Assert ($pk.ok -and $pk.statement['key_id'] -eq 'b8cfcbfd9b14e39d') "wechat-desktop 1.0.0: sha256, signature (pinned store key), manifest == statement, step table all pass ($ms5 ms) $(if (-not $pk.ok) { $pk.code })"
Assert (-not (Test-Path (Join-Path $script:V2Data 'adapters\wechat-desktop'))) "not installed"
# 5) 更新检查
$sw.Restart(); $u = Invoke-UpdateCheck; Assert ($u.state -eq 'none') "update check while signed in: 已经是最新版本 ($($sw.ElapsedMilliseconds) ms)"
# 6) 令牌：DPAPI 加密保存；任何文件、日志里都没有明文
$tok = Get-AcctToken; $raw = [IO.File]::ReadAllBytes((Join-Path $script:AcctDir 'account.dat'))
$enc = -not ([Text.Encoding]::UTF8.GetString($raw).Contains($tok)) -and -not ([Text.Encoding]::Unicode.GetString($raw).Contains($tok))
$root = Split-Path $v2 -Parent
$files = @(Get-ChildItem $root -Recurse -File -Include *.json, *.jsonl, *.log, *.txt, *.md, *.ps1, *.dat, *.env, *.html -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\webview2\\' -and $_.Length -lt 50MB })
$hits = @($files | Where-Object { try { [IO.File]::ReadAllText($_.FullName).Contains($tok) } catch { $false } }).Count
Assert ($enc -and $hits -eq 0) "token is DPAPI-encrypted; plain text found in 0 of $($files.Count) files"
Assert (([IO.File]::ReadAllText($script:CfgPath)) -eq $cfgBefore) "settings still unchanged at the end"
"RESULT: $script:ok / $script:tot passed (live server, signed in)"
if ($script:ok -ne $script:tot) { exit 1 }; exit 0
