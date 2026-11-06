# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_商店.ps1 — 插件商店：校验、安装、更新、下架、卸载，以及插件脚本的执行（只读步骤为主）
# 校验严格按 API.md §5.4，并在本机按 §5.2 的表把脚本再查一遍：服务端说「通过」不算数，客户端自己再查。
# 商店公钥写死在客户端里（测试模式用测试钥匙；正式钥匙以后由服务端负责人给出）；从不信任网上拿到的公钥。
# 插件永远不能扩大秘书的权限：「发送」一律走秘书自己的发送确认卡（核对会话名、回读、记日志）。
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem, System.Web.Extensions
if (-not ('Ed25519' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot '签名\Ed25519.dll') }
$script:StoreJs = New-Object Web.Script.Serialization.JavaScriptSerializer; $script:StoreJs.MaxJsonLength = [int]::MaxValue

# —— 写死的商店公钥：正式钥匙等服务端给；测试模式（config.server.store_test_key = true）只认测试钥匙 ——
$script:StorePins = @{
  test = @{ key_id = 'e86b54bfaacd1c24'; public_b64 = 'qRIYQS65BKrSACxoD1U+kjYKz41Xj7lPsvwFc0uynQ8=' }   # 只用于测试数据（server 0.2.0 测试数据的开发钥匙，不是正式服务器的钥匙）
  prod = @{ key_id = 'b8cfcbfd9b14e39d'; public_b64 = 'Pxh9nQ6gsy/UrKKVU4l3lGryYqMPAVfyby+fhp49clc=' }   # 正式商店钥匙（服务端 0.4.0，公钥，可以写在代码里）
}
if (-not ('Ghost2' -as [type])) { . (Join-Path $PSScriptRoot 'lib_原地读.ps1') }   # 读最小化 / 托盘里的窗口
function Get-StorePin { $s = (Read-Config).server; if ($s -and $s.store_test_key) { return $script:StorePins.test }; $script:StorePins.prod }

# —— §5.2 权限表（文字和风险来自 /v1/store/permissions，本机也存一份用来画权限卡片）——
$script:Regions = 'chat_list', 'message_area', 'sender', 'unread_marker', 'search_box', 'input_box'
$script:PermText = [ordered]@{ 'app.observe' = @('找到并识别这个应用的窗口', 'low'); 'ui.focus' = @('把这个应用的窗口切到前台', 'low'); 'ui.navigate' = @('在应用里按方向键、Esc 翻看列表', 'low')
  'input.search' = @('在搜索框里输入要找的名字', 'medium'); 'input.draft' = @('在输入框里写草稿（不发送）', 'medium'); 'input.send' = @('按下发送，把输入框里的内容发出去', 'high') }
foreach ($r in $script:Regions) { $script:PermText["region.read:$r"] = @("读取「$r」区域里显示的文字", 'medium') }
foreach ($r in 'chat_list', 'search_box', 'input_box') { $script:PermText["ui.click:$r"] = @("点击「$r」区域里的条目", 'medium') }
$script:NavKeys = 'Up', 'Down', 'PageUp', 'PageDown', 'Home', 'End', 'Escape'
$script:NameRx = '^[A-Za-z_][A-Za-z0-9_]{0,63}$'   # 动作名、as、emit 的字段名

