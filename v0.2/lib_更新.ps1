# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_更新.ps1 — 秘书自己的更新（服务端 API §7）：检查 → 下载 → 校验 → 备份 → 安装 → 健康检查 → 不行就退回
# 校验全部在本机做，任何一项不过都拒绝，并说明原因：
#   签名：Ed25519，上下文 secretary-client-release-v1，key_id 和公钥都必须是内置的「更新钥匙」（不是商店钥匙，也不信任网上给的钥匙）
#   声明：响应里的版本 = 声明里的版本；频道 = 我们要的频道；比当前版本新；大小、SHA-256 和下载到的包一致；下载地址和服务器地址同源
#   包内容：只能是相对路径；不能有 ..、盘符、开头的 / 或 \；不能碰 data\（用户数据）
# 安装由单独的更新器（更新器.ps1）在秘书退出后做：先备份当前文件，再覆盖，启动新版本，60 秒内没起来就从备份恢复并启动旧版本
if (-not $script:UpdRoot) { $script:UpdRoot = $PSScriptRoot }   # 秘书程序所在的文件夹（v0.2）
$script:UpdContext = 'secretary-client-release-v1'
function Get-ClientVersion { $f = Join-Path $script:UpdRoot 'VERSION'; if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { '0.2.0' } }
function Get-ReleasePin { if ((Read-Config).server.store_test_key -and $script:ReleasePins.test) { return $script:ReleasePins.test }; $script:ReleasePins.prod }
function Compare-Version([string]$a, [string]$b) { $x = [version]($a -replace '[^\d.]', ''); $y = [version]($b -replace '[^\d.]', ''); $x.CompareTo($y) }
# 服务器的回答（还没下载）：返回 @{ ok; code; reason }
function Test-ReleaseOffer($r, [string]$installed, [string]$channel = 'stable', $pin = (Get-ReleasePin)) {
  $fail = { param($c, $why) @{ ok = $false; code = $c; reason = $why } }
  if (-not $pin) { return (& $fail 'no_pinned_key' '客户端里没有更新钥匙') }
  $st = $r['statement']; if (-not $st) { return (& $fail 'bad_signature' 'no statement') }
  if ([string]$r['alg'] -ne 'Ed25519' -or [string]$r['context'] -ne $script:UpdContext) { return (& $fail 'bad_signature' 'unsupported alg/context') }
  if ([string]$st['key_id'] -ne $pin.key_id) { return (& $fail 'wrong_key' 'key_id is not the built-in release key') }
  $sig = $null; try { $sig = [Convert]::FromBase64String([string]$r['signature']) } catch {}
  $msg = [Text.Encoding]::UTF8.GetBytes("$($script:UpdContext)`n" + [CanonJson]::Of($st))
  if (-not $sig -or -not [Ed25519]::Verify([Convert]::FromBase64String($pin.public_b64), $msg, $sig)) { return (& $fail 'bad_signature' 'signature does not verify with the built-in release key') }
  if ([string]$r['version'] -ne [string]$st['version']) { return (& $fail 'version_mismatch' 'response.version != statement.version') }
  if ([string]$st['channel'] -ne $channel) { return (& $fail 'channel_mismatch' "statement.channel != $channel") }
  try { if ((Compare-Version ([string]$st['version']) $installed) -le 0) { return (& $fail 'not_newer' "not newer than installed $installed") } } catch { return (& $fail 'bad_version' 'version is not a number') }
  if ([long]$r['size'] -ne [long]$st['size'] -or [string]$r['sha256'] -ne [string]$st['sha256']) { return (& $fail 'size_mismatch' 'response size/sha != statement') }
  if ((Get-Origin ([string]$r['url'])) -ne (Get-Origin (Get-ServerCfg).base)) { return (& $fail 'foreign_url' 'download url is not on the server') }
  @{ ok = $true; version = [string]$st['version']; statement = $st }
}
# 下载到的包：大小、SHA-256、每个文件的路径都安全
function Test-ReleaseZip([byte[]]$zip, $st) {
  $fail = { param($c, $why) @{ ok = $false; code = $c; reason = $why } }
  if ($zip.Length -ne [long]$st['size']) { return (& $fail 'size_mismatch' 'downloaded size != statement.size') }
  if ((Get-Sha256Hex $zip) -ne [string]$st['sha256']) { return (& $fail 'sha_mismatch' 'downloaded zip SHA-256 != statement.sha256') }
  $names = @(); try { $ms = New-Object IO.MemoryStream (, $zip); $za = New-Object IO.Compression.ZipArchive ($ms, [IO.Compression.ZipArchiveMode]::Read); $names = @($za.Entries | ForEach-Object { $_.FullName }); $za.Dispose() } catch { return (& $fail 'bad_zip' 'not a valid zip') }
  foreach ($n in $names) {
    $p = $n -replace '\\', '/'
    if ($p -match '^[A-Za-z]:' -or $p.StartsWith('/') -or $p -match '(^|/)\.\.(/|$)' -or $p -match '[\x00-\x1f]') { return (& $fail 'unsafe_path' "unsafe path in zip") }
    if ($p -match '^(data|v0\.2/data)(/|$)') { return (& $fail 'unsafe_path' 'package tries to write user data') }
  }
  if (-not $names.Count) { return (& $fail 'bad_zip' 'empty package') }
  @{ ok = $true; files = $names }
}
# 检查：返回界面用的 @{ state = none|available|required|error|offline; version; notes; size; ... }
$script:UpdOffer = $null
function Invoke-UpdateCheck([string]$channel = 'stable') {
  $cur = Get-ClientVersion
  $r = Invoke-Api 'GET' "/v1/client/latest?version=$([Uri]::EscapeDataString($cur))&channel=$channel"
  if ($r.status -eq 0) { return @{ state = 'offline'; current = $cur } }
  if ($r.status -ne 200) { return @{ state = 'none'; current = $cur } }   # 别的错误：安静处理，下次再查
  $j = $r.json; if (-not $j['update_available']) { return @{ state = 'none'; current = $cur; latest = [string]$j['latest_version'] } }
  $t = Test-ReleaseOffer $j $cur $channel; if (-not $t.ok) { return @{ state = 'error'; current = $cur; code = $t.code; reason = $t.reason } }
  $script:UpdOffer = $j
  @{ state = $(if ($j['required']) { 'required' } else { 'available' }); current = $cur; version = $t.version; notes = [string]$j['notes']; size = [long]$j['size'] }
}
# 下载 + 校验 + 解到暂存文件夹；然后启动更新器（秘书随后退出）
function Start-UpdateInstall([string]$stageRoot = (Join-Path (Split-Path $script:UpdRoot -Parent) 'update_stage')) {
  $j = $script:UpdOffer; if (-not $j) { return @{ ok = $false; reason = '请先检查更新' } }
  $t = Test-ReleaseOffer $j (Get-ClientVersion); if (-not $t.ok) { return @{ ok = $false; reason = $t.reason } }
  $u = [Uri][string]$j['url']; $req = New-ApiRequest 'GET' $u.PathAndQuery $null -Auth
  $resp = $script:AcctHttp.SendAsync($req).Result; if ([int]$resp.StatusCode -ne 200) { return @{ ok = $false; reason = "下载失败（$([int]$resp.StatusCode)）" } }
  $zip = $resp.Content.ReadAsByteArrayAsync().Result
  $z = Test-ReleaseZip $zip $t.statement; if (-not $z.ok) { return @{ ok = $false; code = $z.code; reason = "更新包没有通过检查：$($z.reason)" } }
  Expand-ReleaseZip $zip (Join-Path $stageRoot $t.version)
}
function Expand-ReleaseZip([byte[]]$zip, [string]$dest) {
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }; New-Item -ItemType Directory -Force $dest | Out-Null
  $ms = New-Object IO.MemoryStream (, $zip); $za = New-Object IO.Compression.ZipArchive ($ms, [IO.Compression.ZipArchiveMode]::Read)
  $full = [IO.Path]::GetFullPath($dest).TrimEnd('\') + '\'
  try { foreach ($e in $za.Entries) { if (-not $e.Name) { continue }; $out = [IO.Path]::GetFullPath((Join-Path $dest ($e.FullName -replace '/', '\')))
      if (-not $out.StartsWith($full, [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe path' }   # 再查一次，绝不写到暂存文件夹外面
      New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null; [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true) } }
  finally { $za.Dispose() }
  @{ ok = $true; stage = $dest }
}
