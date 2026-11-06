# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_AI源.ps1 — 「自带密钥」：用户自己的 Claude（Anthropic）或 DeepSeek 密钥
# 密钥用 DPAPI（当前用户）加密存在 config.ai.keys 里，从不以明文写进任何文件、日志或报告；界面上只显示前 3 位和后 4 位。
# 以前放在 .env 里的 Claude 密钥仍然能用（只作 Claude 的后备），行为和以前一样。
# DeepSeek 用它官方的 Anthropic 兼容接口（https://api.deepseek.com/anthropic），所以对话、工具调用（确认卡、认人、找文件）沿用同一套代码；
#   不支持「结构化输出」参数 → 改为在提示里要求 JSON；看图只有 deepseek-flash 支持，选了不支持的模型就直说，不悄悄换。
Add-Type -AssemblyName System.Net.Http, System.Security
$script:KeyEntropy = [Text.Encoding]::UTF8.GetBytes('secretary-keys-v1')
$script:Providers = [ordered]@{
  anthropic = @{ name = 'Claude（Anthropic）'; url = 'https://api.anthropic.com/v1/messages'; models = @('claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-opus-5-5'); default = 'claude-sonnet-5-5'; schema = $true; vision = @('claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-opus-5-5') }
  deepseek  = @{ name = 'DeepSeek'; url = 'https://api.deepseek.com/anthropic/v1/messages'; models = @('deepseek-flash', 'deepseek-v4-pro'); default = 'deepseek-flash'; schema = $false; vision = @('deepseek-flash') }
  openai    = @{ name = 'OpenAI（GPT）'; url = 'https://api.openai.com/v1/chat/completions'; models = @('gpt-6.1-terra', 'gpt-6.1-sol', 'gpt-6-luna', 'gpt-6-astra'); default = 'gpt-6.1-terra'; schema = $true; vision = @('gpt-6.1-terra', 'gpt-6.1-sol', 'gpt-6-luna', 'gpt-6-astra'); openai = $true }   # 模型名来自 OpenAI 文档（2026-11）；有密钥时从 /v1/models 刷新
  compat    = @{ name = '其他（兼容 OpenAI 接口）'; url = ''; models = @(); default = ''; schema = $false; vision = @(); openai = $true }
}
function Get-AiCfg { $a = (Read-Config).ai; [pscustomobject]@{ provider = $(if ($a.provider -and $script:Providers.Contains([string]$a.provider)) { [string]$a.provider } else { 'anthropic' }); models = $(if ($a.models) { $a.models } else { [pscustomobject]@{} }); keys = $(if ($a.keys) { $a.keys } else { [pscustomobject]@{} }); compatBase = [string]$a.compatBase } }
function Save-AiCfg($c) { $cfg = Read-Config; $cfg | Add-Member ai $c -Force; Save-Config $cfg }
function Protect-Key([string]$k) { [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($k), $script:KeyEntropy, 'CurrentUser')) }
function Unprotect-Key([string]$b) { if (-not $b) { return $null }; try { [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($b), $script:KeyEntropy, 'CurrentUser')) } catch { $null } }
function Get-EnvClaudeKey { $f = Join-Path $script:Root '.env'; if (Test-Path $f) { foreach ($l in Get-Content $f -Encoding UTF8) { if ($l -match '^\s*ANTHROPIC_API_KEY\s*=\s*(.+?)\s*$') { return $Matches[1] } } }; $null }
# 某个服务商现在用哪把钥匙：用户在设置里存的优先；Claude 没存时用 .env 里的（和以前一样）
function Get-ProviderKey([string]$p) { $k = Unprotect-Key ([string](Get-AiCfg).keys.$p); if ($k) { return @{ key = $k; from = 'saved' } }; if ($p -eq 'anthropic') { $e = Get-EnvClaudeKey; if ($e) { return @{ key = $e; from = 'env' } } }; $null }
function Get-KeyMask([string]$k) { if (-not $k -or $k.Length -lt 10) { return '••••' }; $k.Substring(0, 3) + '••••' + $k.Substring($k.Length - 4) }
function Set-ProviderKey([string]$p, [string]$key) {
  if (-not $script:Providers.Contains($p)) { return @{ ok = $false; text = '不认识这个服务商' } }
  $key = $key.Trim(); if ($key.Length -lt 20 -or $key -match '\s') { return @{ ok = $false; text = '这看起来不像一把完整的密钥' } }
  $c = Get-AiCfg; $c.keys | Add-Member $p (Protect-Key $key) -Force; Save-AiCfg $c; @{ ok = $true; text = "已保存（$(Get-KeyMask $key)）" }
}
function Remove-ProviderKey([string]$p) { $c = Get-AiCfg; $c.keys.PSObject.Properties.Remove($p); Save-AiCfg $c }
function Set-AiProvider([string]$p) { if (-not $script:Providers.Contains($p)) { return $false }; $c = Get-AiCfg; $c.provider = $p; Save-AiCfg $c; $true }
function Set-AiModel([string]$p, [string]$m) { if (-not $script:Providers.Contains($p) -or $script:Providers[$p].models -notcontains $m) { return $false }; $c = Get-AiCfg; $c.models | Add-Member $p $m -Force; Save-AiCfg $c; $true }
function Get-AiModel([string]$p) { $m = [string](Get-AiCfg).models.$p; if ($m -and $script:Providers[$p].models -contains $m) { $m } else { $script:Providers[$p].default } }