# 一步需要什么权限；不合规时返回 @{ error = '原因' }
function Get-StepPermission($s) {
  $op = [string]$s['op']; $rg = [string]$s['region']
  switch ($op) {
    'find_window' { return @{ perm = 'app.observe' } }
    { $_ -in 'read_region', 'list_items', 'assert_visible' } {
      if ($rg -notin $script:Regions) { return @{ error = "unknown region $rg" } }
      if ($s.ContainsKey('as') -and [string]$s['as'] -notmatch $script:NameRx) { return @{ error = "bad name in as: $($s['as'])" } }
      return @{ perm = "region.read:$rg" } }
    'focus' { return @{ perm = 'ui.focus' } }
    'press_key' {
      $k = [string]$s['key']
      if ($k -eq 'Enter') { if ($rg -ne 'input_box') { return @{ error = 'Enter only allowed with region input_box (input.send)' } }; return @{ perm = 'input.send' } }
      if ($k -in $script:NavKeys) { if ($s.ContainsKey('region')) { return @{ error = 'nav keys must not carry a region' } }; return @{ perm = 'ui.navigate' } }   # 方向键不能带 region（API 0.2.0）
      return @{ error = "key $k not allowed" } }
    'click_item' { if ($rg -notin 'chat_list', 'search_box', 'input_box') { return @{ error = 'click_item only on chat_list/search_box/input_box' } }; return @{ perm = "ui.click:$rg" } }
    'type_text' { if ($rg -eq 'search_box') { return @{ perm = 'input.search' } }; if ($rg -eq 'input_box') { return @{ perm = 'input.draft' } }; return @{ error = 'type_text only into search_box/input_box' } }
    'wait' { $ms = $s['ms']; if (-not ($ms -is [int] -or $ms -is [long]) -or [long]$ms -lt 1 -or [long]$ms -gt 5000) { return @{ error = 'wait ms must be 1..5000' } }; return @{ perm = $null } }
    'emit' { if ([string]$s['field'] -notmatch $script:NameRx) { return @{ error = "bad emit field $($s['field'])" } }; return @{ perm = $null } }
    default { return @{ error = 'unknown op' } }
  }
}
# 整个脚本：权限只能来自表里；每步需要的都已声明；声明了的都用到了；总共不超过 200 步
function Test-PluginScript($permissions, $script) {
  $declared = @($permissions | ForEach-Object { [string]$_ })
  foreach ($p in $declared) { if (-not $script:PermText.Contains($p)) { return @{ ok = $false; code = 'unknown_permission'; reason = "permission $p is not in the table" } } }
  $acts = $script['actions']; if (-not ($acts -is [Collections.IDictionary]) -or -not $acts.Count) { return @{ ok = $false; code = 'bad_script'; reason = 'no actions' } }
  $need = New-Object 'System.Collections.Generic.HashSet[string]'; $steps = 0
  foreach ($name in @($acts.Keys)) {
    if ($name -notmatch $script:NameRx) { return @{ ok = $false; code = 'bad_script'; reason = "bad action name $name" } }
    foreach ($s in @($acts[$name])) {
      $steps++; if (-not ($s -is [Collections.IDictionary])) { return @{ ok = $false; code = 'bad_script'; reason = 'step is not an object' } }
      $r = Get-StepPermission $s; if ($r.error) { return @{ ok = $false; code = 'bad_step'; reason = $r.error } }
      if ($r.perm) { [void]$need.Add($r.perm) }
    }
  }
  if ($steps -gt 200) { return @{ ok = $false; code = 'too_many_steps'; reason = "script has $steps steps (max 200)" } }
  foreach ($p in $need) { if ($declared -notcontains $p) { return @{ ok = $false; code = 'script_exceeds_permissions'; reason = "step needs $p, not declared" } } }
  foreach ($p in $declared) { if (-not $need.Contains($p)) { return @{ ok = $false; code = 'unused_permission'; reason = "declared but unused permission ($p)" } } }
  @{ ok = $true; steps = $steps; required = @($need) }
}

