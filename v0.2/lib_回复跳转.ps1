# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_回复跳转.ps1 — 「去回复」：用户点了以后，把软件叫到眼前 → 打开那个聊天 → 核对标题 → 翻到那条消息 → 光标放进输入框
# 只在用户自己点「去回复」时执行；从不替用户打字（只在搜索框里输入聊天名）、从不按发送。标题对不上就停下，说「没找到这个聊天」，绝不乱猜。
# 驱动（driver）把「读界面 / 点 / 输入 / 滚动」抽出来：真实软件用截图识别 + 窗口消息；测试用 UI 自动化驱动我们自己的模拟聊天软件。
# 日志只记每一步用了多久、成没成，不记任何内容（data\jump_log.jsonl）
# 两个聊天名是不是同一个：去掉群人数「(12)」和空白后要完全一样；只有被截断的名字（以 … 或 ... 结尾）才按前缀比
# （以前会把结尾数字也去掉、还随便按前缀比，「测试会话3」和「测试会话37」会被当成同一个）
function Norm2([string]$s) { ($s -replace '\s*[（(]\d+[)）]\s*$', '' -replace '\s', '') }
function Same2([string]$a, [string]$b) {
  $a = Norm2 $a; $b = Norm2 $b; if (-not $a -or -not $b) { return $false }
  $ta = $a -match '(…|\.\.\.)$'; $tb = $b -match '(…|\.\.\.)$'; $a = $a -replace '(…|\.\.\.)$', ''; $b = $b -replace '(…|\.\.\.)$', ''
  if ($a -eq $b) { return $true }
  [bool](($ta -and $a.Length -ge 2 -and $b.StartsWith($a)) -or ($tb -and $b.Length -ge 2 -and $a.StartsWith($b)))
}
function Invoke-ReplyJump($item, $drv) {
  $log = New-Object System.Collections.Generic.List[object]; $sw = [Diagnostics.Stopwatch]::StartNew()
  $step = { param($name, $ok) $log.Add([ordered]@{ step = $name; ok = [bool]$ok; ms = $sw.ElapsedMilliseconds }); $sw.Restart() }
  $done = { param($ok, $text) @{ ok = $ok; text = $text; steps = $log.ToArray() } }   # 不能写 @($log)：List 里装字典时 PowerShell 5.1 会报 Argument types do not match
  $conv = [string]$item.conv; if (-not $conv) { $conv = [string]$item.who }
  # 1) 叫到眼前
  $r = & $drv.summon; & $step 'summon' $r; if (-not $r) { return (& $done $false '没能把软件叫过来') }
  # 2) 打开聊天：列表里看得到就点；看不到就用搜索框（输入聊天名，回车）
  $st = & $drv.read; $opened = $false
  if (-not (Same2 $st.title $conv)) {
    $row = @($st.rows | Where-Object { Same2 $_.name $conv }) | Select-Object -First 1
    if ($row) { & $drv.clickRow $row; $opened = $true; & $step 'click_list' $true }
    elseif ($drv.search) { $ok = & $drv.search $conv; & $step 'search' $ok; $opened = $ok }
    else { & $step 'find' $false; return (& $done $false '没找到这个聊天') }
    Start-Sleep -Milliseconds $drv.settleMs
    $st = & $drv.read
  } else { & $step 'already_open' $true }
  # 3) 核对标题：对不上就停，不乱猜
  if (-not (Same2 $st.title $conv)) { & $step 'verify_title' $false; if ($drv.cancelSearch) { & $drv.cancelSearch }; return (& $done $false '没找到这个聊天') }
  & $step 'verify_title' $true
  # 4) 翻到那条消息：最多往上翻 10 次（用原话的前几个字找）
  $q = ([string]$item.quote -replace '\s', ''); if ($q.Length -gt 8) { $q = $q.Substring(0, 8) }
  $found = $false
  if ($q) { for ($i = 0; $i -le 10; $i++) { if (@($st.msgs | Where-Object { ($_ -replace '\s', '').Contains($q) }).Count) { $found = $true; break }; if ($i -eq 10) { break }; & $drv.scrollUp; Start-Sleep -Milliseconds 200; $st = & $drv.read } }
  & $step 'scroll_to_message' $found
  # 5) 光标放进输入框（不打字、不发送）
  $ok = & $drv.focusInput; & $step 'focus_input' $ok
  & $done $true $(if ($found) { '' } else { '已打开聊天，那条消息不在最近几屏里' })
}
function Write-JumpLog($res, [string]$app) { try { [IO.File]::AppendAllLines((Join-Path $script:V2Data 'jump_log.jsonl'), [string[]]@((@{ ts = (Get-Date).ToString('s'); app = $app; ok = $res.ok; steps = $res.steps } | ConvertTo-Json -Depth 4 -Compress)), (New-Object Text.UTF8Encoding $false)) } catch {} }

