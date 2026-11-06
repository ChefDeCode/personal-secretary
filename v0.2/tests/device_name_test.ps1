# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 设备名：登录时发给服务端的名字默认是「Windows 电脑-XXXX」，绝不带 Windows 用户名和电脑名；你自己填的名字才会用。
# 用临时设置文件和假的服务端接口（只记录请求，不联网、不打开浏览器）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
$T = Join-Path $env:TEMP ('secretary_devname_' + [guid]::NewGuid().ToString('n').Substring(0, 6)); New-Item -ItemType Directory -Force "$T\data" | Out-Null
. "$v2\lib_v2.ps1"
[IO.File]::WriteAllText("$T\config.json", '{"server":{"model":"m"}}'); $script:CfgPath = "$T\config.json"; $script:V2Data = "$T\data"; $script:AcctDir = "$T\data"
. "$v2\lib_账号.ps1"
$script:AcctDir = "$T\data"; $script:V2Data = "$T\data"; $script:CfgPath = "$T\config.json"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$script:Sent = New-Object System.Collections.ArrayList
function Invoke-Api([string]$Method, [string]$Path, $Body) { [void]$script:Sent.Add(@{ path = $Path; body = $Body }); @{ status = 200; json = @{ device_code = 'dc'; user_code = 'ABCD-1234'; verification_uri_complete = 'http://127.0.0.1:1/device'; interval = 5; expires_in = 600 } } }
function Open-ServerLink([string]$url) { $true }
$user = [Environment]::UserName; $machine = [Environment]::MachineName
function Leaks([string]$s) { ($user -and $s.IndexOf($user, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($machine -and $s.IndexOf($machine, [StringComparison]::OrdinalIgnoreCase) -ge 0) }
try {
  $n1 = Get-DeviceName
  Check "default name is neutral: Windows 电脑- plus 4 random characters" ($n1 -match '^Windows 电脑-[0-9A-F]{4}$')
  Check 'default name has no Windows user name or computer name' (-not (Leaks $n1))
  Check 'the same name is kept next time (saved in settings)' ((Get-DeviceName) -eq $n1 -and [string](Read-Config).server.device_name -eq $n1)
  $r = Start-DeviceLogin
  $sentName = [string]@($script:Sent | Where-Object { $_.path -eq '/v1/device/code' })[0].body.device_name
  Check "login sends the neutral name ($(@($script:Sent).Count) request)" ($sentName -eq $n1 -and $r.device_name -eq $n1 -and -not (Leaks $sentName))
  Set-ServerCfg 'device_name' '我的笔记本'; Stop-DeviceLogin; $script:Sent.Clear(); [void](Start-DeviceLogin)
  Check 'a name you typed is used as is' ([string]$script:Sent[0].body.device_name -eq '我的笔记本')
  Check 'device names must be 1 to 40 characters without control characters' ((Test-DeviceName '笔记本') -and -not (Test-DeviceName '') -and -not (Test-DeviceName '   ') -and -not (Test-DeviceName ('x' * 41)) -and -not (Test-DeviceName "a`tb"))
  Set-ServerCfg 'device_name' ''; $n3 = Get-DeviceName
  Check 'a cleared name falls back to a new neutral one' ($n3 -match '^Windows 电脑-[0-9A-F]{4}$' -and -not (Leaks $n3))
  $src = [IO.File]::ReadAllText("$v2\lib_账号.ps1")
  Check 'the account code never reads the Windows user name or computer name for the device name' ($src -notmatch '\[Environment\]::(UserName|MachineName)' -and $src -notmatch '\$env:(USERNAME|COMPUTERNAME)')
} finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
"device_name_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
