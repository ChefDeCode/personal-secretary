# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 插件商城一键安装，端到端（真服务器，装在临时文件夹，不动你的真设置）：列表 → 下载 + 本机校验 → 权限卡片 → 安装 → 自检（只读：截图认字，只记数字）→ 卸载
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_通用识别.ps1"; . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_账号.ps1"; . "$v2\lib_商店.ps1"
$T = Join-Path $env:TEMP 'secretary_store_e2e'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null; $script:V2Data = $T
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$sv = Get-StoreView; Check "store lists plugins ($(@($sv.plugins).Count))" (@($sv.plugins).Count -gt 0)
$running = @($sv.plugins | Where-Object { $proc = $_; $_ }) ; $wx = $sv.plugins | Where-Object { $_.app -eq '微信' } | Select-Object -First 1
$si = Start-StoreInstall $wx.id $wx.latest; Check "download + verify + permission card ($(@($si.consent.perms).Count) permissions, send=$([bool](@($si.consent.perms) | Where-Object send)))" ($si.ok -and @($si.consent.perms).Count)
$ci = Confirm-StoreInstall $wx.id; Check "install after clicking 安装 ($($ci.version))" ($ci.ok -and @(Get-InstalledPlugins).Count -eq 1)
$st = Test-PluginSelf $wx.id; Check "self-check on the real app, read-only ($($st.detail -replace '：.*?读到', ': read'))" $st.ok
Check 'uninstall removes it' ((Uninstall-StorePlugin $wx.id) -and @(Get-InstalledPlugins).Count -eq 0)
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"store_e2e_test: $pass pass, $fail fail"