# —— 真实微信的驱动：叫过来用现有的 Move-WeChatHere；读界面用现有的 Read-WeChat；点击用窗口消息（不动用户的鼠标）；输入用 SendInput（此时微信在前台）——
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class JumpIn {
  [StructLayout(LayoutKind.Sequential)] struct KI { public ushort vk, scan; public uint flags, time; public IntPtr extra; public uint p1, p2; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public KI ki; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int size);
  [DllImport("user32.dll", EntryPoint = "PostMessageW")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
  public static void Text(string s) { foreach (char c in s) { var a = new INPUT[2]; a[0].type = 1; a[0].ki.scan = c; a[0].ki.flags = 4; a[1].type = 1; a[1].ki.scan = c; a[1].ki.flags = 6; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); System.Threading.Thread.Sleep(15); } }
  public static void Key(ushort vk) { var a = new INPUT[2]; a[0].type = 1; a[0].ki.vk = vk; a[1].type = 1; a[1].ki.vk = vk; a[1].ki.flags = 2; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
  // 滚轮：WM_MOUSEWHEEL 的坐标是屏幕坐标
  public static void Wheel(IntPtr h, int x, int y, int delta) { var p = new POINT { X = x, Y = y }; ClientToScreen(h, ref p); PostMessage(h, 0x020A, (IntPtr)((delta & 0xFFFF) << 16), (IntPtr)(((p.Y & 0xFFFF) << 16) | (p.X & 0xFFFF))); }
}
'@
function New-WeChatJumpDriver {
  $d = @{ settleMs = 900; h = [IntPtr]::Zero; lay = $null }
  $d.summon = { $r = Move-WeChatHere; if ($r.ok) { $p = Get-Process Weixin -ErrorAction SilentlyContinue; $d.h = [WxWin]::FindMain([uint32[]]$p.Id); Start-Sleep -Milliseconds 400 }; [bool]$r.ok }.GetNewClosure()
  $d.read = { $h = $d.h; $wr = [WinTools]::Rect($h); $b = [Rec]::Window($h, $wr.R - $wr.L, $wr.B - $wr.T); $d.lay = [Rec]::Layout($b); $d.dpi = [WinTools]::Dpi($h) / 96.0; $d.w = $b.Width; $d.ht = $b.Height
    $script:KeepImages = $false; $x = Read-WeChat $h $b; $b.Dispose()
    @{ title = [string]$x.会话; rows = @($x.列表 | ForEach-Object { @{ name = [string]$_.会话; x = $_.点X; y = $_.点Y } }); msgs = @($x.消息 | ForEach-Object { [string]$_.文本 }) } }.GetNewClosure()
  $d.clickRow = { param($row) [Rec]::Click($d.h, [int]$row.x, [int]$row.y) }.GetNewClosure()
  # 搜索框：会话列表顶部（导航栏右侧、列表区上方）；点一下 → 输入聊天名 → 回车
  $d.search = { param($name) $cl = [int]($d.w * $d.lay[0]); $nav = [int](60 * $d.dpi)
    [Rec]::Click($d.h, [int](($nav + $cl) / 2), [int](32 * $d.dpi)); Start-Sleep -Milliseconds 300; [JumpIn]::Text($name); Start-Sleep -Milliseconds 700; [JumpIn]::Key(0x0D); $true }.GetNewClosure()
  $d.cancelSearch = { [JumpIn]::Key(0x1B) }   # 打开的不是要找的聊天：Esc 退出搜索，什么都不动
  $d.scrollUp = { $cl = [int]($d.w * $d.lay[0]); $ct = [int]($d.ht * $d.lay[1]); $cb = [int]($d.ht * $d.lay[2]); [JumpIn]::Wheel($d.h, [int](($cl + $d.w) / 2), [int](($ct + $cb) / 2), 360) }.GetNewClosure()
  # 输入框：聊天区下面那一块的中间
  $d.focusInput = { $cl = [int]($d.w * $d.lay[0]); $cb = [int]($d.ht * $d.lay[2]); [Rec]::Click($d.h, [int](($cl + $d.w) / 2), [int](($cb + $d.ht) / 2)); $true }.GetNewClosure()
  $d
}
# 用户点「去回复」：找到那条事项，按来源选驱动（目前：微信；其它软件等适配里有搜索框/输入框区域后接上）
function Start-ReplyJump([string]$id) {
  $it = @(Get-Today) | Where-Object { $_.id -eq $id } | Select-Object -First 1; if (-not $it) { return @{ ok = $false; text = '这条事项已经不在了' } }
  if ($it.src -ne '微信') { return @{ ok = $false; text = "「$($it.src)」还不支持一键去回复" } }
  $res = Invoke-ReplyJump $it (New-WeChatJumpDriver); Write-JumpLog $res '微信'; $res
}
