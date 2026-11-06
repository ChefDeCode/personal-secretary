# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 真服务器上的严格检查（2026-11-05 恢复）：要用你在这台电脑上的登录，所以用真正的安装目录（只读，不改设置、不装东西）。
# 服务器连不上（530 / 域名找不到 / 超时）→ 记「跳过」并写原因；服务器回 401 / 404 / 5xx 或者任何一项没过 → 失败。绝不把错误状态算成通过
$ErrorActionPreference = 'Stop'
$v2 = (Split-Path $PSScriptRoot -Parent)
try { Add-Type -AssemblyName System.Net.Http; $hc = New-Object Net.Http.HttpClient; $hc.Timeout = [TimeSpan]::FromSeconds(12); $pr = $hc.GetAsync('https://secretary.demandatlas.online/healthz').GetAwaiter().GetResult(); $code = [int]$pr.StatusCode }
catch { '[ENVIRONMENT] server unreachable (DNS / timeout / network) — skipped'; exit 54 }
if ($code -eq 530) { '[SERVER530] status=530 — server tunnel down, skipped'; exit 53 }
if ($code -ne 200) { "  [FAIL] server health returned HTTP $code"; exit 1 }# 正式服务端（公网）上不需要账号的检查：只读，不登录、不安装、不改设置；只输出通过/失败和用时
. "$v2\lib_v2.ps1"; . "$v2\lib_账号.ps1"; . "$v2\lib_商店.ps1"
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$cfg = Get-ServerCfg
Assert ($cfg.base -eq 'https://secretary.demandatlas.online' -and -not (Read-Config).server.store_test_key) "using the pinned public server, production keys (not test mode)"
$sw = [Diagnostics.Stopwatch]::StartNew(); $h = Test-ServerHealth; Assert $h.ok "health check ($($sw.ElapsedMilliseconds) ms)"
# 1) /v1/meta
$sw.Restart(); $m = Invoke-Api 'GET' '/v1/meta'; $ms = $sw.ElapsedMilliseconds; $j = $m.json
Assert ($m.status -eq 200 -and ([string]$j['base_url']).TrimEnd('/') -eq $cfg.base) "meta: base_url equals the pinned URL ($ms ms; server $($j['version']))"
Assert ((Test-MetaKey $j['store_signing_key'] $script:StorePins.prod) -and (Test-MetaKey $j['release_signing_key'] $script:ReleasePins.prod)) "meta: store key and release key both match the pinned keys (id + bytes)"
Assert (-not (Test-MetaKey $j['store_signing_key'] $script:ReleasePins.prod) -and -not (Test-MetaKey $j['release_signing_key'] $script:StorePins.prod)) "the two keys are kept apart (store key ≠ release key)"
$lk = @(); if ($j['links']) { $lk = @($j['links'].Values) }; $bad = @($lk | Where-Object { (Get-Origin ([string]$_)) -ne (Get-Origin $cfg.base) })
Assert ($lk.Count -ge 1 -and $bad.Count -eq 0) "meta: all $($lk.Count) links are on the same origin"
"     signup_open=$($j['signup_open']) payments=$($j['payments'])"
$mk = Get-MetaKeyCheck -Fresh; Assert ($mk.ok -eq $true) "client key check accepts this server"
# 2) 更新检查：还没有发布过版本 → 安静处理
$sw.Restart(); $u = Invoke-Api 'GET' '/v1/client/latest?version=0.2.0&channel=stable'; $ums = $sw.ElapsedMilliseconds
"     client/latest → HTTP $($u.status) $(if ($u.error) { $u.error['code'] } elseif ($u.json) { ($u.json.Keys -join ',') })"
Assert ($u.status -in 200, 204, 404 -and -not ($u.json -and $u.json['version'])) "update check: nothing published yet, handled calmly (no update card) ($ums ms)"
# 3) 商城：官方示例插件 wechat-desktop 1.0.0 在列表里；下载并完整校验（只校验，不安装）
$sw.Restart(); $sv = Get-StoreView; $sms = $sw.ElapsedMilliseconds
"     store view: plugins $(@($sv.plugins).Count); needLogin=$([bool]$sv.needLogin) error=$($sv.error) comingSoon=$([bool]$sv.comingSoon)"
$wd = @($sv.plugins | Where-Object { $_.id -eq 'wechat-desktop' })
Assert (-not $sv.comingSoon -and ($wd.Count -eq 1 -and $wd[0].latest -eq '1.0.0')) "store opens (no 「即将开放」) and lists wechat-desktop 1.0.0 ($sms ms)"
if ($wd.Count) { $sw.Restart(); $pk = Get-StorePackage 'wechat-desktop' '1.0.0'; $vms = $sw.ElapsedMilliseconds
  Assert ($pk.ok) "wechat-desktop 1.0.0: download + full verification with the pinned store key passed ($vms ms) $(if (-not $pk.ok) { "code=$($pk.code) $($pk.reason)" })"
  if ($pk.ok) { "     verified: sha256 ok, signature ok (key $($pk.statement['key_id'])), manifest == statement, script $(@($pk.script['actions'].Keys).Count) actions within the step table; NOT installed" } }
Assert (-not (Test-Path (Join-Path $script:V2Data 'adapters\wechat-desktop'))) "nothing installed"
"RESULT: $script:ok / $script:tot passed (live server, no account)"
if ($script:ok -ne $script:tot) { exit 1 }; exit 0
