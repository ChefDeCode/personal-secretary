# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_账号.ps1 — 连接我们自己的服务端（API 见 server\API.md）：设备码登录 / 注册、套餐和用量、经账号走 AI、插件商店的网络部分
# 安全：
#   - 服务器地址除 127.0.0.1 / localhost 外必须是 https；令牌只发给设置里的那个地址（同源）
#   - 令牌用 DPAPI（当前用户）加密存 data\account.dat，从不写进日志、报告或 errors.log；device_code 只放在内存里
#   - 只打开和服务器地址同源的 http/https 网页（登录确认、账号、升级）
Add-Type -AssemblyName System.Net.Http, System.Security, System.Web.Extensions
if (-not $script:AcctDir) { $script:AcctDir = Join-Path $PSScriptRoot 'data' }
$script:AcctEntropy = [Text.Encoding]::UTF8.GetBytes('secretary-account-v1')
$script:AcctHttp = New-Object System.Net.Http.HttpClient; $script:AcctHttp.Timeout = [TimeSpan]::FromSeconds(180)   # AI 回答、下载插件包
$script:AcctQuick = New-Object System.Net.Http.HttpClient; $script:AcctQuick.Timeout = [TimeSpan]::FromSeconds(12)   # 普通接口：连不上就尽快说「还没上线」，不卡住
$script:AcctJs = New-Object Web.Script.Serialization.JavaScriptSerializer; $script:AcctJs.MaxJsonLength = [int]::MaxValue
$script:AcctNotice = ''   # 给界面看的一句话（比如「已在别处退出，请重新登录」）

$script:DefaultServer = try { [string]([IO.File]::ReadAllText((Join-Path $PSScriptRoot '默认设置.json')) | ConvertFrom-Json).server_base } catch { '' }; if (-not $script:DefaultServer) { $script:DefaultServer = 'https://secretary.demandatlas.online' }   # 正式服务端（公网）；设置里可以改（测试用 127.0.0.1）
# —— 设置：config.server = { base; ai_mode = local|account; model; store_events }——
function Get-ServerCfg {
  $s = (Read-Config).server
  [pscustomobject]@{ base = $(if ($s.base) { ([string]$s.base).TrimEnd('/') } else { $script:DefaultServer }); ai_mode = $(if ($s.ai_mode) { [string]$s.ai_mode } else { '' }); model = [string]$s.model; store_events = [bool]$s.store_events }
}
function Set-ServerCfg([string]$key, $value) { $cfg = Read-Config; $s = if ($cfg.server) { $cfg.server } else { [pscustomobject]@{} }; $s | Add-Member $key $value -Force; $cfg | Add-Member server $s -Force; Save-Config $cfg }
# 地址是否可用：127.0.0.1/localhost 可以 http，其它必须 https；返回规范化的源（scheme://host:port）或 $null
function Get-Origin([string]$url) {
  $u = $null; if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$u)) { return $null }
  if ($u.Scheme -notin 'http', 'https') { return $null }
  if ($u.Scheme -eq 'http' -and $u.Host -notin '127.0.0.1', 'localhost', '[::1]') { return $null }
  "$($u.Scheme)://$($u.Host):$($u.Port)".ToLower()
}
function Test-ServerUrl([string]$url) { [bool](Get-Origin $url) }
# 打开服务器给的网页：必须和服务器地址同源，只用 http/https
function Open-ServerLink([string]$url) {
  $o = Get-Origin $url; $base = Get-Origin (Get-ServerCfg).base
  if (-not $o -or $o -ne $base) { return $false }
  Start-Process ([Uri]$url).AbsoluteUri; $true
}

# —— 令牌（DPAPI）——
function Get-AcctToken { $f = Join-Path $script:AcctDir 'account.dat'; if (-not (Test-Path $f)) { return $null }; try { [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($f), $script:AcctEntropy, 'CurrentUser')) } catch { $null } }
function Save-AcctToken([string]$t) { [IO.File]::WriteAllBytes((Join-Path $script:AcctDir 'account.dat'), [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($t), $script:AcctEntropy, 'CurrentUser')) }
function Clear-AcctToken { $f = Join-Path $script:AcctDir 'account.dat'; if (Test-Path $f) { Remove-Item $f -Force }; $script:AcctCache = @{} }
function Test-SignedIn { [bool](Get-AcctToken) }

