# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 旧的设置文件也能照常打开：里面还留着「桌面 2」、后台发送这些已经去掉的键，不报错、不出现在设置里、别的开关照常改；新的「发送」一组能来回切
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; . "$v2\lib_v2.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$T = Join-Path $env:TEMP 'secretary_oldcfg'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null
$script:CfgPath = "$T\config.json"; $script:V2Data = $T
[IO.File]::WriteAllText($script:CfgPath, '{"name":"秘书","features":{"auto_desktop2":true,"auto_launch_apps":true,"edge_line":true,"taskbar_proxy":true,"watch_home_d2":true,"wechat_bg_send":true,"auto_park":true,"watch_wechat":true,"border":false,"never_borrow_mouse":true,"send_wait":"away1m"},"permissions":{"send_messages":true},"launch_apps":["微信"]}', (New-Object Text.UTF8Encoding $false))
$s = $null; $err = ''; try { $s = Get-Settings } catch { $err = $_.Exception.Message }
Check "old config loads without error $err" ($s -ne $null -and -not $err)
$dead = 'auto_desktop2', 'auto_launch_apps', 'edge_line', 'taskbar_proxy', 'watch_home_d2', 'wechat_bg_send', 'auto_park'
Check 'removed switches are not offered any more' (-not @($dead | Where-Object { $s.Contains($_) -or $script:SwitchMap.Contains($_) }).Count)
Check "switches left: $($script:SwitchMap.Count)" ($script:SwitchMap.Count -eq 19)
Check 'old values for kept switches still read (border off, send on, never-borrow-mouse on, wait-until-away on)' ($s.border -eq $false -and $s.send_messages -eq $true -and $s.no_mouse -eq $true -and $s.send_away -eq $true)
Check 'changing a removed switch is refused politely' ((Set-Setting 'auto_desktop2' $false) -eq '没有这个开关')
[void](Set-Setting 'send_away' $false); Check 'wait-until-away can be turned off' (-not (Get-Settings).send_away -and [string](Read-Config).features.send_wait -eq '')
[void](Set-Setting 'send_away' $true); Check 'and back on' ((Get-Settings).send_away)
[void](Set-Setting 'send_pause' $true); Check 'pause sending writes the existing send-off key' ((Read-Config).features.wechat_send_off -eq $true -and (Get-Settings).send_pause)
[void](Set-Setting 'no_mouse' $false); Check 'never-borrow-mouse writes the existing key' ((Read-Config).features.never_borrow_mouse -eq $false)
Check 'old keys left in the file are kept untouched (nothing deleted from your config)' ((Read-Config).features.auto_desktop2 -eq $true)
Check 'autostart default is off (only on when you turn it on)' (-not $script:FeatDefaults.autostart)
"old_config_test: $pass pass, $fail fail"