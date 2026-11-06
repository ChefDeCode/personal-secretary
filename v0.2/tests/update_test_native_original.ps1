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
$port = 8813; $base = "http://127.0.0.1:$port"; $srv = Start-Process node -ArgumentList "`"$PSScriptRoot\mock_server.js`"", $port -PassThru -WindowStyle Hidden; Start-Sleep 1
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
"— 安装、健康检查、退回（测试文件夹里）—"
$tgt = "$T\app\v0.2"; New-Item -ItemType Directory -Force "$tgt\data", "$tgt\ui" | Out-Null
'0.2.0' | Set-Content "$tgt\VERSION" -NoNewline; '# old' | Set-Content "$tgt\秘书.ps1"; 'keep' | Set-Content "$tgt\data\keep.txt"
# 「新版本」：写出运行标记然后待着（健康）；坏版本：马上退出（不健康）
$good = "$T\fake_good.ps1"; "param(`$t) `$rs = @{ pid = `$PID; clean = `$false; started = (Get-Date).ToString('s') } | ConvertTo-Json -Compress; [IO.File]::WriteAllText((Join-Path `$t 'data\run_state.json'), `$rs); Start-Sleep 40" | Set-Content $good -Encoding UTF8
$bad = "$T\fake_bad.ps1"; 'exit 3' | Set-Content $bad -Encoding UTF8
"@powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$good`" `"$tgt`"" | Set-Content "$T\good.cmd" -Encoding ASCII; "@powershell -NoProfile -ExecutionPolicy Bypass -File `"$bad`"" | Set-Content "$T\bad.cmd" -Encoding ASCII
$p = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$v2\更新器.ps1", '-Stage', "$T\stage\0.2.1", '-Target', $tgt, '-Version', '0.2.1', '-OldVersion', '0.2.0', '-StartExe', "$T\good.cmd", '-HealthSeconds', '20') -PassThru -WindowStyle Hidden; $p.WaitForExit(90000)
Assert ($p.ExitCode -eq 0 -and (Get-Content "$tgt\VERSION" -Raw).Trim() -eq '0.2.1' -and (Get-Content "$tgt\data\keep.txt" -Raw).Trim() -eq 'keep' -and (Test-Path "$T\app\update_backup\0.2.0\秘书.ps1")) "update 0.2.0 → 0.2.1: backed up, installed, new version healthy; user data untouched"
$v021 = Get-Content "$tgt\秘书.ps1" -Raw
$zb = [Convert]::FromBase64String($fx['packages']['0.3.0']['zip_b64']); [void](Expand-ReleaseZip $zb "$T\stage\0.3.0")
$p = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$v2\更新器.ps1", '-Stage', "$T\stage\0.3.0", '-Target', $tgt, '-Version', '0.3.0', '-OldVersion', '0.2.1', '-StartExe', "$T\bad.cmd", '-HealthSeconds', '8') -PassThru -WindowStyle Hidden; $p.WaitForExit(90000)
$steps = @(Get-Content "$tgt\data\update_log.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object to -eq '0.3.0' | ForEach-Object step)
Assert ($p.ExitCode -eq 2 -and (Get-Content "$tgt\VERSION" -Raw).Trim() -eq '0.2.1' -and (Get-Content "$tgt\秘书.ps1" -Raw) -eq $v021 -and $steps -contains 'rollback') "new version fails to start → rolled back to 0.2.1 automatically (log: $($steps -join ' → '))"
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | ForEach-Object { try { $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine; if ($cl -match 'fake_good|fake_bad') { Stop-Process -Id $_.Id -Force } } catch {} }
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULT: $script:ok / $script:tot passed (simulated)"