# —— 请求：返回 @{ status; json; error; headers }；401 token_revoked / no_token 时清掉令牌 ——
function New-ApiRequest([string]$method, [string]$path, $body, [switch]$Auth) {
  $base = (Get-ServerCfg).base; if (-not (Test-ServerUrl $base)) { throw '服务器地址不安全：除本机外必须用 https' }
  $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($method)), ($base + $path)
  if ($Auth) { $t = Get-AcctToken; if ($t) { [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $t") } }   # 令牌只发给设置里的这个地址
  if ($null -ne $body) { $req.Content = New-Object System.Net.Http.StringContent ($script:AcctJs.Serialize($body)), ([Text.Encoding]::UTF8), 'application/json' }
  $req
}
function Read-ApiResponse($resp, [switch]$Raw) {
  $r = @{ status = [int]$resp.StatusCode; json = $null; error = $null; headers = $resp.Headers; content = $resp.Content }
  if ($Raw) { return $r }
  $txt = if ($resp.Content) { $resp.Content.ReadAsStringAsync().Result } else { '' }   # 204 之类没有内容的响应
  if ($txt) { try { $r.json = $script:AcctJs.DeserializeObject($txt) } catch {} }
  if ($r.status -ge 400) {
    $e = if ($r.json -and $r.json['error']) { $r.json['error'] } else { @{ code = "http_$($r.status)"; message = "服务器返回 $($r.status)"; retryable = ($r.status -ge 500) } }
    $ra = $null; try { if ($resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) { $ra = [int]$resp.Headers.RetryAfter.Delta.Value.TotalSeconds } } catch {}
    if ($ra -and -not $e['retry_after']) { $e['retry_after'] = $ra }
    $r.error = $e
    if ($r.status -eq 401 -and $e['code'] -in 'token_revoked', 'no_token') { Clear-AcctToken; $script:AcctNotice = '已在别处退出，请重新登录' }
  }
  $r
}
# 服务器连不上（断网、超时、5xx 比如 530）：统一一句「暂时连不上服务器，稍后自动重试」；之后按 30 秒 / 1 / 2 / 5 / 15 分钟退让，退让期间不再去连
$script:SrvDown = @{ until = [datetime]::MinValue; step = 0; base = '' }   # 按服务器地址记：换了地址就重新来
$script:SrvBackoff = @(30, 60, 120, 300, 900)
function Get-OfflineResult { @{ status = 0; json = $null; error = @{ code = 'unreachable'; message = '暂时连不上服务器，稍后自动重试'; retryable = $true } } }
function Invoke-Api([string]$method, [string]$path, $body = $null, [switch]$Auth) {
  $b0 = [string](Get-ServerCfg).base; if ($script:SrvDown.base -ne $b0) { $script:SrvDown = @{ until = [datetime]::MinValue; step = 0; base = $b0 } }
  if ((Get-Date) -lt $script:SrvDown.until) { return (Get-OfflineResult) }   # 正在退让：不去连
  $r = $null
  try { $resp = $script:AcctQuick.SendAsync((New-ApiRequest $method $path $body -Auth:$Auth)).Result; $r = Read-ApiResponse $resp } catch { $r = $null }
  if (-not $r -or $r.status -eq 0 -or ($r.status -ge 500 -and $r.status -le 599)) {
    $i = [Math]::Min($script:SrvDown.step, $script:SrvBackoff.Count - 1); $script:SrvDown.until = (Get-Date).AddSeconds($script:SrvBackoff[$i]); $script:SrvDown.step++
    return (Get-OfflineResult) }
  $script:SrvDown.step = 0; $r
}
function Test-ServerHealth { $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Invoke-Api 'GET' '/healthz'; @{ ok = ($r.status -eq 200); ms = $sw.ElapsedMilliseconds; message = $(if ($r.status -eq 200) { '连接正常' } elseif ($r.error) { $r.error['message'] } else { "返回 $($r.status)" }) } }

# —— 设备码登录（RFC 8628）：界面显示 user_code，浏览器里确认；device_code 只在内存 ——
$script:DeviceLogin = $null
# 设备名：登录时告诉服务端「这是哪台设备」，只用来在账号页面区分你的设备。
# 默认是「Windows 电脑-」加 4 位随机字符（第一次用时生成并记在设置里），不用 Windows 用户名和电脑名；你可以在 设置 → 账号 里改
function Test-DeviceName([string]$n) { $n = "$n".Trim(); $n.Length -ge 1 -and $n.Length -le 40 -and $n -notmatch '[\x00-\x1f\x7f]' }
function Get-DeviceName {
  $n = try { [string](Read-Config).server.device_name } catch { '' }
  if (Test-DeviceName $n) { return $n.Trim() }
  $n = 'Windows 电脑-' + [guid]::NewGuid().ToString('n').Substring(0, 4).ToUpper(); Set-ServerCfg 'device_name' $n; $n
}
function Start-DeviceLogin {
  $name = Get-DeviceName
  $r = Invoke-Api 'POST' '/v1/device/code' @{ device_name = $name }
  if ($r.status -ne 200) { $script:DeviceLogin = $null; return @{ state = 'error'; message = $r.error['message'] } }
  $j = $r.json
  $script:DeviceLogin = @{ device_code = [string]$j['device_code']; user_code = [string]$j['user_code']; uri = [string]$j['verification_uri_complete']; interval = [Math]::Max(1, [int]$j['interval']); expires = (Get-Date).AddSeconds([int]$j['expires_in']); next = (Get-Date).AddSeconds([Math]::Max(1, [int]$j['interval'])); device_name = $name }
  $opened = Open-ServerLink $script:DeviceLogin.uri
  @{ state = 'pending'; user_code = $script:DeviceLogin.user_code; opened = $opened; device_name = $name }
}
function Stop-DeviceLogin { $script:DeviceLogin = $null }
# 到时间才问一次；返回 $null（还没到时间）或 @{ state = pending|ok|error; message }
function Step-DeviceLogin([datetime]$now = (Get-Date)) {
  $d = $script:DeviceLogin; if (-not $d) { return $null }; if ($now -lt $d.next) { return $null }
  if ($now -gt $d.expires) { $script:DeviceLogin = $null; return @{ state = 'error'; message = '确认码过期了，请重新开始' } }
  $r = Invoke-Api 'POST' '/v1/device/token' @{ device_code = $d.device_code }
  if ($r.status -eq 200 -and $r.json['access_token']) {
    Save-AcctToken ([string]$r.json['access_token']); $script:DeviceLogin = $null; $script:AcctNotice = ''
    $e = Get-Entitlements; if ($e -and -not (Get-ServerCfg).model -and $e['default_model']) { Set-ServerCfg 'model' ([string]$e['default_model']) }   # 新装：用套餐默认模型
    return @{ state = 'ok' } }
  $code = if ($r.error) { [string]$r.error['code'] } else { '' }
  switch ($code) {
    'authorization_pending' { $d.next = $now.AddSeconds($d.interval); return @{ state = 'pending' } }
    'slow_down' { $ni = if ($r.json['error']['interval']) { [int]$r.json['error']['interval'] } elseif ($r.json['interval']) { [int]$r.json['interval'] } else { $d.interval + 5 }; $d.interval = [Math]::Max($d.interval + 1, $ni); $d.next = $now.AddSeconds($d.interval); return @{ state = 'pending'; slowed = $d.interval } }
    { $_ -in 'access_denied', 'expired_token', 'invalid_grant' } { $script:DeviceLogin = $null; return @{ state = 'error'; code = $code; message = $(if ($r.error['message']) { $r.error['message'] } else { '登录没有完成，请重新开始' }) } }
    default { $d.next = $now.AddSeconds([Math]::Max($d.interval, 10)); return @{ state = 'pending'; transient = $(if ($r.error) { $r.error['message'] }) } }   # 网络问题：放慢再试
  }
}
function Invoke-Logout { $r = $null; if (Test-SignedIn) { $r = Invoke-Api 'DELETE' '/v1/devices/self' -Auth }; Clear-AcctToken; $script:AcctNotice = ''; $true }

# —— 账号、套餐、用量（缓存一会儿，界面刷新时重新拿）——
$script:AcctCache = @{}
function Get-Me { $r = Invoke-Api 'GET' '/v1/me' -Auth; if ($r.status -eq 200) { $r.json } }
function Get-Entitlements { $r = Invoke-Api 'GET' '/v1/entitlements' -Auth; if ($r.status -eq 200) { $script:AcctCache.ent = $r.json; $r.json } }
function Get-UsageDays([int]$days = 7) { $r = Invoke-Api 'GET' "/v1/usage?days=$days" -Auth; if ($r.status -eq 200) { $r.json['days'] } }
function Get-ServerMeta { $r = Invoke-Api 'GET' '/v1/meta'; if ($r.status -eq 200) { $r.json } }
# 「明天 08:00 恢复」这样的本地时间说法
function Format-ResetTime([string]$utc) {
  $t = [datetime]::MinValue; if (-not [datetime]::TryParse($utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$t)) { return '' }
  $l = $t.ToLocalTime(); $n = (Get-Date).Date
  $day = if ($l.Date -eq $n) { '今天' } elseif ($l.Date -eq $n.AddDays(1)) { '明天' } else { "$($l.Month)月$($l.Day)日" }
  "$day $($l.ToString('HH:mm'))"
}
# 设置 → 账号 页的数据（不含令牌）
function Get-AccountView {
  $cfg = Get-ServerCfg; $v = [ordered]@{ base = $cfg.base; signedIn = (Test-SignedIn); notice = $script:AcctNotice; ai_mode = $cfg.ai_mode; model = $cfg.model; store_events = $cfg.store_events; hasLocalKey = [bool](Get-LocalApiKey); device_name = $(try { [string](Read-Config).server.device_name } catch { '' }) }
  if ($script:DeviceLogin) { $v.login = @{ state = 'pending'; user_code = $script:DeviceLogin.user_code; uri = $script:DeviceLogin.uri } }
  # 服务器还没上线 / 连不上：安安静静说一句，不当成错误
  $hz = Invoke-Api 'GET' '/healthz'; if ($hz.status -ne 200) { $v.offline = $true; return $v }
  if (-not $v.signedIn) { return $v }
  $me = Get-Me; if (-not (Test-SignedIn)) { $v.signedIn = $false; $v.notice = $script:AcctNotice; return $v }
  $e = Get-Entitlements; $u = Get-UsageDays 7; $meta = Get-ServerMeta
  if ($me) { $v.user = @{ name = [string]$me['user']['name']; email = [string]$me['user']['email'] }; $v.device = [string]$me['device']['name'] }
  if ($e) { $v.plan = @{ name = [string]$e['plan']['name']; id = [string]$e['plan']['id']; dailyLimit = $e['daily']['limit']; dailyUsed = $e['daily']['used']; dailyLeft = $e['daily']['remaining']; monthLimit = $e['monthly']['limit']; monthUsed = $e['monthly']['used']; monthLeft = $e['monthly']['remaining']
      lifeLimit = $(if ($e['lifetime']) { $e['lifetime']['limit'] }); lifeLeft = $(if ($e['lifetime']) { $e['lifetime']['remaining'] }); exhausted = [string]$e['exhausted']; resets = (Format-ResetTime ([string]$e['resets_at'])); models = @($e['models']); defaultModel = [string]$e['default_model'] } }
  if ($u) { $v.usage = @($u | ForEach-Object { @{ day = [string]$_['day']; tokens = [long]$_['tokens']; requests = [int]$_['requests'] } }) }
  # 升级 / 管理订阅：只有服务端 /v1/meta 给了链接才显示（不在客户端写死路径）
  $links = if ($meta) { $meta['links'] } else { $null }
  if ($links) { foreach ($k in 'upgrade', 'manage', 'account', 'signup') { if ($links[$k] -and (Get-Origin ([string]$links[$k])) -eq (Get-Origin $cfg.base)) { $v["link_$k"] = [string]$links[$k] } } }
  $v
}
function Get-LocalApiKey { $f = Join-Path (Split-Path $PSScriptRoot -Parent) '.env'; if (Test-Path $f) { foreach ($l in Get-Content $f -Encoding UTF8) { if ($l -match '^\s*ANTHROPIC_API_KEY\s*=\s*(.+?)\s*$') { return $Matches[1] } } }; $null }
# AI 走哪里：用户选了就按选的；没选时有本机测试密钥就用本机（这台开发机保持原样），没有就只能用账号
function Get-AIMode { $m = (Get-ServerCfg).ai_mode; if ($m) { return $m }; if ((Get-LocalApiKey) -or ((Get-Command Get-ProviderKey -ErrorAction SilentlyContinue) -and (Get-ProviderKey (Get-AiCfg).provider))) { 'local' } else { 'account' } }

# —— 流式回答（SSE）：把整段文本拆成事件 ——
function ConvertFrom-Sse([string]$text) {
  $events = New-Object System.Collections.Generic.List[object]; $ev = 'message'; $data = New-Object System.Collections.Generic.List[string]
  foreach ($line in ($text -replace "`r`n", "`n" -replace "`r", "`n") -split "`n") {
    if ($line -eq '') { if ($data.Count) { $d = $data -join "`n"; $obj = $null; try { $obj = $script:AcctJs.DeserializeObject($d) } catch {}; $events.Add(@{ event = $ev; data = $obj; raw = $d }) }; $ev = 'message'; $data.Clear(); continue }
    if ($line.StartsWith(':')) { continue }   # 注释 / 心跳
    $i = $line.IndexOf(':'); $f = if ($i -ge 0) { $line.Substring(0, $i) } else { $line }; $v = if ($i -ge 0) { $line.Substring($i + 1) } else { '' }; if ($v.StartsWith(' ')) { $v = $v.Substring(1) }
    if ($f -eq 'event') { $ev = $v } elseif ($f -eq 'data') { $data.Add($v) }
  }
  if ($data.Count) { $d = $data -join "`n"; $obj = $null; try { $obj = $script:AcctJs.DeserializeObject($d) } catch {}; $events.Add(@{ event = $ev; data = $obj; raw = $d }) }
  $events
}
# 把 SSE 事件合成和 Claude Messages API 一样形状的结果；出错时抛出带 code/message 的异常
function Merge-SseResult($events) {
  $text = New-Object Text.StringBuilder; $done = $null; $err = $null; $start = $null
  foreach ($e in $events) { switch ($e.event) { 'start' { $start = $e.data } 'text' { [void]$text.Append([string]$e.data['text']) } 'done' { $done = $e.data } 'error' { $err = $e.data } } }
  if ($err) { $x = [Exception]::new([string]$err['message']); $x.Data['code'] = [string]$err['code']; $x.Data['retryable'] = [bool]$err['retryable']; $x.Data['retry_after'] = $err['retry_after']; $x.Data['resets_at'] = $err['resets_at']; $x.Data['scope'] = $err['scope']; $x.Data['models'] = $err['models']; throw $x }
  if (-not $done) { $x = [Exception]::new('回答中途断开了'); $x.Data['code'] = 'incomplete'; $x.Data['retryable'] = $true; throw $x }
  $content = if ($done['content']) { @($done['content']) } else { @(@{ type = 'text'; text = $text.ToString() }) }
  [pscustomobject]@{ content = @($content | ForEach-Object { [pscustomobject]$_ }); stop_reason = [string]$done['stop_reason']; model = [string]$done['model']; usage = [pscustomobject]$done['usage']; allowance = $done['allowance']; streamedText = $text.ToString(); rawContent = $content }
}
# 把发给 Claude 的请求体改写成服务端的格式：system 合成一段文字；effort 来自 output_config；要求 JSON 结构的，改为在提示里要求（服务端没有结构化输出参数）
function ConvertTo-ServerAiBody($body, [string]$feature) {
  $sys = if ($body.system -is [string]) { $body.system } elseif ($body.system) { (@($body.system) | ForEach-Object { $_.text }) -join "`n" } else { $null }
  $msgs = @($body.messages)
  if ($body.output_config -and $body.output_config.format -and $body.output_config.format.schema) {
    $schema = $script:AcctJs.Serialize($body.output_config.format.schema); $last = $msgs[-1]
    $extra = "`n`n只输出一个 JSON 对象（不要代码块、不要解释），符合这个 JSON Schema：$schema"
    if ($last.content -is [string]) { $msgs[-1] = @{ role = $last.role; content = $last.content + $extra } } else { $msgs[-1] = @{ role = $last.role; content = @(@($last.content) + @{ type = 'text'; text = $extra }) } }
  }
  $o = [ordered]@{ messages = $msgs; feature = $feature; stream = $true }
  if ($sys) { $o.system = $sys }
  $m = (Get-ServerCfg).model; if ($m) { $o.model = $m }   # 用户选的模型；不在套餐里时服务端会说明，不悄悄换
  if ($body.max_tokens) { $o.max_tokens = [int]$body.max_tokens }
  if ($body.output_config -and $body.output_config.effort) { $o.effort = [string]$body.output_config.effort }
  if ($body.tools) { $o.tools = @($body.tools | ForEach-Object { @{ name = $_.name; description = $_.description; input_schema = $_.input_schema } }); $o.tool_choice = @{ type = 'auto' } }
  $o
}
function Start-AccountAI($body, [string]$feature = 'chat') {
  $req = New-ApiRequest 'POST' '/v1/ai/messages' $null -Auth
  $req.Content = New-Object System.Net.Http.StringContent ((ConvertTo-ServerAiBody $body $feature) | ConvertTo-Json -Depth 30 -Compress), ([Text.Encoding]::UTF8), 'application/json'   # 对话里有 PowerShell 对象，用 ConvertTo-Json
  $script:AcctHttp.SendAsync($req)
}
# 读结果：成功返回和 Claude 一样形状的对象；失败抛异常（Data 里有 code、retryable、retry_after、resets_at）
function Read-AccountAI($task) {
  $resp = $task.Result; $ct = [string]$resp.Content.Headers.ContentType
  if ([int]$resp.StatusCode -ge 400) { $r = Read-ApiResponse $resp; $e = $r.error; $x = [Exception]::new([string]$e['message']); foreach ($k in 'code', 'retryable', 'retry_after', 'resets_at', 'scope', 'models') { $x.Data[$k] = $e[$k] }; throw $x }
  $txt = if ($resp.Content) { $resp.Content.ReadAsStringAsync().Result } else { '' }   # 204 之类没有内容的响应
  if ($ct -match 'event-stream') { return (Merge-SseResult (ConvertFrom-Sse $txt)) }
  $j = $script:AcctJs.DeserializeObject($txt); [pscustomobject]@{ content = @($j['content'] | ForEach-Object { [pscustomobject]$_ }); stop_reason = [string]$j['stop_reason']; model = [string]$j['model']; usage = [pscustomobject]$j['usage']; allowance = $j['allowance'] }
}
# 结构化输出在账号模式下是靠提示要求的：从文字里取出第一个完整的 JSON 对象
function Get-JsonFromText([string]$t) { $i = $t.IndexOf('{'); $j = $t.LastIndexOf('}'); if ($i -lt 0 -or $j -le $i) { return $t }; $t.Substring($i, $j - $i + 1) }

# 经账号走 AI 出错时给用户看的一句话 + 要不要出「额度」卡片（不悄悄换模型、不自动重试）
function Format-AccountAIError($x) {
  $code = [string]$x.Data['code']; $msg = [string]$x.Message
  switch ($code) {
    'quota_exhausted' { $scope = [string]$x.Data['scope']; $when = Format-ResetTime ([string]$x.Data['resets_at'])
      $t = if ($scope -eq 'lifetime') { '试用额度用完了，开通套餐后可以继续用。' } elseif ($scope -eq 'monthly') { "这个月的额度用完了$(if ($when) { "，$when 恢复" })。" } else { "今天的额度用完了$(if ($when) { "，$when 恢复" })。" }
      return @{ text = $t; quota = @{ scope = $scope; resets = $when } } }
    'model_not_in_plan' { $ms = @($x.Data['models']) -join '、'; return @{ text = "$msg$(if ($ms) { "套餐里能用：$ms。可以在 设置 → 账号 里换。" })"; quota = @{ scope = 'model' } } }
    'rate_limited' { $ra = $x.Data['retry_after']; return @{ text = "请求太快了，$(if ($ra) { "$ra 秒后" } else { '稍等一下' })再试。" } }
    { $_ -in 'no_token', 'token_revoked' } { return @{ text = '还没登录账号，或者登录已失效。到 设置 → 账号 里登录一下。'; quota = @{ scope = 'login' } } }
    'unreachable' { return @{ text = '连不上服务器，等会儿再试。' } }
    default { return @{ text = $(if ($msg) { $msg } else { 'AI 暂时用不了。' }) } }
  }
}