# —— 把一个 Claude 格式的请求发给「自带密钥」当前选的服务商 ——
# $body 是秘书原来发给 Claude 的请求体；这里按服务商改：模型换成选的；DeepSeek 不支持结构化输出 → 改为提示里要求 JSON；去掉它不认的字段
function ConvertTo-ProviderBody($body, [string]$p) {
  $b = @{}; foreach ($k in $body.Keys) { $b[$k] = $body[$k] }
  if ($p -eq 'anthropic') { if (-not $b.model -or $b.model -notmatch '^claude-') { $b.model = Get-AiModel 'anthropic' }; return $b }
  $b.model = Get-AiModel $p; $b.Remove('fallbacks')
  $b.thinking = @{ type = 'disabled' }   # 关掉思考：更快、更省；工具调用照常
  if ($b.output_config -and $b.output_config.format -and $b.output_config.format.schema) {
    $schema = $b.output_config.format.schema | ConvertTo-Json -Depth 20 -Compress
    $msgs = @($b.messages); $last = $msgs[-1]; $extra = "`n`n只输出一个 JSON 对象（不要代码块、不要解释），符合这个 JSON Schema：$schema"
    if ($last.content -is [string]) { $msgs[-1] = @{ role = $last.role; content = $last.content + $extra } } else { $msgs[-1] = @{ role = $last.role; content = @(@($last.content) + @{ type = 'text'; text = $extra }) } }
    $b.messages = $msgs; $oc = @{}; if ($b.output_config.effort) { $oc.effort = $b.output_config.effort }; if ($oc.Count) { $b.output_config = $oc } else { $b.Remove('output_config') }
  }
  $b
}
# 发请求（返回 HttpResponseMessage 的任务；读结果用原来的 Read-Claude，格式相同）
$script:AiHttp = New-Object System.Net.Http.HttpClient; $script:AiHttp.Timeout = [TimeSpan]::FromSeconds(120)
function Start-ProviderAI($body) {
  $p = (Get-AiCfg).provider; $k = Get-ProviderKey $p
  if (-not $k) { throw [Exception]::new($(if ($p -eq 'anthropic') { '还没有 Claude 密钥：到 设置 → AI 与隐私 → 自带密钥 里填' } else { "还没有 $($script:Providers[$p].name) 密钥：到 设置 → AI 与隐私 → 自带密钥 里填" })) }
  if ($script:Providers[$p].openai) { return (Start-OpenAIRequest $body $p $k.key) }   # OpenAI 和兼容接口：翻译成 Chat Completions
  $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), $script:Providers[$p].url
  [void]$req.Headers.Add('x-api-key', $k.key); [void]$req.Headers.Add('anthropic-version', '2023-06-01')
  if ($p -eq 'anthropic' -and $body.fallbacks) { [void]$req.Headers.Add('anthropic-beta', 'server-side-fallback-2026-07-01') }
  $req.Content = New-Object System.Net.Http.StringContent (((ConvertTo-ProviderBody $body $p) | ConvertTo-Json -Depth 30 -Compress), [Text.Encoding]::UTF8, 'application/json')
  $script:AiHttp.SendAsync($req)
}
# 测试连接：发一句最短的话（max_tokens 很小）；返回 @{ ok; text; ms }，失败时说清楚原因（不回显密钥）
function Test-ProviderKey([string]$p) {
  $k = Get-ProviderKey $p; if (-not $k) { return @{ ok = $false; text = '还没有填密钥' } }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  if ($script:Providers[$p].openai) {
    try { $resp = (Start-OpenAIRequest @{ max_tokens = 16; messages = @(@{ role = 'user'; content = '回复 OK' }) } $p $k.key).Result } catch { return @{ ok = $false; text = $(if ($_.Exception.Message -match '接口地址') { $_.Exception.Message } else { '连不上服务商（网络问题）' }); ms = $sw.ElapsedMilliseconds } }
    $code = [int]$resp.StatusCode; if ($code -eq 200) { [void](Update-ProviderModels $p); return @{ ok = $true; text = "连接正常（$($sw.ElapsedMilliseconds) 毫秒，模型 $(Get-AiModel $p)）"; ms = $sw.ElapsedMilliseconds } }
    return @{ ok = $false; text = $(switch ($code) { 401 { '密钥不对或已经作废' } 403 { '这把密钥没有权限' } 404 { '接口地址或模型名不对' } 429 { '请求太多或额度用完了，稍后再试' } default { "服务商返回 $code" } }); code = $code; ms = $sw.ElapsedMilliseconds }
  }
  $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), $script:Providers[$p].url
  [void]$req.Headers.Add('x-api-key', $k.key); [void]$req.Headers.Add('anthropic-version', '2023-06-01')
  $b = @{ model = (Get-AiModel $p); max_tokens = 8; messages = @(@{ role = 'user'; content = '回复 OK' }) }; if ($p -ne 'anthropic') { $b.thinking = @{ type = 'disabled' } }
  $req.Content = New-Object System.Net.Http.StringContent (($b | ConvertTo-Json -Depth 5 -Compress), [Text.Encoding]::UTF8, 'application/json')
  try { $resp = $script:AiHttp.SendAsync($req).Result } catch { return @{ ok = $false; text = '连不上服务商（网络问题）'; ms = $sw.ElapsedMilliseconds } }
  $code = [int]$resp.StatusCode
  if ($code -eq 200) { return @{ ok = $true; text = "连接正常（$($sw.ElapsedMilliseconds) 毫秒，模型 $(Get-AiModel $p)）"; ms = $sw.ElapsedMilliseconds } }
  $why = switch ($code) { 401 { '密钥不对或已经作废' } 403 { '这把密钥没有权限' } 402 { '账户余额不足' } 429 { '请求太多或额度用完了，稍后再试' } default { "服务商返回 $code" } }
  @{ ok = $false; text = $why; code = $code; ms = $sw.ElapsedMilliseconds }
}
# 当前选的模型能不能看图（不能就直说，不悄悄换服务商）
function Test-ProviderVision { $p = (Get-AiCfg).provider; $m = Get-AiModel $p; @{ ok = ($script:Providers[$p].vision -contains $m); provider = $script:Providers[$p].name; model = $m } }
# 设置页：不含任何密钥，只有遮住的样子；也说清楚选这个服务商时内容会发给谁
function Get-AiPage {
  $c = Get-AiCfg; $mode = if (Get-Command Get-AIMode -ErrorAction SilentlyContinue) { Get-AIMode } else { 'local' }
  @{ mode = $mode; provider = $c.provider; compatBase = [string](Read-Config).ai.compatBase; privacy = "选 $($script:Providers[$c.provider].name) 时，秘书整理的内容会发给 $($script:Providers[$c.provider].name)$(if ($c.provider -eq 'compat' -and (Read-Config).ai.compatBase) { '（' + ([Uri][string](Read-Config).ai.compatBase).Host + '）' })"
     providers = @($script:Providers.Keys | ForEach-Object { $k = Get-ProviderKey $_; @{ id = $_; name = $script:Providers[$_].name; models = $script:Providers[$_].models; model = (Get-AiModel $_); hasKey = [bool]$k; keyFrom = $(if ($k) { $k.from } else { '' }); mask = $(if ($k) { Get-KeyMask $k.key } else { '' }); vision = @($script:Providers[$_].vision) } }) }
}

. (Join-Path $PSScriptRoot 'lib_AI源_openai.ps1')   # OpenAI（GPT）和兼容 OpenAI 接口的服务商
