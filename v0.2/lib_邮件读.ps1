# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_邮件读.ps1 — Outlook（新版 olk.exe / 经典版 OUTLOOK.EXE）原地只读：用无障碍接口（UIA）读邮件列表和打开着的那封邮件
# 不点、不打字、不切前台、不动窗口；最小化着不读（等它开着）。只有你在连接卡上点了「连接」（设置里 Outlook 邮件开着）才会读
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$script:MailProcs = @('olk', 'OUTLOOK')
# 能不能读：窗口在、没最小化（最小化着不还原、不动它，等你自己打开）
function Test-MailReadable([IntPtr]$h) { $h -ne [IntPtr]::Zero -and -not [WinTools]::IsIconic($h) }
# Outlook 的主窗口（没开 / 最小化 → 0）
function Get-MailWindow([switch]$AllowMin) {   # -AllowMin：最小化 / 托盘里的也给（值守用透明读）
  foreach ($n in $script:MailProcs) {
    $ps = @(Get-Process $n -ErrorAction SilentlyContinue); if (-not $ps.Count) { continue }
    $h = [AppWin]::Largest([uint32[]]$ps.Id); if ($h -eq [IntPtr]::Zero) { $h = [WinTools]::LargestVisibleWindow([uint32[]]$ps.Id) }
    if ((Test-MailReadable $h) -or ($AllowMin -and $h -ne [IntPtr]::Zero)) { return @{ h = $h; proc = $n } } }
  $null }
# 读一次：邮件列表（每行一段文字 + 是不是未读）+ 打开着的邮件正文（前 40 行）。只返回文字，调用方决定存不存
function Read-MailUia([IntPtr]$h, [int]$maxRows = 40) {
  $root = [Windows.Automation.AutomationElement]::FromHandle($h)
  $all = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
  $CT = [Windows.Automation.ControlType]
  $rows = New-Object System.Collections.Generic.List[object]; $body = ''; $bodyLen = 0
  foreach ($e in $all) {
    $c = $e.Current
    if (($c.ControlType -eq $CT::ListItem -or $c.ControlType -eq $CT::DataItem) -and $c.Name -and $rows.Count -lt $maxRows) {
      $n = ($c.Name -replace '\s+', ' ').Trim(); if ($n.Length -lt 6) { continue }   # 太短的是按钮、文件夹之类
      $rows.Add(@{ text = $n; unread = [bool]($n -match '^(未读|Unread)\b|\b(未读|Unread)\b') }) }
    elseif ($c.ControlType -eq $CT::Document) {   # 阅读窗格：取最长的那个文档
      $t = ''; try { $tp = $e.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern); $t = $tp.DocumentRange.GetText(20000) } catch { $t = [string]$c.Name }
      if ($t.Length -gt $bodyLen) { $body = $t; $bodyLen = $t.Length } }
  }
  $lines = @($body -split "`r?`n" | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { $_ } | Select-Object -First 40)
  @{ nodes = [int]$all.Count; rows = $rows.ToArray(); body = [string[]]$lines }
}
# Outlook 装了没有（给设置页和连接卡）
function Test-MailInstalled { (Test-Path "$env:LOCALAPPDATA\Microsoft\WindowsApps\olk.exe") -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE') }
