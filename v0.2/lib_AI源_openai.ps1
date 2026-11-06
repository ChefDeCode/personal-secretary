# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_AI源_openai.ps1 — OpenAI（GPT）和「其他（兼容 OpenAI 接口）」：把秘书的 Claude 格式请求翻译成 Chat Completions，再把回答翻译回 Claude 格式
# 这样对话、工具调用（确认卡、认人、找文件）在所有服务商上走同一套代码。
# 工具：Claude 的 tool_use / tool_result ⇄ OpenAI 的 tool_calls / role=tool 消息；图片：base64 ⇄ data: 网址
# 结构化输出：OpenAI 用 response_format（json_schema）；兼容接口不一定支持，改为在提示里要求 JSON
function Get-CompatBase { $b = [string](Read-Config).ai.compatBase; if ($b) { $b.TrimEnd('/') } else { '' } }
function Get-ProviderUrl([string]$p) { if ($p -eq 'compat') { $b = Get-CompatBase; if (-not $b) { return $null }; return "$b/chat/completions" }; $script:Providers[$p].url }
function Set-CompatBase([string]$url) {
  $u = $null; if (-not [Uri]::TryCreate($url.Trim(), [UriKind]::Absolute, [ref]$u) -or $u.Scheme -ne 'https') { return @{ ok = $false; text = '地址必须是 https:// 开头的完整地址' } }
  $c = Get-AiCfg; $c | Add-Member compatBase ($u.AbsoluteUri.TrimEnd('/')) -Force; Save-AiCfg $c; @{ ok = $true; text = "已保存，接口在 $($u.Scheme)://$($u.Host)" }
}
function ConvertTo-OpenAIBody($body, [string]$p) {
  $msgs = New-Object System.Collections.Generic.List[object]
  $sys = if ($body.system -is [string]) { $body.system } elseif ($body.system) { (@($body.system) | ForEach-Object { $_.text }) -join "`n" } else { $null }
  if ($sys) { $msgs.Add(@{ role = 'system'; content = $sys }) }
  foreach ($m in @($body.messages)) {
    $role = [string]$m.role; $c = $m.content
    if ($c -is [string]) { $msgs.Add(@{ role = $role; content = $c }); continue }
    $texts = New-Object System.Collections.Generic.List[object]; $calls = New-Object System.Collections.Generic.List[object]
    foreach ($b in @($c)) {
      switch ([string]$b.type) {
        'text' { $texts.Add(@{ type = 'text'; text = [string]$b.text }) }
        'image' { $texts.Add(@{ type = 'image_url'; image_url = @{ url = "data:$($b.source.media_type);base64,$($b.source.data)" } }) }
        'tool_use' { $calls.Add(@{ id = [string]$b.id; type = 'function'; function = @{ name = [string]$b.name; arguments = $(if ($b.input) { $b.input | ConvertTo-Json -Depth 20 -Compress } else { '{}' }) } }) }
        'tool_result' { $rc = if ($b.content -is [string]) { $b.content } else { (@($b.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n" }; $msgs.Add(@{ role = 'tool'; tool_call_id = [string]$b.tool_use_id; content = [string]$rc }) }
      }
    }
    if ($role -eq 'assistant') { $o = @{ role = 'assistant'; content = $(if ($texts.Count) { ($texts | ForEach-Object { $_.text }) -join "`n" } else { $null }) }; if ($calls.Count) { $o.tool_calls = $calls.ToArray() }; $msgs.Add($o) }
    elseif ($texts.Count) { $msgs.Add(@{ role = $role; content = $(if (@($texts | Where-Object { $_.type -ne 'text' }).Count) { $texts.ToArray() } else { ($texts | ForEach-Object { $_.text }) -join "`n" }) }) }
  }
  $o = [ordered]@{ model = (Get-AiModel $p); messages = $msgs.ToArray() }
  if ($body.max_tokens) { if ($p -eq 'openai') { $o.max_completion_tokens = [int]$body.max_tokens } else { $o.max_tokens = [int]$body.max_tokens } }
  if ($body.tools) { $o.tools = @($body.tools | ForEach-Object { @{ type = 'function'; function = @{ name = $_.name; description = $_.description; parameters = $_.input_schema } } }) }
  if ($body.output_config -and $body.output_config.format -and $body.output_config.format.schema) {
    if ($p -eq 'openai') { $o.response_format = @{ type = 'json_schema'; json_schema = @{ name = 'out'; schema = $body.output_config.format.schema; strict = $false } } }
    else { $last = $o.messages[-1]; $last.content = [string]$last.content + "`n`n只输出一个 JSON 对象（不要代码块、不要解释），符合这个 JSON Schema：$($body.output_config.format.schema | ConvertTo-Json -Depth 20 -Compress)" }
  }
  if ($p -eq 'openai' -and $body.output_config -and $body.output_config.effort) { $o.reasoning_effort = [string]$body.output_config.effort }
  $o
}
# OpenAI 的回答 → 和 Claude 一样形状的对象（content 里是 text / tool_use 块）
function ConvertFrom-OpenAIResponse([string]$txt) {
  $j = $txt | ConvertFrom-Json; $ch = @($j.choices)[0]; $msg = $ch.message
  $content = New-Object System.Collections.Generic.List[object]
  if ($msg.content) { $content.Add([pscustomobject]@{ type = 'text'; text = [string]$msg.content }) }
  foreach ($tc in @($msg.tool_calls)) { if (-not $tc) { continue }; $in = try { $tc.function.arguments | ConvertFrom-Json } catch { [pscustomobject]@{} }; $content.Add([pscustomobject]@{ type = 'tool_use'; id = [string]$tc.id; name = [string]$tc.function.name; input = $in }) }
  $stop = switch ([string]$ch.finish_reason) { 'tool_calls' { 'tool_use' } 'length' { 'max_tokens' } 'content_filter' { 'refusal' } default { 'end_turn' } }
  [pscustomobject]@{ content = $content.ToArray(); stop_reason = $stop; model = [string]$j.model; usage = [pscustomobject]@{ input_tokens = [int]$j.usage.prompt_tokens; output_tokens = [int]$j.usage.completion_tokens; cache_read_input_tokens = 0 } }
}
function Start-OpenAIRequest($body, [string]$p, [string]$key) {
  $url = Get-ProviderUrl $p; if (-not $url) { throw [Exception]::new('还没有填接口地址：到 设置 → AI 与隐私 → 自带密钥 里填') }
  if ($body.tools -and $script:NoToolModels -and ($script:NoToolModels -contains "$p|$(Get-AiModel $p)")) { throw [Exception]::new('这个模型不支持工具，没法替你发消息、认人或找文件。请换一个模型') }
  $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), $url
  [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $key")
  $req.Content = New-Object System.Net.Http.StringContent (((ConvertTo-OpenAIBody $body $p) | ConvertTo-Json -Depth 30 -Compress), [Text.Encoding]::UTF8, 'application/json')
  $script:AiHttp.SendAsync($req)
}
# 读回答：失败时说清楚（模型不支持工具时明说，不去猜）
function Read-OpenAIResponse($task, [string]$p) {
  $resp = $task.Result; $txt = $resp.Content.ReadAsStringAsync().Result
  if (-not $resp.IsSuccessStatusCode) {
    $msg = try { [string]($txt | ConvertFrom-Json).error.message } catch { '' }
    if ($msg -match 'tool|function') { if (-not $script:NoToolModels) { $script:NoToolModels = @() }; $script:NoToolModels += "$p|$(Get-AiModel $p)"; throw [Exception]::new('这个模型不支持工具，没法替你发消息、认人或找文件。请换一个模型') }
    $why = switch ([int]$resp.StatusCode) { 401 { '密钥不对或已经作废' } 403 { '这把密钥没有权限' } 404 { '接口地址或模型名不对' } 429 { '请求太多或额度用完了' } default { "服务商返回 $([int]$resp.StatusCode)" } }
    throw [Exception]::new("AI 调用失败：$why")
  }
  ConvertFrom-OpenAIResponse $txt
}
# 有密钥时从 /v1/models 取这个服务商能用的模型（取不到就用内置的名单）
function Update-ProviderModels([string]$p) {
  $k = Get-ProviderKey $p; $base = if ($p -eq 'compat') { Get-CompatBase } else { 'https://api.openai.com/v1' }; if (-not $k -or -not $base) { return @() }
  $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get), "$base/models"; [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $($k.key)")
  try { $r = $script:AiHttp.SendAsync($req).Result; if (-not $r.IsSuccessStatusCode) { return @() }; $ids = @(($r.Content.ReadAsStringAsync().Result | ConvertFrom-Json).data | ForEach-Object { [string]$_.id } | Where-Object { $p -ne 'openai' -or $_ -match '^gpt-' } | Sort-Object) } catch { return @() }
  if ($ids.Count) { $script:Providers[$p].models = $ids; if (-not $script:Providers[$p].default -or $ids -notcontains $script:Providers[$p].default) { $script:Providers[$p].default = $ids[0] } }
  $ids
}
