# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 发送.ps1 — 执行一张你已经在确认卡上点了「发送」的动作（秘书在你点了以后单独开这个进程，界面不会卡）
# 只有一种发法：借用最前面几秒。等你停手 → 把微信叫到你现在的桌面最前面 → 只用键盘找聊天、粘贴、逐字核对、回车 → 前台还给你、微信放回原样、剪贴板还原
# （后台打字的老发法和「桌面 2」那一套已经挪到 旧东西\桌面2和后台发送）
# 发之前三道闸：同时只许一个在发；发出去过的绝不再发；同一条两分钟里试了 3 次就停
param([Parameter(Mandatory = $true)][string]$Id)
. (Join-Path $PSScriptRoot 'lib_v2.ps1')
. (Join-Path $PSScriptRoot 'lib_动作.ps1')
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'lib_版本.ps1')) { . (Join-Path $PSScriptRoot 'lib_版本.ps1'); Write-ReliabilityVersionMark -DataPath $script:V2Data -Component sender }
. (Join-Path $script:Root 'lib_识别.ps1')
$a = Get-Action $Id; if (-not $a) { exit 1 }
$steps = New-Object System.Collections.ArrayList
function Step([string]$t, [bool]$ok = $true) { [void]$steps.Add(@{ ok = $ok; text = $t }) }
function Finish([object]$ok, [string]$msg) {
  if ($script:LitFile) { try { Set-Lit $script:LitFile 1 } catch {} }
  $result = Save-ActionResult $Id $ok $msg @($steps) ([string]$script:Draft)
  $saved = Get-Action $Id
  [IO.File]::AppendAllLines((Join-Path $script:V2Data 'send_log.jsonl'), [string[]]@((Protect ((@{ ts = (Get-Date).ToString('s'); id = $Id; status = $result.state; message = $msg; steps = @($steps) }) | ConvertTo-Json -Depth 8 -Compress))), [Text.UTF8Encoding]::new($false))
  exit
}
function Norm($s) { ([string]$s -replace '\s', '') }
# 会话名必须完全一样（去掉空白和群人数「(12)」后）；只有列表里被截断的名字（以 … 结尾）才按开头比。以前开头一样就算，会把「Leo明远」和「Leo明远2」当成同一个
function Same($x, $y) {
  $x = (Norm $x) -replace '[（(]\d+[)）]$', ''; $y = (Norm $y) -replace '[（(]\d+[)）]$', ''; if (-not $x -or -not $y) { return $false }; if ($x -eq $y) { return $true }
  $tx = $x -match '(…|\.\.\.)$'; $ty = $y -match '(…|\.\.\.)$'; $x2 = $x -replace '(…|\.\.\.)$', ''; $y2 = $y -replace '(…|\.\.\.)$', ''
  [bool](($tx -and $x2.Length -ge 2 -and $y.StartsWith($x2)) -or ($ty -and $y2.Length -ge 2 -and $x.StartsWith($y2)))
}
function SameExact($x, $y) { $x = (Norm $x) -replace '[（(]\d+[)）]$', ''; $y = (Norm $y) -replace '[（(]\d+[)）]$', ''; [bool]($x -and $y -and $x -ceq $y) }
function Snap($h) { $r = [WinTools]::Rect($h); $b = [Rec]::Window($h, $r.R - $r.L, $r.B - $r.T); $x = Read-WeChat $h $b; $b.Dispose(); $x }

