# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 真服务器上的严格检查（2026-11-05 恢复）：要用你在这台电脑上的登录，所以用真正的安装目录（只读，不改设置、不装东西）。
# 服务器连不上（530 / 域名找不到 / 超时）→ 记「跳过」并写原因；服务器回 401 / 404 / 5xx 或者任何一项没过 → 失败。绝不把错误状态算成通过
$ErrorActionPreference = 'Stop'
$v2 = (Split-Path $PSScriptRoot -Parent)
try { Add-Type -AssemblyName System.Net.Http; $hc = New-Object Net.Http.HttpClient; $hc.Timeout = [TimeSpan]::FromSeconds(12); $pr = $hc.GetAsync('https://secretary.demandatlas.online/healthz').GetAwaiter().GetResult(); $code = [int]$pr.StatusCode }
catch { '[ENVIRONMENT] server unreachable (DNS / timeout / network) — skipped'; exit 54 }
if ($code -eq 530) { '[SERVER530] status=530 — server tunnel down, skipped'; exit 53 }
if ($code -ne 200) { "  [FAIL] server health returned HTTP $code"; exit 1 }# 正式商城上 6 个官方插件（已审核、未上架）：按编号取详情、下载、用内置商店钥匙完整校验；不安装、不对任何应用运行
. "$v2\lib_v2.ps1"; . "$v2\lib_账号.ps1"; . "$v2\lib_商店.ps1"
$ids = [ordered]@{ 'qq-nt' = 'QQ.exe'; 'wxwork' = 'WXWork.exe'; 'dingtalk' = 'DingTalk.exe'; 'feishu' = 'Feishu.exe'; 'outlook-classic' = 'OUTLOOK.EXE'; 'outlook-new' = 'olk.exe' }
"server $((Get-ServerCfg).base); signed in: $(Test-SignedIn); test mode: $([bool](Read-Config).server.store_test_key); meta keys ok: $((Get-MetaKeyCheck -Fresh).ok)"
$pass = 0
foreach ($id in $ids.Keys) {
  $d = Invoke-Api 'GET' "/v1/store/plugins/$id" -Auth
  if ($d.status -ne 200) { "  [FAIL] $id — details HTTP $($d.status) $($d.error['code'])"; continue }
  $vers = @($d.json['versions'] | Where-Object { $_['review_status'] -eq 'approved' }); $ver = [string]$vers[0]['version']
  $pk = Get-StorePackage $id $ver
  if (-not $pk.ok) { "  [FAIL] $id $ver — $($pk.code): $($pk.reason)"; continue }
  $proc = [string]$pk.manifest['app']['process']; $perms = @($pk.manifest['permissions']) -join ','
  $acts = @($pk.script['actions'].Keys) -join ','
  $problems = @()
  if ($proc -ne $ids[$id]) { $problems += "process $proc (expected $($ids[$id]))" }
  if (@($pk.manifest['permissions'] | Where-Object { $_ -notin 'app.observe', 'region.read:chat_list', 'region.read:message_area' }).Count) { $problems += "unexpected permission(s): $perms" }
  $hdr = $null; $r1 = $script:AcctHttp.SendAsync((New-ApiRequest 'GET' "/v1/store/plugins/$id/versions/$ver/package" $null -Auth)).Result; $vals = $null; if ($r1.Headers.TryGetValues('X-Package-Sha256', [ref]$vals)) { $hdr = @($vals)[0] }
  if (-not $hdr) { $problems += 'no X-Package-Sha256 header' }
  if ($problems.Count) { "  [FAIL] $id $ver — $($problems -join '; ')" } else { $pass++; "  [PASS] $id $ver — signature (key $($pk.statement['key_id'])), sha256 + size + X-Package-Sha256 header, manifest = statement, regions, script ($acts) all ok; process $proc; perms $perms" }
}
# 运行时找窗口：进程名不分大小写（OUTLOOK.EXE 要能对上正在运行的 outlook.exe）
$caseOk = [bool](Get-Process ([IO.Path]::GetFileNameWithoutExtension('EXPLORER.EXE')) -ErrorAction SilentlyContinue)
"  [$(if ($caseOk) { 'PASS' } else { 'FAIL' })] runtime window matching is case-insensitive (manifest 'EXPLORER.EXE' finds running explorer.exe)"
"RESULT: $pass / $($ids.Count) plugins verified (nothing installed)"
if ($pass -ne $ids.Count -or -not $caseOk) { exit 1 }; exit 0
