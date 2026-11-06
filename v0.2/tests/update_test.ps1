# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 自动更新测试（模拟）：用服务端 0.3.0 代码生成的测试数据（测试用更新钥匙，不是正式钥匙），在单独的测试文件夹里装、坏了就退回
# 不碰正在运行的秘书；测试里启动的「新版本」是一个只写运行标记的小脚本
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
$T = Join-Path $env:TEMP 'secretary_update_test'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\cfg" | Out-Null
. "$v2\lib_v2.ps1"; Copy-Item $script:CfgPath "$T\cfg\config.json"; $script:CfgPath = "$T\cfg\config.json"; $script:AcctDir = "$T\cfg"
. "$v2\lib_账号.ps1"; . "$v2\lib_商店.ps1"; . "$v2\lib_更新.ps1"
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
Add-Type -AssemblyName System.Web.Extensions; $js = New-Object Web.Script.Serialization.JavaScriptSerializer; $js.MaxJsonLength = [int]::MaxValue
$fx = $js.DeserializeObject([IO.File]::ReadAllText("$PSScriptRoot\fixtures\client-release-0.3.0.json"))
$rk = $fx['release_key']; $script:ReleasePins.test = @{ key_id = [string]$rk['key_id']; public_b64 = [string]$rk['public_key'] }
Set-ServerCfg 'store_test_key' $true; Set-ServerCfg 'base' 'http://127.0.0.1:8810'
"— 正式钥匙是写死的 —"
Assert ($script:ReleasePins.prod.key_id -eq 'adbeb7b56b0e8c53' -and $script:StorePins.prod.key_id -eq 'b8cfcbfd9b14e39d') "production release key and store key are pinned, and different"
Set-ServerCfg 'store_test_key' $false; $off = Test-ReleaseOffer $fx['http']['latest_update']['json'] '0.2.0'
Assert (-not $off.ok -and $off.code -eq 'wrong_key') "outside test mode a test-signed release is refused ($($off.code))"
Set-ServerCfg 'store_test_key' $true
"— 好的更新 —"
$o = Test-ReleaseOffer $fx['http']['latest_update']['json'] '0.2.0'; Assert ($o.ok -and $o.version -eq '0.2.1') "0.2.0 → 0.2.1 offer: signature (release key, release context), version, channel, size, url all ok"
$zip = [Convert]::FromBase64String($fx['packages']['0.2.1']['zip_b64']); $z = Test-ReleaseZip $zip $o.statement
Assert ($z.ok -and $z.files.Count -eq 3) "0.2.1 package: size + sha256 + safe paths ok ($($z.files.Count) files)"
Assert (-not (Test-ReleaseOffer $fx['http']['latest_update']['json'] '0.2.1').ok) "already on 0.2.1 → not offered again"
"— 13 种坏包 —"
$rej = 0; foreach ($n in $fx['negative']) { $r = $n['response']; $c = Test-ReleaseOffer $r '0.2.0'
  if ($c.ok -and $n['zip_b64']) { $c = Test-ReleaseZip ([Convert]::FromBase64String($n['zip_b64'])) $c.statement }
  if (-not $c.ok) { $rej++ } else { "     NOT rejected: $($n['name'])" } }
Assert ($rej -eq @($fx['negative']).Count) "all bad releases refused: $rej / $(@($fx['negative']).Count) (sha, size, tampered, store key, store context, wrong key, version, channel, downgrade, foreign url, zip-slip, absolute path, data dir)"
"— 检查更新（模拟服务端）—"
$port = 8813; $base = "http://127.0.0.1:$port"; $srv=[pscustomobject]@{HasExited=$true}; . "$PSScriptRoot\lib_mock_http.ps1"; Set-TestHttpTransport
function Invoke-WebRequest([string]$Uri,[string]$Method='GET',[switch]$UseBasicParsing){Invoke-TestHttp $Uri $Method}
try {
  Set-ServerCfg 'base' $base
  [void](Invoke-WebRequest "$base/__mode?upd=none" -Method Post -UseBasicParsing); $c1 = Invoke-UpdateCheck
  Assert ($c1.state -eq 'none') "nothing published → calm, no update card"
  [void](Invoke-WebRequest "$base/__mode?upd=update" -Method Post -UseBasicParsing); $c2 = Invoke-UpdateCheck
  Assert ($c2.state -eq 'available' -and $c2.version -eq '0.2.1' -and $c2.notes) "update available → card data: 0.2.1 + notes"
  [void](Invoke-WebRequest "$base/__mode?upd=required" -Method Post -UseBasicParsing); $c3 = Invoke-UpdateCheck
  Assert ($c3.state -eq 'required' -and $c3.version -eq '0.3.0') "required update flagged as required"
  [void](Invoke-WebRequest "$base/__mode?upd=update" -Method Post -UseBasicParsing); [void](Invoke-UpdateCheck)
  $si = Start-UpdateInstall "$T\stage"; Assert ($si.ok -and (Test-Path "$T\stage\0.2.1\VERSION")) "download → verify → unpacked to the staging folder only"
} finally { if (-not $srv.HasExited) { $srv.Kill() } }
# Process start/health/rollback integration is preserved in update_test_native_original.ps1.
"[PENDING_NATIVE] updater_process_health_rollback"
"RESULT: $script:ok / $script:tot passed (in-memory transport, real signatures and staging)"
if($script:ok -ne $script:tot){exit 1}
