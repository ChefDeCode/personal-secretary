# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 自带密钥 / 多服务商测试：OpenAI 翻译层用模拟接口测（标明是模拟）；DeepSeek 只在给了真密钥时做最小的真实调用；不显示任何密钥
param([string]$DeepSeekKeyFile = '')
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . "$v2\lib_账号.ps1"
$T = Join-Path $env:TEMP 'secretary_ai_test'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null
Copy-Item $script:CfgPath "$T\config.json"; $realCfg = $script:CfgPath; $script:CfgPath = "$T\config.json"   # 用测试副本，不改用户的设置
. "$v2\lib_AI源.ps1"
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
"— 密钥的保存 —"
$fake = 'sk-test-mock-key-0123456789'
$r = Set-ProviderKey 'compat' $fake; $raw = [IO.File]::ReadAllText($script:CfgPath)
Assert ($r.ok -and $raw -notmatch 'mock-key' -and (Get-ProviderKey 'compat').key -eq $fake) "key saved encrypted (DPAPI); not readable in the settings file"
Assert ((Get-AiPage | ConvertTo-Json -Depth 6) -notmatch 'mock-key' -and ((Get-AiPage).providers | Where-Object id -eq 'compat').mask -eq 'sk-••••6789') "settings page shows only the first 3 and last 4 characters"
Assert (-not (Set-CompatBase 'http://example.com/v1').ok) "compatible endpoint must be https"
Assert ((Set-ProviderKey 'deepseek' 'short').ok -eq $false) "obviously incomplete key refused"
"— OpenAI 翻译层（模拟）—"
$body = @{ max_tokens = 100; system = @(@{ type = 'text'; text = '系统提示' }); tools = @(@{ name = 'propose_send'; description = 'd'; input_schema = @{ type = 'object'; properties = @{ as_said = @{ type = 'string' } } } })
  messages = @(@{ role = 'user'; content = '你好' }, @{ role = 'assistant'; content = @(@{ type = 'text'; text = '我看看' }, @{ type = 'tool_use'; id = 'tu1'; name = 'get_today'; input = @{} }) },
    @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'tu1'; content = '没有事项' }, @{ type = 'image'; source = @{ type = 'base64'; media_type = 'image/png'; data = 'AAAA' } }, @{ type = 'text'; text = '这是什么' }) }) }
