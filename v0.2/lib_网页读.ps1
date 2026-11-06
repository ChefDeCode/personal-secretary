# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_网页读.ps1 — Edge 当来源：只读你勾选过的网站（设置里的网站清单），而且只读你正开着的那个标签页
# 原地只读（无障碍接口）：先看地址，网站不在清单里就什么都不读；不点、不打字、不切标签、不动窗口；最小化着不读
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
function Get-EdgeWindow([switch]$AllowMin) {   # -AllowMin：最小化的也给（值守用透明读）
  $ps = @(Get-Process msedge -ErrorAction SilentlyContinue); if (-not $ps.Count) { return $null }
  $h = [AppWin]::Largest([uint32[]]$ps.Id); if ($h -eq [IntPtr]::Zero) { $h = [WinTools]::LargestVisibleWindow([uint32[]]$ps.Id) }
  if ($h -eq [IntPtr]::Zero -or (-not $AllowMin -and [WinTools]::IsIconic($h))) { return $null }; $h }
# 网站清单里的写法：example.com（含子域名）；去掉 http://、www.、路径
function ConvertTo-SiteHost([string]$s) { $s = ([string]$s).Trim().ToLowerInvariant() -replace '^[a-z]+://', '' -replace '^www\.', ''; ($s -split '[/?#:]')[0] }
function Test-SiteAllowed([string]$url, $sites) {
  $hst = ConvertTo-SiteHost $url; if (-not $hst) { return $false }
  foreach ($s in @($sites)) { $x = ConvertTo-SiteHost $s; if ($x -and ($hst -eq $x -or $hst.EndsWith('.' + $x))) { return $true } }; $false }
# 读地址栏（第一个内容像网址的输入框）
function Get-EdgeUrl($root) {
  $edits = $root.FindAll([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Edit)))
  foreach ($e in $edits) { $v = ''; try { $v = [string]$e.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value } catch {}
    if ($v -match '^(https?://)?[\w-]+(\.[\w-]+)+([/:?#].*)?$') { return $v } }
  '' }
# 读一次：地址；只有网站在清单里才读正文（前 80 行）
function Read-EdgeUia([IntPtr]$h, $sites) {
  $root = [Windows.Automation.AutomationElement]::FromHandle($h); $url = Get-EdgeUrl $root
  $r = @{ url_host = (ConvertTo-SiteHost $url); allowed = (Test-SiteAllowed $url $sites); lines = [string[]]@() }
  if (-not $r.allowed) { return $r }
  $docs = $root.FindAll([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Document)))
  $best = ''; foreach ($d in $docs) { $t = ''; try { $t = $d.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(40000) } catch {}; if ($t.Length -gt $best.Length) { $best = $t } }
  $r.lines = [string[]]@($best -split "`r?`n" | ForEach-Object { $x = ($_ -replace '\s+', ' ').Trim(); if ($x.Length -gt 300) { $x.Substring(0, 300) } else { $x } } | Where-Object { $_ } | Select-Object -First 80)
  $r }
