# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_发文件.ps1 — 把文件发进聊天（只在用户点了确认卡上的「发送」之后由 发送.ps1 调用）
# 流程：把软件短暂叫到前台 → 核对聊天名（必须完全一样）→ 确认前台确实是它 → 点输入框 → 把文件放进剪贴板（CF_HDROP）并粘贴 →
#       出现「发送文件」对话框：核对对话框里的文件名，对上才按它的发送；没有对话框：核对输入框里是这个文件，对上才按回车 →
#       回读聊天，确认最后一条自己的消息是这个文件 → 把软件放回原处、把前台和剪贴板还回去。
# 任何一步对不上都停下，不发送。驱动（driver）把「读界面 / 点 / 按键」抽出来：真微信用截图识别；测试用 UI 自动化驱动我们的模拟聊天软件。
Add-Type -AssemblyName System.Windows.Forms
if (-not ('FileKeys' -as [type])) { Add-Type @'
using System; using System.Runtime.InteropServices;
public static class FileKeys {
  [StructLayout(LayoutKind.Sequential)] struct KI { public ushort vk, scan; public uint flags, time; public IntPtr extra; public uint p1, p2; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public KI ki; }   // x64 下 40 字节
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int size);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  static INPUT K(ushort vk, bool up) { var i = new INPUT(); i.type = 1; i.ki.vk = vk; if (up) i.ki.flags = 2; return i; }
  public static uint CtrlV() { var a = new[] { K(0x11, false), K(0x56, false), K(0x56, true), K(0x11, true) }; return SendInput(4, a, Marshal.SizeOf(typeof(INPUT))); }
  public static uint Key(ushort vk) { var a = new[] { K(vk, false), K(vk, true) }; return SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
  public static uint FgPid() { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p; }
}
'@ }
# 文件名对得上：去掉空白后，较短的一方（OCR 可能截断，至少 4 个字）是另一方的开头；扩展名可有可无
function Test-FileNameShown([string]$shown, [string]$name) {
  $s = ($shown -replace '\s', ''); $n = ($name -replace '\s', ''); if (-not $s -or -not $n) { return $false }
  $base = [IO.Path]::GetFileNameWithoutExtension($n)
  foreach ($cand in @($n, $base)) { if ($s.Contains($cand)) { return $true } }
  $k = [Math]::Min($base.Length, 6); if ($k -lt 4) { $k = [Math]::Min($base.Length, 4) }
  $s.Contains($base.Substring(0, $k)) -and $k -ge [Math]::Min(4, $base.Length)
}
# 剪贴板：先存下原来的内容，用完还回去（尽力而为）
function Set-ClipFile([string]$path) { $old = $null; try { $old = [Windows.Forms.Clipboard]::GetDataObject() } catch {}; $sc = New-Object System.Collections.Specialized.StringCollection; [void]$sc.Add($path); [Windows.Forms.Clipboard]::SetFileDropList($sc); $old }
function Restore-Clip($old) { try { if ($old) { [Windows.Forms.Clipboard]::SetDataObject($old, $true) } else { [Windows.Forms.Clipboard]::Clear() } } catch {} }

function Invoke-FileSend($act, $drv, [scriptblock]$Same) {
  $steps = New-Object System.Collections.Generic.List[object]; $sw = [Diagnostics.Stopwatch]::StartNew()
  $step = { param($t, $ok = $true) $steps.Add(@{ ok = [bool]$ok; text = $t; ms = $sw.ElapsedMilliseconds }) }
  $done = { param($ok, $msg) @{ ok = $ok; message = $msg; steps = $steps.ToArray() } }   # 不能写 @($steps)：List 里装字典时 PowerShell 5.1 会报错
  $path = [string]$act.file; $name = [IO.Path]::GetFileName($path)
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { & $step '要发的文件找不到了' $false; return (& $done $false '文件不在') }
  $clip = $null; $clipSaved = $false; $sendAttempted = $false; $hadFileBefore = $false
  $interrupted = { if ($drv.userMoved) { [bool](& $drv.userMoved) } else { $false } }
  try {
    if ($drv.prepare -and -not (& $drv.prepare)) { return (& $done $false '等你停手') }
    if (-not (& $drv.summon)) { & $step '没能把软件叫到前台' $false; return (& $done $false '叫不到前台') }
    & $step '已把软件叫到前台'
    $t = & $drv.title; if (-not (& $Same $t $act.conv)) { & $step '打开的聊天名对不上，停止' $false; return (& $done $false '会话名不符') }
    & $step "核对过聊天名：$($act.conv)"
    if (-not (& $drv.isForeground)) { & $step '前台不是这个软件，不粘贴' $false; return (& $done $false '前台不对') }
    if (& $interrupted) { return (& $done $false '用户输入') }
    [void](& $drv.focusInput); Start-Sleep -Milliseconds 300
    $hadFileBefore = [bool](& $drv.lastMineHasFile $name)
    $clip = Set-ClipFile $path; $clipSaved = $true
    if (-not (& $drv.isForeground)) { & $step '前台被换走了，不粘贴' $false; return (& $done $false '前台不对') }
    if (& $interrupted) { return (& $done $false '用户输入') }
    [void](& $drv.paste); Start-Sleep -Milliseconds ([int]$drv.settleMs)
    $dlg = & $drv.dialog
    if ($dlg -and $dlg.present) {
      if (-not (Test-FileNameShown ([string]$dlg.fileName) $name)) { [void](& $drv.dialogCancel); & $step '发送对话框里的文件名对不上，已取消，没有发送' $false; return (& $done $false '文件名不符') }
      & $step '发送对话框里的文件名核对无误'
      if (-not (& $drv.isForeground)) { return (& $done $false '前台不对') }
      if (& $interrupted) { return (& $done $false '用户输入') }
      if ($drv.actionId) { Set-ActionPhase $drv.actionId 'send_intent' }; $sendAttempted = $true
      [void](& $drv.dialogSend)
      if ($drv.actionId) { Set-ActionPhase $drv.actionId 'send_pressed' }
    } else {
      if (-not (& $drv.inputHasFile $name)) { [void](& $drv.clearInput); & $step '输入框里没有看到这个文件，没有发送' $false; return (& $done $false '粘贴没成功') }
      & $step '输入框里的文件核对无误'
      if (-not (& $drv.isForeground)) { & $step '前台被换走了，没有按发送' $false; return (& $done $false '前台不对') }
      if (& $interrupted) { return (& $done $false '用户输入') }
      if ($drv.actionId) { Set-ActionPhase $drv.actionId 'send_intent' }; $sendAttempted = $true
      [void](& $drv.pressEnter)
      if ($drv.actionId) { Set-ActionPhase $drv.actionId 'send_pressed' }
    }
    Start-Sleep -Milliseconds ([int]$drv.settleMs)
    if ((& $drv.lastMineHasFile $name) -and -not $hadFileBefore) { if ($drv.actionId) { Set-ActionPhase $drv.actionId 'verified' }; & $step '已发出，聊天里能看到这个文件'; return (& $done $true '已发出') }
    & $step '按了发送，但没能在聊天里确认到这个文件，标为「结果不明」，不会重发' $false; return (& $done $null '结果不明')
  } catch { & $step '执行中断，已保留阶段记录' $false; & $done $(if ($sendAttempted) { $null } else { $false }) '执行中断'
  } finally { if ($clipSaved) { Restore-Clip $clip }; try { [void](& $drv.restore) } catch {} }
}

# —— 真微信的驱动：叫过来用 Move-WeChatHere；读界面用 Read-WeChat；点击用窗口消息；按键（Ctrl+V / 回车）用 SendInput，且每次都先确认前台是微信 ——
function New-WeChatFileDriver {
  $d = @{ settleMs = 1500; h = [IntPtr]::Zero; wasMin = $false; wasHidden = $false; prevFg = [IntPtr]::Zero; inputStarted = $false; realAt = 0; interrupted = $false }
  $d.prepare = {
    $cfg = (Read-Config).features; $need = if ($cfg.send_wait -eq 'away1m') { 60000 } else { 2000 }
    $limit = if ($need -ge 60000) { 7200 } else { 60 }
    $d.inputStarted = [RealInput]::Start([int][FgSend]::IdleMs())
    if (-not $d.inputStarted) { return $false }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ([RealInput]::IdleMs() -lt $need) { if ($sw.Elapsed.TotalSeconds -ge $limit) { return $false }; Start-Sleep -Milliseconds 100 }
    $d.realAt = [RealInput]::LastReal; $true
  }.GetNewClosure()
  $d.userMoved = { if ($d.inputStarted -and [RealInput]::LastReal -ne $d.realAt) { $d.interrupted = $true }; [bool]$d.interrupted }.GetNewClosure()
  $d.summon = { $d.prevFg = [FileKeys]::GetForegroundWindow(); $p = @(Get-Process Weixin -ErrorAction SilentlyContinue); if (-not $p.Count) { return $false }
    $h = [WxWin]::FindMain([uint32[]]$p.Id); $d.wasMin = [WxWin]::IsIconic($h); $d.wasHidden = -not [WxWin]::IsWindowVisible($h)   # 记下微信原来的样子（最小化 / 在托盘里），发完放回去
    $r = Move-WeChatHere; if (-not $r.ok) { return $false }; $d.h = [WxWin]::FindMain([uint32[]]$p.Id); Start-Sleep -Milliseconds 500; $true }.GetNewClosure()
  $d.snap = { $wr = [WinTools]::Rect($d.h); $b = [Rec]::Window($d.h, $wr.R - $wr.L, $wr.B - $wr.T); $script:KeepImages = $false; $x = Read-WeChat $d.h $b; $d.lay = [Rec]::Layout($b); $d.w = $b.Width; $d.ht = $b.Height; $b.Dispose(); $x }.GetNewClosure()
  $d.title = { [string](& $d.snap).会话 }.GetNewClosure()
  $d.isForeground = { $wx = @((Get-Process Weixin -ErrorAction SilentlyContinue).Id); $wx -contains [int][FileKeys]::FgPid() }
  $d.focusInput = { $cl = [int]($d.w * $d.lay[0]); $cb = [int]($d.ht * $d.lay[2]); [Rec]::Click($d.h, [int](($cl + $d.w) / 2), [int](($cb + $d.ht) / 2)); $true }.GetNewClosure()
  $d.paste = { [FileKeys]::CtrlV() }
  # 粘贴后微信弹出的「发送给 …」小窗口：同一个进程里新出现的、比主窗口小的可见窗口；用 OCR 读出里面的字
  $d.dialog = { $p = @(Get-Process Weixin -ErrorAction SilentlyContinue); $fg = [FileKeys]::GetForegroundWindow(); if ($fg -eq $d.h -or -not (@($p.Id) -contains [int][FileKeys]::FgPid())) { return @{ present = $false } }
    $wr = [WinTools]::Rect($fg); $b = [Rec]::Window($fg, $wr.R - $wr.L, $wr.B - $wr.T); try { $txt = (@(Get-Lines (Invoke-Ocr $b)) | ForEach-Object 文本) -join '' } finally { $b.Dispose() }
    $d.dlg = $fg; @{ present = $true; fileName = $txt } }.GetNewClosure()
  $d.dialogSend = { if ([FileKeys]::GetForegroundWindow() -eq $d.dlg) { [FileKeys]::Key(0x0D) } }.GetNewClosure()
  $d.dialogCancel = { if ([FileKeys]::GetForegroundWindow() -eq $d.dlg) { [FileKeys]::Key(0x1B) } }.GetNewClosure()
  $d.inputHasFile = { param($name) $wr = [WinTools]::Rect($d.h); $b = [Rec]::Window($d.h, $wr.R - $wr.L, $wr.B - $wr.T); try { $cl = [int]($b.Width * $d.lay[0]); $cb = [int]($b.Height * $d.lay[2]); $rc = New-Object Drawing.Rectangle $cl, ($cb + 4), ($b.Width - $cl), ($b.Height - $cb - 8); $c = Crop $b $rc; $txt = (@(Get-Lines (Invoke-Ocr $c)) | ForEach-Object 文本) -join ''; $c.Dispose() } finally { $b.Dispose() }; Test-FileNameShown $txt $name }.GetNewClosure()
  $d.clearInput = { if ([FileKeys]::GetForegroundWindow() -eq $d.h) { [FileKeys]::Key(0x08) } }.GetNewClosure()   # 只删掉刚粘进去的那个文件（退格一次）
  $d.pressEnter = { [FileKeys]::Key(0x0D) }
  $d.lastMineHasFile = { param($name) $x = & $d.snap; $m = @($x.消息 | Where-Object { $_.发送方 -eq '我' }) | Select-Object -Last 1; [bool]($m -and (Test-FileNameShown ([string]$m.文本) $name)) }.GetNewClosure()
  # 放回原处：原来最小化 / 在托盘里的放回最小化；前台还给原来的窗口
  $d.restore = { if ($d.inputStarted) { [RealInput]::Stop() }; if (($d.wasMin -or $d.wasHidden) -and $d.h -ne [IntPtr]::Zero) { [void][WxWin]::ShowWindow($d.h, 7) }; if (-not $d.interrupted -and $d.prevFg -ne [IntPtr]::Zero) { [void][FileKeys]::SetForegroundWindow($d.prevFg) } }.GetNewClosure()
  $d
}