# —— §5.4：下载的包 + 签名，逐项检查；任何一项不过都拒绝，并说明原因 ——
function Get-Sha256Hex([byte[]]$b) { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b)).Replace('-', '').ToLower() }
function Test-PluginPackage([byte[]]$zip, $sig, [string]$headerSha = '', $pin = (Get-StorePin)) {
  $fail = { param($code, $reason) @{ ok = $false; code = $code; reason = $reason } }
  if (-not $pin) { return (& $fail 'no_pinned_key' '客户端里还没有正式的商店公钥') }
  $st = $sig['statement']; if (-not $st) { return (& $fail 'bad_signature' 'no statement') }
  $sha = Get-Sha256Hex $zip
  if ($sha -ne [string]$st['sha256']) { return (& $fail 'sha_mismatch' 'zip SHA-256 != statement.sha256') }
  if ($headerSha -and $sha -ne $headerSha.ToLower()) { return (& $fail 'sha_mismatch' 'zip SHA-256 != X-Package-Sha256') }
  if ([string]$sig['alg'] -ne 'Ed25519' -or [string]$sig['context'] -ne 'secretary-plugin-v1') { return (& $fail 'bad_signature' 'unsupported alg/context') }
  if ([string]$st['key_id'] -ne $pin.key_id) { return (& $fail 'wrong_key' 'key_id is not the built-in store key') }
  $msg = [Text.Encoding]::UTF8.GetBytes("secretary-plugin-v1`n" + [CanonJson]::Of($st))
  $sb = $null; try { $sb = [Convert]::FromBase64String([string]$sig['signature']) } catch {}
  if (-not [Ed25519]::Verify([Convert]::FromBase64String($pin.public_b64), $msg, $sb)) { return (& $fail 'bad_signature' 'signature does not verify (not signed by the built-in store key, or statement changed)') }
  if ([string]$st['review_status'] -ne 'approved') { return (& $fail 'not_approved' "review_status is $($st['review_status'])") }
  if ($zip.Length -gt 256KB) { return (& $fail 'too_big' 'package larger than 256 KB') }
  if ([long]$st['size'] -ne $zip.Length) { return (& $fail 'size_mismatch' 'zip size != statement.size') }
  # 解包：必须正好是这三个文件
  $files = @{}
  try { $ms = New-Object IO.MemoryStream (, $zip); $za = New-Object IO.Compression.ZipArchive ($ms, [IO.Compression.ZipArchiveMode]::Read)
    foreach ($e in $za.Entries) { if ($e.FullName -match '[\\/]' -or $e.Length -gt 256KB) { $files['__bad'] = 1; continue }; $sr = New-Object IO.StreamReader ($e.Open(), [Text.Encoding]::UTF8); $files[$e.FullName] = $sr.ReadToEnd(); $sr.Dispose() }
    $za.Dispose() } catch { return (& $fail 'bad_zip' 'not a valid zip') }
  $names = @($files.Keys | Sort-Object)
  if ($names.Count -ne 3 -or ($names -join ',') -ne 'config.json,manifest.json,script.json') { return (& $fail 'extra_file' "zip must contain exactly manifest.json, config.json, script.json (has $($names.Count) files)") }
  try { $man = $script:StoreJs.DeserializeObject($files['manifest.json']); $cfg = $script:StoreJs.DeserializeObject($files['config.json']); $scr = $script:StoreJs.DeserializeObject($files['script.json']) } catch { return (& $fail 'bad_json' 'manifest/config/script is not valid JSON') }
  if ([string]$man['id'] -ne [string]$st['plugin_id'] -or [string]$man['version'] -ne [string]$st['version']) { return (& $fail 'id_mismatch' 'manifest id/version != statement') }
  if ([string]$man['app']['process'] -ne [string]$st['app_process']) { return (& $fail 'app_mismatch' 'manifest.app.process != statement.app_process') }
  $mp = @(@($man['permissions']) | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive); $sp = @(@($st['permissions']) | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
  if (($mp -join "`n") -ne ($sp -join "`n")) { return (& $fail 'perm_mismatch' 'manifest.permissions (sorted) != statement.permissions') }
  foreach ($k in @($cfg['regions'].Keys)) { if ($k -notin $script:Regions) { return (& $fail 'bad_region' "config region $k not allowed") }; $why = Test-RegionSpec $cfg['regions'] $k; if ($why) { return (& $fail 'bad_region' "config region ${k}: $why") } }
  $chk = Test-PluginScript $man['permissions'] $scr; if (-not $chk.ok) { return (& $fail $chk.code $chk.reason) }
  @{ ok = $true; statement = $st; manifest = $man; config = $cfg; script = $scr; sha256 = $sha }
}

# —— 区域（config.regions）：两种写法都接受，都是窗口的比例坐标（0–1，左上角为原点，跟 DPI 无关）——
#   推荐：{ "x":0.31, "y":0.08, "w":0.69, "h":0.66 }（可选 "anchor": "left|right" 只作说明）
#   兼容：{ "x0":0.31, "y0":0.08, "x1":1.0, "y1":0.74 }
#   子区域：{ "within": "chat_list", ... } 没有自己的框时用父区域的框（例如未读标记在会话列表里）
function Test-RegionSpec($regions, [string]$k) {
  $r = $regions[$k]; if (-not ($r -is [Collections.IDictionary])) { return 'not an object' }
  $num = { param($v) ($v -is [int] -or $v -is [long] -or $v -is [decimal] -or $v -is [double]) -and [double]$v -ge 0 -and [double]$v -le 1 }
  if ($r.ContainsKey('within')) { $p = [string]$r['within']; if ($p -eq $k -or -not $regions.ContainsKey($p)) { return "within must name another region in config" }; if ($regions[$p] -is [Collections.IDictionary] -and $regions[$p].ContainsKey('within')) { return 'within cannot be nested twice' } }
  $has4 = @('x', 'y', 'w', 'h' | Where-Object { $r.ContainsKey($_) }).Count; $hasXY = @('x0', 'y0', 'x1', 'y1' | Where-Object { $r.ContainsKey($_) }).Count
  if ($has4 -and $has4 -ne 4) { return 'x/y/w/h must all be given' }; if ($hasXY -and $hasXY -ne 4) { return 'x0/y0/x1/y1 must all be given' }
  if (-not $has4 -and -not $hasXY -and -not $r.ContainsKey('within')) { return 'needs a box (x,y,w,h) or within' }
  if ($has4) { foreach ($n in 'x', 'y', 'w', 'h') { if (-not (& $num $r[$n])) { return "$n must be a number 0..1" } }; if ([double]$r['w'] -le 0 -or [double]$r['h'] -le 0 -or [double]$r['x'] + [double]$r['w'] -gt 1.0001 -or [double]$r['y'] + [double]$r['h'] -gt 1.0001) { return 'box must be inside the window' } }
  if ($hasXY) { foreach ($n in 'x0', 'y0', 'x1', 'y1') { if (-not (& $num $r[$n])) { return "$n must be a number 0..1" } }; if ([double]$r['x1'] -le [double]$r['x0'] -or [double]$r['y1'] -le [double]$r['y0']) { return 'x1/y1 must be larger than x0/y0' } }
  ''
}
# 区域 → x0/y0/x1/y1 比例；子区域没有框时用父区域的框
function Get-RegionBox($regions, [string]$k) {
  $r = $regions[$k]; if (-not $r) { return $null }
  if ($r.ContainsKey('x')) { return @{ x0 = [double]$r['x']; y0 = [double]$r['y']; x1 = [double]$r['x'] + [double]$r['w']; y1 = [double]$r['y'] + [double]$r['h'] } }
  if ($r.ContainsKey('x0')) { return @{ x0 = [double]$r['x0']; y0 = [double]$r['y0']; x1 = [double]$r['x1']; y1 = [double]$r['y1'] } }
  if ($r.ContainsKey('within')) { return (Get-RegionBox $regions ([string]$r['within'])) }
  $null
}
# —— 安装 / 更新 / 卸载 ——
function Get-PluginDir([string]$id) { Join-Path (Join-Path $script:V2Data 'adapters') $id }
function Get-InstalledPlugins {
  $root = Join-Path $script:V2Data 'adapters'; if (-not (Test-Path $root)) { return @() }
  @(Get-ChildItem $root -Directory | ForEach-Object { $f = Join-Path $_.FullName 'installed.json'; if (Test-Path $f) { try { Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} } } | Where-Object { $_ })
}
# 下载并校验（还没装）：返回 @{ ok; reason; consent = 权限卡片数据; ... }
function Get-StorePackage([string]$id, [string]$ver) {
  $r1 = $script:AcctHttp.SendAsync((New-ApiRequest 'GET' "/v1/store/plugins/$([Uri]::EscapeDataString($id))/versions/$([Uri]::EscapeDataString($ver))/package" $null -Auth)).Result
  if ([int]$r1.StatusCode -ne 200) { $e = Read-ApiResponse $r1; return @{ ok = $false; code = $e.error['code']; reason = $e.error['message'] } }
  $zip = $r1.Content.ReadAsByteArrayAsync().Result; $hdr = ''; $v = $null; if ($r1.Headers.TryGetValues('X-Package-Sha256', [ref]$v)) { $hdr = @($v)[0] }
  $r2 = Invoke-Api 'GET' "/v1/store/plugins/$([Uri]::EscapeDataString($id))/versions/$([Uri]::EscapeDataString($ver))/signature" -Auth
  if ($r2.status -ne 200) { return @{ ok = $false; code = $r2.error['code']; reason = $r2.error['message'] } }
  $t = Test-PluginPackage $zip $r2.json $hdr; if ($t.ok) { $t.zip = $zip; $t.sig = $r2.json }; $t
}
# 权限卡片的数据：每项文字 + 风险；有「发送」的单独标出来
function Get-ConsentView($t, $old = $null) {
  $man = $t.manifest; $prev = if ($old) { @($old.permissions) } else { @() }
  [ordered]@{ id = [string]$man['id']; name = [string]$man['name']; version = [string]$man['version']; app = [string]$man['app']['display']; process = [string]$man['app']['process']
    perms = @(@($man['permissions']) | ForEach-Object { $p = [string]$_; [ordered]@{ id = $p; text = $script:PermText[$p][0]; risk = $script:PermText[$p][1]; added = ($old -and $prev -notcontains $p); send = ($p -eq 'input.send') } })
    can = @($man['can']); cannot = @($man['cannot']); replaces = [bool](Get-LocalAdapterFor ([string]$man['app']['process'])) }
}
# 这个应用有没有秘书自己适配出来的版面（装商店插件时会替换，留作备份，卸载时恢复）
function Get-LocalAdapterFor([string]$process) { $proc = [IO.Path]::GetFileNameWithoutExtension($process); $f = Join-Path (Join-Path $script:V2Data 'adapters') "$proc.json"; if (Test-Path $f) { $f } }
function Install-StorePlugin($t) {
  $man = $t.manifest; $id = [string]$man['id']; $dir = Get-PluginDir $id; New-Item -ItemType Directory -Force $dir | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $dir 'package.zip'), $t.zip)
  foreach ($n in 'manifest', 'config', 'script') { [IO.File]::WriteAllText((Join-Path $dir "$n.json"), $script:StoreJs.Serialize($t[$n]), (New-Object Text.UTF8Encoding $false)) }
  [IO.File]::WriteAllText((Join-Path $dir 'signature.json'), $script:StoreJs.Serialize($t.sig), (New-Object Text.UTF8Encoding $false))
  $local = Get-LocalAdapterFor ([string]$man['app']['process']); $backup = ''
  if ($local) { $backup = Join-Path $dir 'local_backup'; New-Item -ItemType Directory -Force $backup | Out-Null; foreach ($x in Get-ChildItem (Split-Path $local) -Filter "$([IO.Path]::GetFileNameWithoutExtension($local)).*" -File) { Move-Item $x.FullName $backup -Force } }   # 自己适配的版面挪去备份（读取改用商店插件）
  $info = [ordered]@{ id = $id; version = [string]$man['version']; source = 'store'; app_process = [string]$man['app']['process']; app = [string]$man['app']['display']; name = [string]$man['name']; permissions = @($man['permissions']); installed_at = (Get-Date).ToString('s'); enabled = $true; withdrawn = $false; backup = $backup; sha256 = $t.sha256 }
  [IO.File]::WriteAllText((Join-Path $dir 'installed.json'), ($info | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
  Send-StoreEvent $id $info.version 'install'; $info
}
function Uninstall-StorePlugin([string]$id) {
  $dir = Get-PluginDir $id; if (-not (Test-Path $dir)) { return $false }
  $info = Get-Content (Join-Path $dir 'installed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($info.backup -and (Test-Path $info.backup)) { foreach ($x in Get-ChildItem $info.backup -File) { Move-Item $x.FullName (Join-Path $script:V2Data 'adapters') -Force } }   # 恢复自己适配的版面
  Remove-Item $dir -Recurse -Force; Send-StoreEvent $id $info.version 'uninstall'; $true
}
function Set-PluginField([string]$id, [string]$k, $v) { $f = Join-Path (Get-PluginDir $id) 'installed.json'; $o = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json; $o | Add-Member $k $v -Force; [IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false)) }
function Send-StoreEvent([string]$id, [string]$ver, [string]$action) { if ((Get-ServerCfg).store_events) { try { [void](Invoke-Api 'POST' '/v1/store/events' @{ id = $id; version = $ver; action = $action } -Auth) } catch {} } }   # 默认关；只有次数，不含任何内容
function Send-PluginReport([string]$id, [string]$ver, [string]$detail) { Invoke-Api 'POST' "/v1/store/plugins/$([Uri]::EscapeDataString($id))/reports" @{ version = $ver; kind = 'broken'; detail = $detail.Substring(0, [Math]::Min(1000, $detail.Length)) } -Auth }   # detail 只放数字和步骤名，不放读到的内容

# —— 更新检查（启动时 + 每 6 小时）：新增权限由客户端自己算，不只看服务端的标记 ——
# 没有新权限 → 静默更新（所有检查照做）；有新权限 → 出卡片请用户重新同意，不自动更新；下架 → 立即停用并出卡片；unknown → 忽略
function Invoke-StoreUpdateCheck {
  $inst = @(Get-InstalledPlugins); if (-not $inst.Count) { return @() }
  $r = Invoke-Api 'POST' '/v1/store/updates' @{ installed = @($inst | ForEach-Object { @{ id = $_.id; version = $_.version } }) } -Auth
  if ($r.status -ne 200) { return @() }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($u in @($r.json['updates'])) {
    $id = [string]$u['id']; $me = $inst | Where-Object id -eq $id | Select-Object -First 1; if (-not $me) { continue }
    $st = [string]$u['status']
    if ($u['withdrawn']) { Set-PluginField $id 'enabled' $false; Set-PluginField $id 'withdrawn' $true; $out.Add(@{ id = $id; kind = 'withdrawn'; name = $me.name; latest = $(if ($st -eq 'update_available') { [string]$u['latest']['version'] }) }); continue }
    if ($st -ne 'update_available') { continue }   # up_to_date / unknown：不做事
    $lat = $u['latest']; $newPerms = @($lat['permissions'] | ForEach-Object { if ($_ -is [Collections.IDictionary]) { [string]$_['id'] } else { [string]$_ } })
    $added = @($newPerms | Where-Object { @($me.permissions) -notcontains $_ })
    if ($added.Count -or $u['requires_reconsent']) { $out.Add(@{ id = $id; kind = 'reconsent'; name = $me.name; version = [string]$lat['version']; added = $added }); continue }
    $t = Get-StorePackage $id ([string]$lat['version'])
    if ($t.ok) { $ad = @($t.manifest['permissions'] | Where-Object { @($me.permissions) -notcontains $_ }); if ($ad.Count) { $out.Add(@{ id = $id; kind = 'reconsent'; name = $me.name; version = [string]$lat['version']; added = $ad }); continue }   # 包里实际多了权限：也要重新同意
      [void](Install-StorePlugin $t); Send-StoreEvent $id ([string]$lat['version']) 'update'; $out.Add(@{ id = $id; kind = 'updated'; name = $me.name; version = [string]$lat['version'] }) }
    else { $out.Add(@{ id = $id; kind = 'update_failed'; name = $me.name; reason = $t.reason }) }
  }
  $out
}

# 同一个应用换了进程名（微信 4 是 Weixin.exe，以前是 WeChat.exe）：只认这张表里同一应用的名字，不会扩大插件能读的应用
$script:ProcAliases = @{ wechat = @('Weixin'); weixin = @('WeChat'); feishu = @('Lark'); lark = @('Feishu') }
# 应用的主窗口：先按「正常窗口」找，找不到（有的软件窗口样式特殊）再找这个进程最大的可见窗口
function Get-PluginWindow($procs) { $ids = [uint32[]]@($procs | ForEach-Object { $_.Id }); $h = [AppWin]::Largest($ids); if ($h -eq [IntPtr]::Zero) { $h = [WinTools]::LargestVisibleWindow($ids) }
  if ($h -eq [IntPtr]::Zero -or -not [Ghost2]::IsWindowVisible($h)) { $hm = [Ghost2]::HiddenMain($ids, 400, 300); if ($hm -ne [IntPtr]::Zero) { $h = $hm } }   # 关在托盘里：用隐藏着的主窗口（够大、不是工具窗口）
  $h }
function Get-PluginProcs([string]$process) { $n = [IO.Path]::GetFileNameWithoutExtension($process); $p = @(Get-Process $n -ErrorAction SilentlyContinue); if (-not $p.Count) { foreach ($al in @($script:ProcAliases[$n.ToLower()])) { if ($al) { $p = @(Get-Process $al -ErrorAction SilentlyContinue); if ($p.Count) { break } } } }; $p }
# —— 插件脚本执行：只读步骤映射到现有的读取代码；交互步骤只在用户自己发起的动作里执行；「发送」从不直接执行 ——
# 区域格式（config.regions）：{ "x0":0.31,"y0":0.08,"x1":1.0,"y1":0.86 } 都是窗口客户区的比例；可选 kind / my_side（见 报告.md）
function Invoke-PluginAction([string]$id, [string]$action, $params = @{}, [switch]$UserInitiated) {
  $dir = Get-PluginDir $id; $info = Get-Content (Join-Path $dir 'installed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $info.enabled) { return @{ ok = $false; reason = '这个插件已停用' } }
  $man = $script:StoreJs.DeserializeObject([IO.File]::ReadAllText((Join-Path $dir 'manifest.json'))); $cfg = $script:StoreJs.DeserializeObject([IO.File]::ReadAllText((Join-Path $dir 'config.json'))); $scr = $script:StoreJs.DeserializeObject([IO.File]::ReadAllText((Join-Path $dir 'script.json')))
  $chk = Test-PluginScript $man['permissions'] $scr; if (-not $chk.ok) { return @{ ok = $false; reason = "脚本没通过本机检查：$($chk.reason)" } }   # 每次执行前都再查
  $steps = $scr['actions'][$action]; if (-not $steps) { return @{ ok = $false; reason = "没有动作 $action" } }
  $vars = @{}; $emitted = [ordered]@{}; $h = [IntPtr]::Zero; $img = $null
  try {
    foreach ($s in @($steps)) {
      $op = [string]$s['op']; $perm = (Get-StepPermission $s).perm
      if ($op -in 'focus', 'click_item', 'type_text' -or ($op -eq 'press_key')) { if (-not $UserInitiated) { return @{ ok = $false; reason = "动作「$action」要操作应用，只能由你自己发起" } } }
      if ($perm -eq 'input.send') { return @{ ok = $false; needsConfirm = $true; reason = '发送一律走秘书自己的确认卡'; draft = $vars } }   # 插件不能自己发出去
      switch ($op) {
        'find_window' { $p = @(Get-PluginProcs ([string]$man['app']['process'])); if (-not $p.Count) { return @{ ok = $false; reason = '应用没开' } }; $h = Get-PluginWindow $p; if ($h -eq [IntPtr]::Zero) { return @{ ok = $false; reason = '没找到窗口' } }
          if ($img) { $img.Dispose() }
          if (-not $UserInitiated -and [Ghost2]::NeedsGhost($h)) { $gr = Invoke-GhostSnap $h; if (-not $gr.ok) { return @{ ok = $false; reason = $gr.why } }; $img = $gr.bmp }   # 最小化 / 关在托盘里：透明地放出来截一次图，马上放回去
          else { $r = [WinTools]::Rect($h); $img = [Rec]::Window($h, $r.R - $r.L, $r.B - $r.T) }
          $script:GDpi = [WinTools]::Dpi($h) / 96.0 }
        { $_ -in 'read_region', 'list_items', 'assert_visible' } {
          if (-not $img) { return @{ ok = $false; reason = '先要 find_window' } }
          $rg = Get-RegionBox $cfg['regions'] ([string]$s['region']); if (-not $rg) { return @{ ok = $false; reason = "config 里没有区域 $($s['region'])" } }
          $rect = To-Rect ([pscustomobject]@{ present = $true; x0 = $rg.x0; y0 = $rg.y0; x1 = $rg.x1; y1 = $rg.y1 }) $img.Width $img.Height; if (-not $rect) { return @{ ok = $false; reason = "区域 $($s['region']) 太小" } }
          $crop = Crop $img $rect
          try {
            if ($op -eq 'list_items') { $vars[[string]$s['as']] = @(Read-ListRows $crop @() 1.5 | ForEach-Object { $_.name }) }
            else { $txt = (@(Get-Lines (Invoke-Ocr $crop)) | Sort-Object y | ForEach-Object 文本) -join "`n"; if ($op -eq 'assert_visible' -and -not $txt) { return @{ ok = $false; reason = "区域 $($s['region']) 是空的" } }; if ($s['as']) { $vars[[string]$s['as']] = $txt } }
          } finally { $crop.Dispose() } }
        'wait' { Start-Sleep -Milliseconds ([int]$s['ms']) }
        'emit' { $emitted[[string]$s['field']] = $vars[[string]$s['field']] }
        { $_ -in 'focus', 'click_item', 'type_text', 'press_key' } { $r = Invoke-PluginUiStep $h $cfg $s $params; if (-not $r.ok) { return $r } }
      }
    }
  } finally { if ($img) { $img.Dispose() } }
  @{ ok = $true; data = $emitted }
}
# 交互步骤（只在用户发起时）：前台、点区域中心、打字、方向键；Enter 从不在这里执行（上面已拦下）
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class PlugUi {
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }
  [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int size);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  public static void Key(ushort vk) { var a = new INPUT[2]; a[0].type = 1; a[0].u.ki.wVk = vk; a[1].type = 1; a[1].u.ki.wVk = vk; a[1].u.ki.dwFlags = 2; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
  public static void Text(string s) { foreach (char c in s) { var a = new INPUT[2]; a[0].type = 1; a[0].u.ki.wScan = c; a[0].u.ki.dwFlags = 4; a[1].type = 1; a[1].u.ki.wScan = c; a[1].u.ki.dwFlags = 4 | 2; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); } }
  public static void Click(int x, int y) { SetCursorPos(x, y); var a = new INPUT[2]; a[0].type = 0; a[0].u.mi.dwFlags = 2; a[1].type = 0; a[1].u.mi.dwFlags = 4; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
}
'@
$script:VkOf = @{ Up = 0x26; Down = 0x28; PageUp = 0x21; PageDown = 0x22; Home = 0x24; End = 0x23; Escape = 0x1B }
function Invoke-PluginUiStep([IntPtr]$h, $cfg, $s, $params) {
  if ($h -eq [IntPtr]::Zero) { return @{ ok = $false; reason = '先要 find_window' } }
  switch ([string]$s['op']) {
    'focus' { [void][PlugUi]::SetForegroundWindow($h) }
    'click_item' { $rg = Get-RegionBox $cfg['regions'] ([string]$s['region']); $rg = @{ x0 = $rg.x0; y0 = $rg.y0; x1 = $rg.x1; y1 = $rg.y1 }; $r = [WinTools]::Rect($h); [PlugUi]::Click([int]($r.L + ($r.R - $r.L) * ([double]$rg['x0'] + [double]$rg['x1']) / 2), [int]($r.T + ($r.B - $r.T) * ([double]$rg['y0'] + [double]$rg['y1']) / 2)) }
    'type_text' { $t = [string]$s['text']; if ($t.StartsWith('$')) { $t = [string]$params[$t.Substring(1)] }; [PlugUi]::Text($t) }
    'press_key' { [PlugUi]::Key([uint16]$script:VkOf[[string]$s['key']]) }
  }
  @{ ok = $true }
}
# 自检：安装/更新后跑一次只读动作，看能不能读出东西（只记数字）
function Test-PluginSelf([string]$id) {
  $dir = Get-PluginDir $id; $scr = $script:StoreJs.DeserializeObject([IO.File]::ReadAllText((Join-Path $dir 'script.json')))
  $readOnly = @($scr['actions'].Keys | Where-Object { -not (@($scr['actions'][$_]) | Where-Object { [string]$_['op'] -in 'focus', 'click_item', 'type_text', 'press_key' }) })
  if (-not $readOnly.Count) { return @{ ok = $true; note = '没有只读动作，跳过自检' } }
  $a = $readOnly[0]; $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Invoke-PluginAction $id $a
  $counts = if ($r.ok) { ($r.data.Keys | ForEach-Object { "$_=$(@($r.data[$_]).Count)" }) -join ' ' } else { '' }
  @{ ok = [bool]($r.ok -and ($r.data.Values | Where-Object { @($_).Count })); action = $a; ms = $sw.ElapsedMilliseconds; reason = $r.reason; detail = "自检动作 $a：$(if ($r.ok) { "读到 $counts" } else { $r.reason })，用时 $($sw.ElapsedMilliseconds) 毫秒" }
}

# —— 设置 → 插件商城 页的数据 ——
# 没有内置的正式商店公钥时（测试模式除外）：显示「商城即将开放」，不拉列表、不信任 /v1/meta 给的公钥；已装的插件照样列出来、能卸载
function Get-StoreView {
  $inst = @(Get-InstalledPlugins | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; version = $_.version; app = $_.app; enabled = [bool]$_.enabled; withdrawn = [bool]$_.withdrawn; permissions = @($_.permissions) } })
  $v = [ordered]@{ installed = $inst; plugins = @() }
  if (-not (Get-StorePin)) { $v.comingSoon = $true; return $v }
  $mk = Get-MetaKeyCheck; if ($mk.offline) { $v.offline = $true; return $v }
  if ($mk.ok -eq $false) { $v.error = '服务器给的签名公钥和秘书内置的对不上，暂时不信任这个商城'; return $v }
  $r = Invoke-Api 'GET' '/v1/store/plugins' -Auth:(Test-SignedIn)
  if ($r.status -eq 401) { $v.needLogin = $true; return $v }
  if ($r.status -eq 0) { $v.offline = $true; return $v }
  if ($r.status -ne 200) { $v.error = [string]$r.error['message']; return $v }
  $v.plugins = @(@($r.json['plugins']) | ForEach-Object { $p = $_; $mine = $inst | Where-Object { $_.id -eq [string]$p['id'] } | Select-Object -First 1
    [ordered]@{ id = [string]$p['id']; name = [string]$p['name']; summary = [string]$p['summary']; publisher = [string]$p['publisher']; app = [string]$p['app']['display']; latest = [string]$p['latest_version']; risk = [string]$p['highest_risk']; installed = $(if ($mine) { $mine.version } else { '' }) } })
  $v
}
# 安装分两步：先下载 + 全部校验 + 出权限卡片（这里），用户点「安装」后才真正装
$script:PendingPkg = @{}
function Start-StoreInstall([string]$id, [string]$ver) {
  if (-not (Get-StorePin)) { return @{ ok = $false; reason = '商城即将开放' } }
  if ((Get-MetaKeyCheck).ok -eq $false) { return @{ ok = $false; reason = '服务器给的签名公钥和内置的对不上' } }
  $p = Get-StorePackage $id $ver; if (-not $p.ok) { return @{ ok = $false; reason = "没有通过校验，不能安装：$($p.reason)" } }
  $script:PendingPkg[$id] = $p
  $old = Get-InstalledPlugins | Where-Object { $_.id -eq $id } | Select-Object -First 1
  @{ ok = $true; consent = (Get-ConsentView $p $old) }
}
function Confirm-StoreInstall([string]$id) {
  $p = $script:PendingPkg[$id]; if (-not $p) { return @{ ok = $false; reason = '请重新点一次安装' } }
  $script:PendingPkg.Remove($id); $info = Install-StorePlugin $p
  $sc = Invoke-InstallSelfCheck $id; $out = @{ ok = $true; name = $info.name; version = $info.version; selfcheck = $sc.state; detail = $sc.detail }
  if ($sc.state -eq 'failed') { $fx = Repair-PluginRead $id 'selfcheck'; $out.readapt = $fx.proc; $out.app = $fx.app }
  $out
}

