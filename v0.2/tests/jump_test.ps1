# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 「去回复」流程测试：在我们自己的模拟聊天软件上，用 UI 自动化当驱动（不发任何真实鼠标 / 键盘输入，不碰微信）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_回复跳转.ps1"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
$app = Start-Process "$PSScriptRoot\模拟聊天.exe" -PassThru; Start-Sleep 2
function Win { $AE::RootElement.FindFirst($TS::Children, (New-Object Windows.Automation.PropertyCondition ($AE::ProcessIdProperty, $app.Id))) }
function El([string]$name) { (Win).FindFirst($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, $name))) }
function Items([string]$listName) { $l = El $listName; @($l.FindAll($TS::Children, (New-Object Windows.Automation.PropertyCondition ($AE::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)))) }
$script:typed = 0
# UI 自动化驱动：和真实驱动同样的接口
$drv = @{ settleMs = 300 }
$drv.summon = { [bool](Win) }
$drv.read = { @{ title = [string](El '聊天标题').Current.HelpText; rows = @(Items '会话列表' | Where-Object { -not $_.Current.IsOffscreen } | ForEach-Object { @{ name = $_.Current.Name; el = $_ } }); msgs = @(Items '消息' | Where-Object { -not $_.Current.IsOffscreen } | ForEach-Object { $_.Current.Name }) } }
$drv.clickRow = { param($row) $row.el.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() }
$drv.search = { param($name) (El '搜索框').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($name); (El '搜索').GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); $true }
$drv.cancelSearch = { (El '搜索框').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('') }
$drv.scrollUp = { (El '消息').GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Scroll([Windows.Automation.ScrollAmount]::NoAmount, [Windows.Automation.ScrollAmount]::LargeDecrement) }
$drv.focusInput = { (El '输入框').SetFocus(); Start-Sleep -Milliseconds 150; $fe = $AE::FocusedElement; $fe.Current.Name -eq '输入框' }
try {
  $inputVal = { (El '输入框').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value }
  # 1) 列表里看得到的聊天
  $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Invoke-ReplyJump @{ conv = '测试会话3'; who = '示例人'; quote = '周五下午的方案你看过了吗' } $drv
  Assert ($r.ok -and ($r.steps | Where-Object step -eq 'click_list').ok) "visible chat opened from the list ($($sw.ElapsedMilliseconds) ms)"
  Assert (($r.steps | Where-Object step -eq 'verify_title').ok) "title verified"
  Assert (($r.steps | Where-Object step -eq 'scroll_to_message').ok) "scrolled up to the message (≤10 pages)"
  Assert (($r.steps | Where-Object step -eq 'focus_input').ok -and -not (& $inputVal)) "caret in the input box; nothing typed (input empty)"
  "     steps: $(($r.steps | ForEach-Object { "$($_.step)=$(if ($_.ok) { 'ok' } else { 'no' })/$($_.ms)ms" }) -join ', ')"
  # 2) 列表里看不到的：用搜索框
  $r = Invoke-ReplyJump @{ conv = '测试会话37'; who = '示例人'; quote = '周五下午的方案你看过了吗' } $drv
  Assert ($r.ok -and ($r.steps | Where-Object step -eq 'search').ok -and ($r.steps | Where-Object step -eq 'verify_title').ok) "off-screen chat opened through the search box, title verified"
  # 3) 不存在的聊天：标题对不上 → 停下，不放光标，不乱猜
  $r = Invoke-ReplyJump @{ conv = '不存在的会话'; who = '示例人'; quote = 'x' } $drv
  Assert (-not $r.ok -and $r.text -eq '没找到这个聊天' -and -not ($r.steps | Where-Object step -eq 'focus_input')) "unknown chat → stops with 「没找到这个聊天」, no caret, no guessing"
  Assert (-not (& $inputVal)) "nothing was ever typed into the input box"
  # 4) 原话不在最近 10 屏：仍然打开聊天，说明找不到那条
  $r = Invoke-ReplyJump @{ conv = '测试会话5'; who = '示例人'; quote = '这句话根本不存在' } $drv
  $ups = @($r.steps | Where-Object step -eq 'scroll_to_message')
  Assert ($r.ok -and -not $ups[0].ok -and $r.text -match '不在最近几屏') "message not found within the bound → chat still open, says so (bounded scroll)"
} finally { if (-not $app.HasExited) { $app.Kill() } }
"RESULT: $script:ok / $script:tot passed"