$script:SendLease = $null
try {
$script:SendLease = Enter-SendLease
if (-not $script:SendLease) { exit 2 }
if ((Get-ActionState $a) -eq 'succeeded') { Step '这条之前已经发出去了，没有再发一次'; Finish $true '已发出' }
if ((Get-ActionState $a) -in 'unknown','running') { exit 2 }
if ($a.status -ne 'confirmed') { Step '这张卡片没有被确认，不执行' $false; Finish $false '未确认' }
if (-not (Get-Switch 'send_messages')) { Step '「替你发消息和文件」已关闭' $false; Finish $false '权限已关闭' }

# 三道闸（防止同一条被好几个发送程序同时 / 反复去发；2026-11-01 23:00 出过一次）
# 1) 别的发送程序正在借用微信 → 这次不动，交给秘书排队
$busy = Join-Path $script:V2Data 'send_busy.flag'
if (Test-Path $busy) { $op = 0; try { $op = [int](Get-Content $busy -Raw) } catch {}; if ($op -and $op -ne $PID -and (Get-Process -Id $op -ErrorAction SilentlyContinue) -and ((Get-Date) - (Get-Item $busy).LastWriteTime).TotalMinutes -lt 3) { $script:NoAutoRetry = $true; Step '另一条消息正在发，这条等它发完再发' $false; Finish $false '另一条正在发' } }
# 2) 这一条之前已经发出去了（这次的或挪开的上一次结果是「已发出」）→ 绝不再发一次
$prevOk = $false; foreach ($rfPrev in (Join-Path $script:ActDir "$Id.result.json"), (Join-Path $script:ActDir "$Id.result.prev.json")) { if (Test-Path $rfPrev) { try { if (((Unprotect (Get-Content $rfPrev -Raw)) | ConvertFrom-Json).ok -eq $true) { $prevOk = $true } } catch {} } }
if ($prevOk) { $a.status = 'sent'; Set-ActionField $a 'phase' 'verified'; Save-Action $a; Step '这条之前已经发出去了，没有再发一次' $true; Finish $true '已发出' }
# 3) 同一条 2 分钟里已经试了 3 次 → 先停下，等你点重试
if ((Get-ActionAttemptCount $Id) -ge 3) { Step '这条两分钟里已试过三次，请稍后点重试' $false; Finish $false '尝试太多' }
[IO.File]::WriteAllText($busy, [string]$PID); $script:OwnBusy = $busy   # 正在发：值守这段时间不去点、不去滚微信
if (Test-SessionLocked) { Step '电脑锁着，等你解锁后再发' $false; Finish $false '电脑锁着' }   # 锁着就不借用前台；解锁后秘书会接着发
$a = Start-ActionAttempt $Id
. (Join-Path $PSScriptRoot 'lib_虚拟桌面.ps1')   # 找微信窗口的小工具

if ($a.file) {
  # 发文件：要把微信短暂叫到前台粘贴（见 lib_发文件.ps1）；文字以外的部分（有附言时）这一版不一起发
  . (Join-Path $PSScriptRoot 'lib_前台发送.ps1')
  . (Join-Path $PSScriptRoot 'lib_发文件.ps1')
  Set-Lit (Join-Path $script:DataDir 'state.json') 120; $script:LitFile = Join-Path $script:DataDir 'state.json'   # 发送全程亮着，做完（Finish）熄灭
  $p = Get-Process Weixin -ErrorAction SilentlyContinue; if (-not $p) { Step '微信没有在运行' $false; Finish $false '微信不可用' }
  # Files use the same title/foreground checks; no speculative background clicks.
  $drv = New-WeChatFileDriver
  $drv.actionId = $Id
  try { $r = Invoke-FileSend $a $drv ${function:SameExact} }
  catch { Step '文件发送中断，请核对结果' $false; $ar = Get-Action $Id; Finish $(if ($ar.phase -eq 'preparing') { $false } else { $null }) '执行中断' }
  foreach ($s in $r.steps) { Step $s.text $s.ok }
  Finish $r.ok $r.message
}

# 发文字：借用最前面
. (Join-Path $PSScriptRoot 'lib_找聊天.ps1'); . (Join-Path $PSScriptRoot 'lib_打字.ps1'); . (Join-Path $PSScriptRoot 'lib_前台发送.ps1')
Set-Lit (Join-Path $script:DataDir 'state.json') 120; $script:LitFile = Join-Path $script:DataDir 'state.json'; $script:NoAutoRetry = $true
$cfgF = (Read-Config).features
$o = @{ proc = 'Weixin'; findMain = { param($ids) [FgSend]::FindLarge($ids, $true) }   # 只认看得见的大窗口；托盘里的由微信自己的快捷键叫出来
        summon = { param($hh) [FgSend]::CtrlAlt(0x57); for ($i = 0; $i -lt 12 -and -not [FgSend]::IsWindowVisible($hh); $i++) { Start-Sleep -Milliseconds 50 } }   # 托盘里的：按微信自己的「显示微信」快捷键 Ctrl+Alt+W（绝不重新启动微信：那样会弹出一个新的登录窗口）
        trayHide = { param($hh) [void][FgSend]::ShowWindow($hh, 7) }   # 原来在托盘里的：发完放成最小化（用系统的方法藏回托盘，微信自己会搞不清状态）
        pill = (Join-Path $script:V2Data 'notice_pill.json'); border = (Join-Path $script:DataDir 'border.json'); same = ${function:SameExact}; actionId = $Id; noMouse = [bool]$cfgF.never_borrow_mouse
        idleMs = $(if ($cfgF.send_wait -eq 'away1m') { 60000 } else { 2000 }); maxWaitSec = $(if ($cfgF.send_wait -eq 'away1m') { 7200 } else { 60 }); nowFlag = (Join-Path $script:V2Data "send_now_$Id.flag") }
$fr = $null; try { $fr = Invoke-FgSend $o $a.conv $a.text -Replace:([bool]$a.replace) } catch { Step '发送中断，已根据记录判断是否需要核对' $false; $ar = Get-Action $Id; Finish $(if ($ar.phase -eq 'preparing') { $false } else { $null }) '执行中断' }   # 出错也要写结果、收掉「正在发」
try { [IO.File]::AppendAllLines((Join-Path $script:V2Data 'send_trace.jsonl'), [string[]]@((@{ ts = (Get-Date).ToString('s'); id = $Id; kind = 'fg'; ok = $fr.ok; msg = $fr.msg; focus = $fr.focus; diag = $fr.diag; keys_effect = $fr.keys_effect; fg_at_keys = $fr.fg_at_keys; capped = [bool]$fr.capped; cbf = $fr.cbf; verify = $fr.verify; front_ms = $fr.front_ms; steps_ms = $fr.t; fg_back = $fr.fg_back; clip_ok = $fr.clip_ok } | ConvertTo-Json -Depth 3 -Compress))) } catch {}
foreach ($s in @($fr.steps)) { Step $s.text $s.ok }
$script:Draft = $fr.draft; if ($fr.ok -ne $false) { $script:EnterPressed = $true }
Finish $fr.ok $fr.msg
} finally {
  if ($script:OwnBusy -and (Test-Path -LiteralPath $script:OwnBusy)) {
    try { if (([IO.File]::ReadAllText($script:OwnBusy)).Trim() -eq [string]$PID) { [IO.File]::Delete($script:OwnBusy) } } catch {}
  }
  Exit-SendLease $script:SendLease
}