# —— /v1/meta 里的公钥必须和内置的一模一样（key_id 和公钥字节）；对不上就不信任服务器，安静地报一句，绝不自动换成网上的钥匙 ——
# 商店钥匙和更新包钥匙分开：商店的签名永远不能拿来验证更新包，反过来也一样
$script:ReleasePins = @{ prod = @{ key_id = 'adbeb7b56b0e8c53'; public_b64 = 'RunTUkE6Nw+TqontNOQZ4OZqbB6dBtVqoaO6x8oUnZk=' }; test = $null }
function Test-MetaKey($k, $pin) { if (-not $k -or -not $pin) { return $false }; try { [string]$k['key_id'] -eq $pin.key_id -and [string]$k['alg'] -eq 'Ed25519' -and ([Convert]::ToBase64String([Convert]::FromBase64String([string]$k['public_key'])) -eq $pin.public_b64) } catch { $false } }
$script:MetaKeyCheck = $null
function Get-MetaKeyCheck([switch]$Fresh) {
  if ($script:MetaKeyCheck -and -not $Fresh -and ((Get-Date) - $script:MetaKeyCheck.at).TotalMinutes -lt 30) { return $script:MetaKeyCheck }
  $r = Invoke-Api 'GET' '/v1/meta'; if ($r.status -ne 200) { return @{ ok = $null; offline = ($r.status -eq 0); at = Get-Date } }
  $test = [bool](Read-Config).server.store_test_key
  $okStore = Test-MetaKey $r.json['store_signing_key'] (Get-StorePin)
  $okRel = if ($test) { $true } else { Test-MetaKey $r.json['release_signing_key'] $script:ReleasePins.prod }
  $script:MetaKeyCheck = @{ ok = ($okStore -and $okRel); store = $okStore; release = $okRel; at = Get-Date }; $script:MetaKeyCheck
}
# 装好以后马上跑一次只读自检（应用没开 / 最小化就先跳过，值守读的时候会再看）
function Invoke-InstallSelfCheck([string]$id) {
  $info = Get-Content (Join-Path (Get-PluginDir $id) 'installed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $ps = @(Get-PluginProcs ([string]$info.app_process)); if (-not $ps.Count) { return @{ state = 'skipped'; detail = '应用没开，等它开着时再检查' } }
  if (-not ('Rec' -as [type])) { . (Join-Path $script:Root 'lib_识别.ps1') }; if (-not ('AppWin' -as [type])) { . (Join-Path $PSScriptRoot 'lib_虚拟桌面.ps1') }; if (-not (Get-Command Read-ListRows -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'lib_通用识别.ps1') }
  $h = Get-PluginWindow $ps; if ($h -eq [IntPtr]::Zero -or [WinTools]::IsIconic($h)) { return @{ state = 'skipped'; detail = '应用最小化着，等它在桌面上时再检查' } }
  $r = Test-PluginSelf $id; @{ state = $(if ($r.ok) { 'ok' } else { 'failed' }); detail = $r.detail }
}
# 插件读不出来（安装自检或值守连续读空）：停用它，恢复秘书自己适配过的版面；没有的话交给秘书重新适配这个应用
function Repair-PluginRead([string]$id, [string]$why) {
  $dir = Get-PluginDir $id; $info = Get-Content (Join-Path $dir 'installed.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Set-PluginField $id 'enabled' $false; Set-PluginField $id 'broken' $why; Remove-Item (Join-Path $dir 'broken.json') -ErrorAction SilentlyContinue
  $restored = $false; if ($info.backup -and (Test-Path $info.backup)) { foreach ($x in Get-ChildItem $info.backup -File) { Copy-Item $x.FullName (Join-Path $script:V2Data 'adapters') -Force; $restored = $true } }
  $proc = [IO.Path]::GetFileNameWithoutExtension([string]$info.app_process); $live = @(Get-PluginProcs ([string]$info.app_process)) | Select-Object -First 1; if ($live) { $proc = $live.ProcessName }
  @{ id = $id; app = [string]$info.app; proc = $(if ($restored) { '' } else { $proc }); restored = $restored }
}