# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_数据.ps1 — 侧窗面板的数据桥：读取 data\ 下的本地数据（DPAPI 解密）组装成给页面的 JSON；处理页面发来的开关修改
# 只在本机进程内解密，数据通过 WebView2 的 PostWebMessage 交给页面，不落盘明文、不联网。
# 依赖 lib_窗口工具.ps1（开关定义与读取），调用方需先 dot-source 它。
Add-Type -AssemblyName System.Security
$script:DataDir = Join-Path $PSScriptRoot 'data'
$script:Entropy = [Text.Encoding]::UTF8.GetBytes('secretary-v0.1')   # 与 12_值守.ps1 相同
function Unprotect([string]$b) { if (-not $b) { return '' }; try { [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($b), $script:Entropy, 'CurrentUser')) } catch { '' } }
function Read-Jsonl([string]$name, [int]$tail = 0) {
  $f = Join-Path $script:DataDir $name; if (-not (Test-Path $f)) { return @() }
  $lines = if ($tail) { Get-Content $f -Encoding UTF8 -Tail $tail } else { Get-Content $f -Encoding UTF8 }
  @($lines | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
}

# 组装面板数据：设置（功能 + 权限）、今天清单、未读会话、最近新消息、运行状态
function Get-PanelData {
  $today = (Get-Date).Date
  $todos = @(Read-Jsonl 'todos.jsonl' | Where-Object { ([datetime]$_.ts).Date -eq $today } | ForEach-Object {
    [ordered]@{ category = $_.类别; who = Unprotect $_.谁; what = Unprotect $_.事情; due = Unprotect $_.截止; conv = Unprotect $_.conv
                time = ([datetime]$_.原文时间).ToString('HH:mm'); source = $_.来源 } })
  $list = @(); $lf = Join-Path $script:DataDir 'list_latest.json'
  if (Test-Path $lf) { try { $list = @((Get-Content $lf -Raw -Encoding UTF8 | ConvertFrom-Json).items) } catch {} }
  $unread = @($list | Where-Object 未读 | ForEach-Object { [ordered]@{ conv = Unprotect $_.会话; preview = Unprotect $_.预览; time = Unprotect $_.时间 } })
  $recent = @(Read-Jsonl 'messages.jsonl' 400 | Where-Object { -not $_.baseline } | Select-Object -Last 40 | ForEach-Object {
    [ordered]@{ conv = Unprotect $_.conv; sender = Unprotect $_.sender; text = Unprotect $_.text; image = [bool]$_.is_image
                time = ([datetime]$_.ts).ToString('HH:mm'); shown = Unprotect $_.shown } }); [array]::Reverse($recent)
  $stats = $null; $sf = Join-Path $script:DataDir 'stats.json'; if (Test-Path $sf) { try { $stats = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  $pidFile = Join-Path $script:DataDir 'pid'
  $watching = (Test-Path $pidFile) -and [bool](Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue)
  $hint = ''; $hf = Join-Path $script:DataDir 'hint.txt'; if (Test-Path $hf) { $hint = (Get-Content $hf -Raw -Encoding UTF8).Trim() }
  [ordered]@{
    type = 'data'; name = Get-SecretaryName; updated = (Get-Date).ToString('HH:mm:ss'); watching = $watching; hint = $hint
    features = @($script:FeatDefaults.Keys | ForEach-Object { [ordered]@{ key = $_; label = $script:FeatLabels[$_]; on = Get-Feature $_ } })
    permissions = @($script:PermDefaults.Keys | ForEach-Object { [ordered]@{ key = $_; label = $script:PermLabels[$_]; on = Get-Permission $_; locked = ($_ -eq 'type_or_send') } })
    todos = $todos; unread = $unread; recent = $recent
    stats = $(if ($stats) { [ordered]@{ newMessages = $stats.新消息; extracted = $stats.提取条目; cloudCostUsd = $stats.云端费用美元 } } else { $null })
  }
}

# 页面请求修改开关：与 13_设置.ps1 规则一致（type_or_send 锁定为关；autostart 关时删除启动快捷方式，开时只记意愿）
function Set-Switch([string]$name, [bool]$on) {
  $cfgFile = $script:CfgPath   # 不叫 $cfgPath：和 $script:CfgPath 只差大小写，PowerShell 里会被当成同一个名字
  $cfg = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
  foreach ($sec in 'features', 'permissions') { if (-not $cfg.$sec) { $cfg | Add-Member -NotePropertyName $sec -NotePropertyValue ([pscustomobject]@{}) -Force } }
  if ($script:FeatDefaults.Contains($name)) { $sec = 'features' } elseif ($script:PermDefaults.Contains($name)) { $sec = 'permissions' } else { return '没有这个开关' }
  if ($name -eq 'type_or_send' -and $on) { return '输入或发送消息在本原型里锁定为关' }
  $cfg.$sec | Add-Member -NotePropertyName $name -NotePropertyValue $on -Force
  [IO.File]::WriteAllText($cfgFile, ($cfg | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
  ''
}