$o = ConvertTo-OpenAIBody $body 'openai'
$roles = @($o.messages | ForEach-Object { $_.role }) -join ','
Assert ($roles -eq 'system,user,assistant,tool,user' -and $o.messages[2].tool_calls[0].function.name -eq 'get_today' -and $o.messages[3].tool_call_id -eq 'tu1') "Claude tool_use / tool_result → OpenAI tool_calls / role=tool, in order ($roles)"
Assert ($o.tools[0].type -eq 'function' -and $o.tools[0].function.parameters.properties.as_said -and $o.max_completion_tokens -eq 100) "tools → functions with the same schema; max_completion_tokens for OpenAI"
Assert (@($o.messages[4].content | Where-Object { $_.type -eq 'image_url' -and $_.image_url.url -like 'data:image/png;base64,*' }).Count -eq 1) "images → data URL"
$sb = @{ max_tokens = 50; output_config = @{ format = @{ type = 'json_schema'; schema = @{ type = 'object' } } }; messages = @(@{ role = 'user'; content = 'x' }) }
Assert ((ConvertTo-OpenAIBody $sb 'openai').response_format.type -eq 'json_schema' -and (ConvertTo-OpenAIBody $sb 'compat').messages[-1].content -match 'JSON Schema') "structured output: response_format for OpenAI, asked in the prompt for other compatible services"
$resp = '{"model":"m","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"propose_send","arguments":"{\"as_said\":\"明远\",\"text\":\"hi\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}'
$j = ConvertFrom-OpenAIResponse $resp
Assert ($j.stop_reason -eq 'tool_use' -and $j.content[0].type -eq 'tool_use' -and $j.content[0].input.as_said -eq '明远' -and $j.usage.input_tokens -eq 3) "OpenAI tool_calls → Claude-shaped tool_use with parsed arguments"
"— 完整对话（模拟的兼容接口：先要求 propose_send，再回一句）—"
$srv = Start-Process node -ArgumentList "`"$PSScriptRoot\mock_openai.js`"", 8821 -PassThru -WindowStyle Hidden; Start-Sleep 1
try {
  $c = Get-AiCfg; $c | Add-Member compatBase 'http://127.0.0.1:8821/v1' -Force; $c.provider = 'compat'; $c.models | Add-Member compat 'mock-model-a' -Force; Save-AiCfg $c   # 只在测试副本里：本机模拟接口允许 http
  $script:Providers['compat'].models = @('mock-model-a'); $script:Providers['compat'].vision = @()
  $tk = Test-ProviderKey 'compat'; Assert ($tk.ok -and (@($script:Providers['compat'].models) -contains 'mock-model-b')) "测试连接 ok; model list refreshed from /models (simulated)"
  $script:ChatFile = "$T\chat.jsonl"; $script:ChatArchive = "$T\chat_archive.jsonl"; $script:SummaryFile = "$T\summary.txt"; $script:ActDir = "$T\actions"; $script:PeopleFile = "$T\people.jsonl"; New-Item -ItemType Directory -Force $script:ActDir | Out-Null
  $ast = [Management.Automation.Language.Parser]::ParseFile("$v2\秘书.ps1", [ref]$null, [ref]$null)
  foreach ($fn in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Get-HistoryMessages', 'Start-Turn', 'Send-TurnRequest', 'Poll-Turn', 'Finish-Turn', 'Start-Claude', 'Read-Claude', 'Get-ApiKey', 'On-PersonChoice' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
  foreach ($as in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -in '$stepNames', '$http' }, $false)) { . ([scriptblock]::Create($as.Extent.Text)) }
  $usageFile = "$T\usage.json"; $script:Usage = [pscustomobject]@{ calls = 0; input = 0; output = 0; cacheRead = 0; usd = 0.0 }; $script:Posted = New-Object System.Collections.ArrayList
  function Post($o) { [void]$script:Posted.Add($o) }; function Show-Notice($t) {}; function Write-MemUsed {}; function Write-ErrorLog {}; function Start-Compaction {}; function Post-MiniRaw {}
  function Get-PeopleSources { @{ chats = @(@{ app = '微信'; title = '文件传输助手'; last = '' }); senders = @() } }
  $realGetSwitch = ${function:Get-Switch}; function Get-Switch([string]$k) { if ($k -eq 'send_messages') { return $true }; & $realGetSwitch $k }
  function Get-AIMode { 'local' }
  function Wait-Turn { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($script:Turn -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 200; try { Poll-Turn } catch { if ($script:Turn) { Finish-Turn $null '这一步出错了' } } } }
  $script:Posted.Clear(); [void](Add-ChatItem @{ role = 'me'; text = '给文件传输助手发个测试' }); Start-Turn '给文件传输助手发个测试'; Wait-Turn
  $sc = @($script:Posted | Where-Object { $_.type -eq 'item' -and $_.item.card.kind -eq 'send' } | ForEach-Object { $_.item.card })
  Assert ($sc.Count -eq 1 -and $sc[0].who -eq '文件传输助手' -and $sc[0].status -eq 'open') "tool loop through an OpenAI-style API ends at the same OPEN confirm card (simulated, nothing sent)"
  $c = Get-AiCfg; $c.keys | Add-Member compat (Protect-Key 'sk-wrong-key-000000000000') -Force; Save-AiCfg $c
  $tk2 = Test-ProviderKey 'compat'; Assert (-not $tk2.ok -and $tk2.text -match '密钥不对') "wrong key → clear message 「$($tk2.text)」 (simulated)"
} finally { if (-not $srv.HasExited) { $srv.Kill() } }
if ($DeepSeekKeyFile -and (Test-Path $DeepSeekKeyFile)) {
  "— DeepSeek（真实，用量很小）—"
  $k = (Get-Content $DeepSeekKeyFile -Raw).Trim(); [void](Set-ProviderKey 'deepseek' $k); Remove-Variable k
  $c = Get-AiCfg; $c.provider = 'deepseek'; Save-AiCfg $c
  $tk = Test-ProviderKey 'deepseek'; Assert $tk.ok "DeepSeek 测试连接: $($tk.text)"
}
$script:CfgPath = $realCfg; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $script:ok / $script:tot passed (OpenAI parts simulated)"
