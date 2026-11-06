# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 验证 docs\plugin-format.md 里的最小例子：用临时测试钥匙签名，跑客户端完整的 Test-PluginPackage（开发模式，不安装）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . "$v2\lib_账号.ps1"; . "$v2\lib_商店.ps1"
Add-Type -Path "$PSScriptRoot\TestSigner.cs" -ReferencedAssemblies System.Numerics
Add-Type -AssemblyName System.IO.Compression, System.Web.Extensions
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$js = New-Object Web.Script.Serialization.JavaScriptSerializer
$seed = New-Object byte[] 32; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($seed)
$pin = @{ key_id = 'testkey0000000001'; public_b64 = [Convert]::ToBase64String([TestSigner]::Public($seed)) }
$perms = @('app.observe', 'region.read:chat_list', 'region.read:message_area', 'ui.navigate')
$man = [ordered]@{ id = 'example-notes'; name = '示例笔记（只读）'; version = '1.0.0'; category = 'office'; summary = '读出示例笔记左侧的笔记列表和当前打开的笔记。'
  app = [ordered]@{ process = 'ExampleNotes.exe'; display = '示例笔记'; tested_versions = @('1.0') }; permissions = $perms
  can = @('看左侧的笔记列表', '读出当前打开的笔记', '用 PageDown 往下翻列表'); cannot = @('不会点开、不会打字、不会发送', '不会联网、不会读写文件') }
$cfg = @{ regions = [ordered]@{ chat_list = [ordered]@{ anchor = 'left'; x = 0.0; y = 0.08; w = 0.28; h = 0.92 }; message_area = [ordered]@{ anchor = 'right'; x = 0.28; y = 0.08; w = 0.72; h = 0.92 } } }
$scr = @{ actions = [ordered]@{
    list_notes = @(@{ op = 'find_window' }, @{ op = 'list_items'; region = 'chat_list'; as = 'notes' }, @{ op = 'emit'; field = 'notes' })
    read_current = @(@{ op = 'find_window' }, @{ op = 'read_region'; region = 'message_area'; as = 'text' }, @{ op = 'emit'; field = 'text' })
    next_page = @(@{ op = 'find_window' }, @{ op = 'press_key'; key = 'PageDown' }) } }
function New-Zip($files) { $ms = New-Object IO.MemoryStream; $za = New-Object IO.Compression.ZipArchive ($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
  foreach ($k in $files.Keys) { $e = $za.CreateEntry($k); $w = New-Object IO.StreamWriter ($e.Open(), (New-Object Text.UTF8Encoding $false)); $w.Write($files[$k]); $w.Dispose() }; $za.Dispose(); $ms.ToArray() }
function Sign-Package([byte[]]$zip, $over = @{}) {
  $st = @{ plugin_id = 'example-notes'; version = '1.0.0'; app_process = 'ExampleNotes.exe'; permissions = $perms; review_status = 'approved'; sha256 = (Get-Sha256Hex $zip); size = $zip.Length; key_id = $pin.key_id }
  foreach ($k in $over.Keys) { $st[$k] = $over[$k] }
  $st2 = $js.DeserializeObject($js.Serialize($st))   # 和从网上收到的一样：字典
  $msg = [Text.Encoding]::UTF8.GetBytes("secretary-plugin-v1`n" + [CanonJson]::Of($st2))
  @{ alg = 'Ed25519'; context = 'secretary-plugin-v1'; statement = $st2; signature = [Convert]::ToBase64String([TestSigner]::Sign($seed, $msg)) } }
$files = [ordered]@{ 'manifest.json' = ($man | ConvertTo-Json -Depth 6); 'config.json' = ($cfg | ConvertTo-Json -Depth 6); 'script.json' = ($scr | ConvertTo-Json -Depth 6) }
$zip = New-Zip $files; $sig = Sign-Package $zip
$r = Test-PluginPackage $zip $sig '' $pin
Assert ($r.ok) "minimal example passes the client's full package check (dev mode, test key) $(if (-not $r.ok) { "$($r.code): $($r.reason)" })"
Assert ((Get-RegionBox $r.config['regions'] 'message_area').x1 -eq 1.0) "x/y/w/h regions are understood (message_area right edge = 1.0)"
# 例子稍微改坏一点，确认会被拒
$bad = @(
  @{ n = 'nav key with region'; f = { $s2 = $js.DeserializeObject(($scr | ConvertTo-Json -Depth 6)); $s2['actions']['next_page'][1]['region'] = 'chat_list'; $files['script.json'] = $js.Serialize($s2) } },
  @{ n = 'region outside window'; f = { $c2 = $js.DeserializeObject(($cfg | ConvertTo-Json -Depth 6)); $c2['regions']['message_area']['w'] = 0.9; $files['config.json'] = $js.Serialize($c2) } },
  @{ n = 'unknown region name'; f = { $c2 = $js.DeserializeObject(($cfg | ConvertTo-Json -Depth 6)); $c2['regions']['toolbar'] = @{ x = 0; y = 0; w = 0.1; h = 0.1 }; $files['config.json'] = $js.Serialize($c2) } },
  @{ n = 'within points nowhere'; f = { $c2 = $js.DeserializeObject(($cfg | ConvertTo-Json -Depth 6)); $c2['regions']['sender'] = @{ within = 'nothing' }; $files['config.json'] = $js.Serialize($c2) } },
  @{ n = 'declared but unused permission'; f = { $m2 = $js.DeserializeObject(($man | ConvertTo-Json -Depth 6)); $m2['permissions'] = @($perms + 'ui.focus'); $files['manifest.json'] = $js.Serialize($m2); $script:extraPerm = $true } },
  @{ n = 'extra file in zip'; f = { $files['readme.txt'] = 'x' } }
)
foreach ($b in $bad) {
  $files = [ordered]@{ 'manifest.json' = ($man | ConvertTo-Json -Depth 6); 'config.json' = ($cfg | ConvertTo-Json -Depth 6); 'script.json' = ($scr | ConvertTo-Json -Depth 6) }; $script:extraPerm = $false
  & $b.f; $z2 = New-Zip $files; $s2 = Sign-Package $z2 $(if ($script:extraPerm) { @{ permissions = @($perms + 'ui.focus') } } else { @{} })
  $r2 = Test-PluginPackage $z2 $s2 '' $pin; Assert (-not $r2.ok) "rejected: $($b.n) ($($r2.code))"
}
"RESULT: $script:ok / $script:tot passed"
