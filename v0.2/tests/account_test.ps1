# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 账号 + 插件商城（客户端部分）测试：对着模拟服务端（mock_server.js，回放 server 0.2.0 的真实响应）跑，标注为「模拟」
# 用单独的测试文件夹和测试配置；不碰正式数据、不打开浏览器（打开网页的函数在测试里换成只记录）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
$T = Join-Path $env:TEMP "secretary_acct_test"; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\data\adapters" | Out-Null
. "$v2\lib_v2.ps1"
Copy-Item $script:CfgPath "$T\config.json"; $script:CfgPath = "$T\config.json"; $script:V2Data = "$T\data"; $script:AcctDir = "$T\data"
. "$v2\lib_账号.ps1"; . "$v2\lib_商店.ps1"
$script:AcctDir = "$T\data"; $script:V2Data = "$T\data"
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$script:Opened = New-Object System.Collections.Generic.List[string]
$realOpen = ${function:Open-ServerLink}
function Open-ServerLink([string]$url) { $o = Get-Origin $url; $base = Get-Origin (Get-ServerCfg).base; if (-not $o -or $o -ne $base) { return $false }; $script:Opened.Add($url); $true }   # 测试里不真的打开浏览器
$port = 8811; $base = "http://127.0.0.1:$port"
$srv=[pscustomobject]@{HasExited=$true}; . "$PSScriptRoot\lib_mock_http.ps1"; Set-TestHttpTransport
Add-Type -AssemblyName System.Web.Extensions; $js = New-Object Web.Script.Serialization.JavaScriptSerializer; $js.MaxJsonLength = [int]::MaxValue
$fx = $js.DeserializeObject([IO.File]::ReadAllText("$PSScriptRoot\fixtures\server-0.2.0.json"))
function Ctl([string]$p) { [void](Invoke-WebRequest "$base$p" -Method Post -UseBasicParsing) }
function Invoke-WebRequest([string]$Uri,[string]$Method='GET',[switch]$UseBasicParsing){Invoke-TestHttp $Uri $Method}
try {
  "— 服务器地址 —"
  Assert ((Get-ServerCfg).base -eq 'https://secretary.demandatlas.online') "default server is the public https address"
  Assert (-not (Test-ServerUrl 'http://secretary.demandatlas.online') -and (Test-ServerUrl 'http://127.0.0.1:8811') -and -not (Test-ServerUrl 'ftp://x')) "plain http only allowed for this computer (127.0.0.1); public must be https"
  Set-ServerCfg 'base' $base; Set-ServerCfg 'store_test_key' $true
  Assert ((Test-ServerHealth).ok) "health check against the simulated server"
  Assert (-not (Open-ServerLink 'https://evil.example.com/device') -and -not (& $realOpen 'https://evil.example.com/x')) "links to another site are refused (only the server's own pages open)"

  "— 登录或注册（设备码）—"
  $s = Start-DeviceLogin
  Assert ($s.state -eq 'pending' -and $s.user_code -match '^[A-Z0-9]{4}-[A-Z0-9]{4}$' -and $script:Opened.Count -eq 1 -and $script:Opened[0] -like "$base/device?code=*") "one button: shows the code and opens the server's login/sign-up page ($($s.user_code))"
  $script:DeviceLogin.next = Get-Date; $r = Step-DeviceLogin
  Assert ($r.state -eq 'pending' -and -not (Test-SignedIn)) "before approval in the browser: still waiting, not signed in"
  Ctl '/__approve'; $script:DeviceLogin.next = Get-Date; $r = Step-DeviceLogin
  Assert ($r.state -eq 'ok' -and (Test-SignedIn)) "after approval: signed in"
  $raw = [IO.File]::ReadAllBytes("$T\data\account.dat"); $plain = [Text.Encoding]::UTF8.GetString($raw)
  Assert ($plain -notmatch 'mock-token' -and (Get-AcctToken) -eq 'mock-token-not-secret') "token stored encrypted (DPAPI), not readable as text"

  "— 套餐和额度 —"
  $v = Get-AccountView
  Assert ($v.signedIn -and $v.plan.name -eq '免费版' -and $v.plan.dailyLeft -eq 50000 -and $v.plan.monthLeft -eq 1000000 -and $v.user.email) "account page: plan 免费版, 50000 left today, 1000000 this month"
  Assert (@($v.plan.models).Count -eq 2 -and $v.plan.defaultModel -eq 'claude-sonnet-5-5' -and (Get-ServerCfg).model -eq 'claude-sonnet-5-5') "models in the plan listed; new install uses the plan's default model"
  Assert ($v.link_upgrade -eq "$base/upgrade" -and $v.link_account -eq "$base/account") "升级 / 账号 links come from the server (same site only)"
  Ctl '/__mode?ent=trial'; $v = Get-AccountView
  Assert ($v.plan.name -eq '试用' -and $v.plan.lifeLeft -eq 20000 -and $v.plan.lifeLimit -eq 20000) "trial: one-time allowance shown (20000 total)"
  Ctl '/__mode?ent=exhausted'; $v = Get-AccountView
  Assert ($v.plan.exhausted -eq 'daily' -and $v.plan.dailyLeft -eq 0 -and $v.plan.resets) "used up today: says so, with the reset time ($($v.plan.resets))"
  Ctl '/__mode?ent=normal'

  "— 插件商城 —"
  # 注意：这里不能用 $t 当变量名（和测试文件夹 $T 是同一个变量）
  $cat = Invoke-Api 'GET' '/v1/store/plugins' -Auth
  Assert ($cat.status -eq 200 -and @($cat.json['plugins']).Count -ge 1) "catalog loads ($(@($cat.json['plugins']).Count) plugin)"
  $pk = Get-StorePackage 'wechat-desktop' '1.0.0'
  Assert ($pk.ok) "package downloaded and every check passed (signature with the built-in test key, sha, size, files, permissions, script) $($pk.reason)"
  $cv = Get-ConsentView $pk
  Assert ($cv.perms.Count -ge 1 -and -not ($cv.perms | Where-Object send)) "permission card data: $($cv.perms.Count) permissions, none is 发送"
  $info = Install-StorePlugin $pk
  Assert (@(Get-InstalledPlugins).Count -eq 1 -and (Test-Path "$T\data\adapters\wechat-desktop\installed.json")) "installed"
  Assert ((Uninstall-StorePlugin 'wechat-desktop') -and @(Get-InstalledPlugins).Count -eq 0 -and -not (Test-Path "$T\data\adapters\wechat-desktop")) "uninstall removes it completely"
  $t2 = Get-StorePackage 'send-test' '1.0.0'; $cv2 = if ($t2.ok) { Get-ConsentView $t2 }
  Assert ($t2.ok -and ($cv2.perms | Where-Object send)) "a plugin that asks for 发送 is flagged on the permission card"
  [void](Install-StorePlugin $pk); $u = @(Invoke-StoreUpdateCheck); Assert ($u.Count -eq 0 -and @(Get-InstalledPlugins).Count -eq 1) "update check: up to date → nothing changes"; [void](Uninstall-StorePlugin 'wechat-desktop')

  "— 拒绝不合规的包和脚本（服务端说过了也要本机再查）—"
  $rej = 0; $all = 0; foreach ($n in $fx['negative_scripts']) { $all++; $c = Test-PluginScript $n['permissions'] $n['script']; if (-not $c.ok) { $rej++ } else { "     not rejected: $($n['name'])" } }
  Assert ($rej -eq $all) "bad scripts rejected: $rej / $all (incl. nav key with a region, Enter outside the input box, unknown op)"
  $rej = 0; $all = 0; foreach ($k in $fx['negative_signed'].Keys) { $all++; $p = $fx['negative_signed'][$k]; $c = Test-PluginPackage ([Convert]::FromBase64String($p['zip_b64'])) $p['signature']; if (-not $c.ok) { $rej++ } else { "     not rejected: $k" } }
  Assert ($rej -eq $all) "bad signed packages rejected: $rej / $all"
  $good = $fx['packages']['wechat-desktop-1.0.0']; $zip = [Convert]::FromBase64String($good['zip_b64']); $zip[-1] = $zip[-1] -bxor 1
  $c1 = Test-PluginPackage $zip $good['signature']
  $sig = $js.DeserializeObject($js.Serialize($good['signature'])); $sig['statement']['size'] = [int]$sig['statement']['size'] + 1
  $c2 = Test-PluginPackage ([Convert]::FromBase64String($good['zip_b64'])) $sig
  Assert ((-not $c1.ok) -and $c1.code -eq 'sha_mismatch' -and (-not $c2.ok) -and $c2.code -eq 'bad_signature') "tampered zip → sha_mismatch; tampered statement → bad_signature"
  Set-ServerCfg 'store_test_key' $false
  $wk = Get-StorePackage 'wechat-desktop' '1.0.0'; Assert (-not $wk.ok -and $wk.code -eq 'wrong_key') "without test mode only the pinned production key is trusted: test-signed package refused ($($wk.code))"

  "— 经账号走 AI —"
  $ev = ConvertFrom-Sse ([string]$fx['sse_ok']); $mr = Merge-SseResult $ev
  Assert ($mr.streamedText -eq '你好，我在。' -and $mr.stop_reason -eq 'end_turn' -and $mr.allowance) "SSE parser: start/text/done → full text, stop reason, remaining allowance"
  $bad = "event: start`ndata: {}`n`nevent: error`ndata: {""code"":""quota_exhausted"",""message"":""今天的额度用完了"",""scope"":""daily"",""resets_at"":""2026-11-01T16:00:00Z""}`n`n"
  $e1 = $null; try { [void](Merge-SseResult (ConvertFrom-Sse $bad)) } catch { $e1 = $_.Exception }
  Assert ($e1 -and $e1.Data['code'] -eq 'quota_exhausted' -and (Format-AccountAIError $e1).quota.scope -eq 'daily') "SSE error event mid-stream → quota card (daily)"
  $e2 = $null; try { [void](Merge-SseResult (ConvertFrom-Sse "event: start`ndata: {}`n`nevent: text`ndata: {""text"":""半""}`n`n")) } catch { $e2 = $_.Exception }
  Assert ($e2 -and $e2.Data['code'] -eq 'incomplete') "stream cut off before done → reported as incomplete, not a partial answer"
  $body = @{ model = 'x'; max_tokens = 300; system = @(@{ type = 'text'; text = '系统' }); tools = @(@{ name = 'get_today'; description = 'd'; input_schema = @{ type = 'object' } }); messages = @(@{ role = 'user'; content = '你好' }) }
  function AskAI($b) { try { @{ ok = $true; r = (Read-AccountAI (Start-AccountAI $b 'chat')) } } catch { $x = $_.Exception; while ($x.InnerException -and -not $x.Data['code']) { $x = $x.InnerException }; @{ ok = $false; x = $x; f = (Format-AccountAIError $x) } } }
  Ctl '/__mode?ai=ok'; $a1 = AskAI $body; $sent = (Invoke-WebRequest "$base/__lastai" -UseBasicParsing).Content | ConvertFrom-Json
  Assert ($a1.ok -and ($a1.r.content | Where-Object type -eq 'text').text -eq '你好，我在。' -and $sent.model -eq (Get-ServerCfg).model -and $sent.system -eq '系统' -and $sent.stream) "chat through the account: answer arrives; sends the plan model the user picked (not the caller's), system as text, streaming"
  Ctl '/__mode?ai=tool'; $a2 = AskAI $body; $tu = @($a2.r.content | Where-Object type -eq 'tool_use')
  $msgs = @($body.messages) + @{ role = 'assistant'; content = @($a2.r.rawContent) } + @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = $tu[0].id; content = '今天没有事项' }) }
  $b2 = $body.Clone(); $b2.messages = $msgs; $a3 = AskAI $b2
  Assert ($tu.Count -eq 1 -and $tu[0].name -eq 'get_today' -and $a3.ok -and ($a3.r.content | Where-Object type -eq 'text').text) "tool loop: model asks for get_today → result sent back → final answer (simulated tool step)"
  Ctl '/__mode?ai=quota_daily'; $q1 = AskAI $body
  Assert (-not $q1.ok -and $q1.f.quota.scope -eq 'daily' -and $q1.f.text -match '今天的额度用完了') "daily quota used up → 「$($q1.f.text)」 + 升级 card"
  Ctl '/__mode?ai=quota_lifetime'; $q2 = AskAI $body
  Assert (-not $q2.ok -and $q2.f.quota.scope -eq 'lifetime' -and $q2.f.text -match '试用额度用完') "trial used up → 「$($q2.f.text)」"
  Ctl '/__mode?ai=bad_model'; $q3 = AskAI $body
  Assert (-not $q3.ok -and $q3.f.quota.scope -eq 'model' -and $q3.f.text -match 'claude-sonnet-5-5' -and (Get-ServerCfg).model -eq 'claude-sonnet-5-5') "model not in plan → says which models are allowed; does not switch models by itself"
  Ctl '/__mode?ai=ok'

  "— 服务器没上线 —"
  Set-ServerCfg 'base' 'https://127.0.0.1:1'; $sw = [Diagnostics.Stopwatch]::StartNew(); $ov = Get-AccountView
  Assert ($ov.offline -and $sw.ElapsedMilliseconds -lt 15000) "server unreachable → calm 「还没上线」 state in $($sw.ElapsedMilliseconds) ms (no error)"
  $sv = Get-StoreView; Set-ServerCfg 'store_test_key' $false; $sv2 = Get-StoreView
  Set-ServerCfg 'base' $base; $script:MetaKeyCheck = $null; $sv2 = Get-StoreView
  Assert ($sv2.error -match '对不上' -and -not $sv2.plugins.Count -and $null -ne $sv2.installed) "server's /v1/meta key ≠ pinned key → store not trusted, quiet message; installed plugins still listed (can uninstall)"
  Set-ServerCfg 'base' $base; Set-ServerCfg 'store_test_key' $true
  $script:MetaKeyCheck = $null; $sv3 = Get-StoreView; $si = Start-StoreInstall 'wechat-desktop' '1.0.0'; $ci = Confirm-StoreInstall 'wechat-desktop'; $sv4 = Get-StoreView
  Assert ($sv3.plugins.Count -ge 1 -and $si.ok -and $si.consent.perms.Count -and $ci.ok -and ($sv4.plugins | Where-Object id -eq 'wechat-desktop').installed -eq '1.0.0' -and $sv4.installed.Count -eq 1) "store page: list → download+verify → permission card → 安装 → shows installed"
  [void](Uninstall-StorePlugin 'wechat-desktop')
  "— 退出 —"
  [void](Invoke-Logout); Assert (-not (Test-SignedIn) -and -not (Test-Path "$T\data\account.dat")) "退出登录 removes the token from this computer"
  $leak = @(Get-ChildItem $T -Recurse -File | Where-Object { [IO.File]::ReadAllText($_.FullName) -match 'mock-token-not-secret' }).Count
  Assert ($leak -eq 0) "token never written as plain text anywhere ($leak files)"
} finally { if (-not $srv.HasExited) { $srv.Kill() }; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
"RESULT: $script:ok / $script:tot passed (simulated server)"
