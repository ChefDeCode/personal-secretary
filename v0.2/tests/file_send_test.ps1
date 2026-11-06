# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 发文件测试：只在我们自己的模拟聊天软件上（对话框模式 + 输入框模式），不碰微信；按键只在前台是测试窗口时发
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_发文件.ps1"; . "$PSScriptRoot\lib_测试输入.ps1"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]
function Assert($c, $l) { $script:tot++; if ($c) { $script:ok++ }; "  [{0}] {1}" -f $(if ($c) { 'PASS' } else { 'FAIL' }), $l }; $script:ok = 0; $script:tot = 0
# 发送.ps1 里同样的「聊天名完全一样」规则
function Same($x, $y) { $x = ([string]$x -replace '\s', ''); $y = ([string]$y -replace '\s', ''); $x -and $y -and $x -eq $y }
$T = Join-Path $env:TEMP 'secretary_filesend_test'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $T | Out-Null
$file = "$T\秘书测试.txt"; [IO.File]::WriteAllText($file, '【秘书测试】文件发送测试'); $other = "$T\别的文件.txt"; [IO.File]::WriteAllText($other, 'x')
function New-MockDriver($app) {
  $d = @{ settleMs = 900; restored = $false; pasteWhat = $null }; $AE = $AE; $TS = $TS   # 复制到本地：GetNewClosure 只带走本地变量
  $win = { $AE::RootElement.FindFirst($TS::Children, (New-Object Windows.Automation.PropertyCondition ($AE::ProcessIdProperty, $app.Id))) }.GetNewClosure()
  $el = { param($n) (& $win).FindFirst($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, $n))) }.GetNewClosure()
  $d.summon = { $w = & $win; if (-not $w) { return $false }; $w.SetFocus(); Start-Sleep -Milliseconds 400; $true }.GetNewClosure()
  $d.title = { [string](& $el '聊天标题').Current.HelpText }.GetNewClosure()
  $d.isForeground = { [int][FileKeys]::FgPid() -eq $app.Id }.GetNewClosure()
  $d.focusInput = { (& $el '输入框').SetFocus(); $true }.GetNewClosure()
  $d.paste = { if ($d.pasteWhat) { $sc = New-Object System.Collections.Specialized.StringCollection; [void]$sc.Add($d.pasteWhat); [Windows.Forms.Clipboard]::SetFileDropList($sc) }; Assert-NoUserInput; Assert-OursForeground; $k = [FileKeys]::CtrlV(); [TIn]::OurLast = [uint32][Environment]::TickCount; $k }.GetNewClosure()   # 测试自己按的键记一下时间，不算「你动了」
  $d.dialog = { $nm = New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, '发送文件'); $mw = & $win; $dw = if ($mw) { $mw.FindFirst($TS::Children, $nm) }   # 有主人的对话框在 UI 自动化里挂在主窗口下面，不在最上层
    if (-not $dw) { $dw = @($AE::RootElement.FindAll($TS::Children, (New-Object Windows.Automation.PropertyCondition ($AE::ProcessIdProperty, $app.Id)))) | Where-Object { $_.Current.Name -eq '发送文件' } | Select-Object -First 1 }
    if (-not $dw) { return @{ present = $false } }; $d.dlg = $dw; @{ present = $true; fileName = [string]$dw.FindFirst($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, '文件名'))).Current.HelpText + [string]($dw.FindFirst($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::AutomationIdProperty, ''))).Current.Name) + (@($dw.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Text } | ForEach-Object { $_.Current.Name }) -join ' ') } }.GetNewClosure()
  $d.dialogSend = { $b = $d.dlg.FindFirst($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, '发送'))); $b.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }.GetNewClosure()
  $d.dialogCancel = { $b = $d.dlg.FindFirst($TS::Descendants, (New-Object Windows.Automation.PropertyCondition ($AE::NameProperty, '取消'))); $b.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }.GetNewClosure()
  $d.inputHasFile = { param($name) Test-FileNameShown ([string](& $el '输入框').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value) $name }.GetNewClosure()
  $d.clearInput = { Assert-OursForeground; $k = [FileKeys]::Key(0x08); [TIn]::OurLast = [uint32][Environment]::TickCount; $k }
  $d.pressEnter = { Assert-NoUserInput; Assert-OursForeground; $k = [FileKeys]::Key(0x0D); [TIn]::OurLast = [uint32][Environment]::TickCount; $k }
  $d.lastMineHasFile = { param($name) $l = & $el '消息'; $items = @($l.FindAll($TS::Children, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name }); $m = @($items | Where-Object { $_ -like '我：*' }) | Select-Object -Last 1; [bool]($m -and (Test-FileNameShown $m $name)) }.GetNewClosure()
  $d.restore = { $d.restored = $true }.GetNewClosure()
  $d.count = { $l = & $el '消息'; @($l.FindAll($TS::Children, [Windows.Automation.Condition]::TrueCondition)).Count }.GetNewClosure()
  $d.open = { param($n) $i = & $el $n; $i.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 400 }.GetNewClosure()
  $d
}
$apps = @()
try {
  foreach ($mode in 'dialog', 'inline') {
    "— $mode 模式（$(if ($mode -eq 'dialog') { '粘贴后弹出发送对话框' } else { '文件进输入框，回车发送' })）—"
    $app = Start-Process "$PSScriptRoot\模拟聊天.exe" -ArgumentList $mode -PassThru; $apps += $app; Start-Sleep 2; Register-TestWindow $app.Id
    $drv = New-MockDriver $app; & $drv.open '测试会话3'; Start-InputWatch
    $n0 = & $drv.count; $r = Invoke-FileSend @{ file = $file; conv = '测试会话3' } $drv ${function:Same}
    Assert ($r.ok -eq $true -and (& $drv.count) -eq $n0 + 1 -and $drv.restored) "send 秘书测试.txt to the right chat → sent, re-read confirms it, app put back ($(@($r.steps).Count) steps, $($r.steps[-1].ms) ms)"; if ($r.ok -ne $true) { "     steps: " + ((@($r.steps) | ForEach-Object { "$($_.text)=$($_.ok)" }) -join ' | ') + " msg=$($r.message)" }
    $drv.restored = $false; $n0 = & $drv.count; $r = Invoke-FileSend @{ file = $file; conv = '测试会话4' } $drv ${function:Same}
    Assert ($r.ok -eq $false -and $r.message -eq '会话名不符' -and (& $drv.count) -eq $n0 -and $drv.restored) "chat title doesn't match exactly → stops, nothing pasted or sent"
    if ($mode -eq 'dialog') {
      $drv.pasteWhat = $other; $n0 = & $drv.count; $r = Invoke-FileSend @{ file = $file; conv = '测试会话3' } $drv ${function:Same}; $drv.pasteWhat = $null
      Assert ($r.ok -eq $false -and $r.message -eq '文件名不符' -and (& $drv.count) -eq $n0) "send dialog shows a different file name → cancelled, nothing sent (got: $($r.message))"
    } else {
      $drv.pasteWhat = $other; $n0 = & $drv.count; $r = Invoke-FileSend @{ file = $file; conv = '测试会话3' } $drv ${function:Same}; $drv.pasteWhat = $null
      Assert ($r.ok -eq $false -and $r.message -eq '粘贴没成功' -and (& $drv.count) -eq $n0) "input box holds a different file → removed again, nothing sent (got: $($r.message))"
    }
  }
  $r = Invoke-FileSend @{ file = "$T\不存在.txt"; conv = '测试会话3' } $drv ${function:Same}; Assert ($r.ok -eq $false -and $r.message -eq '文件不在') "missing file → stops before touching anything"
} catch [TestAbort] { "  [ABORT] $($_.Exception.Message)" }
finally { foreach ($a in $apps) { if (-not $a.HasExited) { $a.Kill() } }; Restore-MovedWindows; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
"RESULT: $script:ok / $script:tot passed"
