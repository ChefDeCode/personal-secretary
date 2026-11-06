# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 安装后登记.ps1 — 安装包装完文件后运行一次：在「开始」菜单放快捷方式、在「应用和功能」里登记卸载入口
# 两样都经过改动记录（v0.2\data\changes.jsonl）做，卸载秘书.ps1 会按记录原样还原。不设开机自动启动（用户在设置里自己开）
param([string]$AppRoot = (Split-Path $PSScriptRoot -Parent), [string]$Version = '0.2.0',
  [string]$StartMenuDir = [Environment]::GetFolderPath('Programs'), [string]$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PersonalSecretary')   # 后两个只给测试改
$ErrorActionPreference = 'Stop'
$v2 = Join-Path $AppRoot 'v0.2'
. (Join-Path $v2 'lib_改动记录.ps1')
$script:ChangeJournal = Join-Path $v2 'data\changes.jsonl'
$exe = Join-Path $v2 '秘书.exe'; $ico = Join-Path $v2 'ui\secretary.ico'
$lnk = Join-Path $StartMenuDir '个人秘书.lnk'
Set-JournaledStartupLink $lnk $true $exe '' $v2 $ico '个人秘书'
$key = $UninstallKey
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$un = '"' + $ps + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $AppRoot '卸载秘书.ps1') + '"'
$vals = [ordered]@{ DisplayName = '个人秘书'; DisplayVersion = $Version; Publisher = 'ChefDeCode'; InstallLocation = $AppRoot; DisplayIcon = $ico
  UninstallString = $un; QuietUninstallString = $un + ' -Mode KeepData -Quiet';  URLInfoAbout = 'https://github.com/ChefDeCode/personal-secretary' }
foreach ($k in $vals.Keys) { Set-JournaledHkcuValue $key $k $vals[$k] }
'ok'