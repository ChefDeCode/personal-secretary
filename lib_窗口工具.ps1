# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_窗口工具.ps1 — 07/08/10 共用的窗口辅助函数（只操作本进程自己创建的覆盖窗口）
# 加载时把本进程设为 Per-Monitor DPI aware V2：否则在 200% 缩放屏上拿到的是被系统虚拟化（缩小一半）的坐标，
# 覆盖窗口会错位，PrintWindow 也只能拿到半分辨率画面。必须在创建任何窗口之前调用。
Add-Type @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;

[ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktopManager {
  [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr hwnd, out bool onCurrent);
  [PreserveSig] int GetWindowDesktopId(IntPtr hwnd, out Guid desktopId);
  [PreserveSig] int MoveWindowToDesktop(IntPtr hwnd, ref Guid desktopId);
}

public static class WinTools {
  public delegate bool CB(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out R r, int size);
  public static bool EnablePerMonitorDpi() { try { return SetProcessDpiAwarenessContext((IntPtr)(-4)); } catch { return false; } }
  public class RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] struct R { public int L,T,R_,B; }
  [DllImport("user32.dll", EntryPoint="GetWindowRect")] static extern bool GetRect(IntPtr h, out R r);

  static IVirtualDesktopManager vdm;
  static IVirtualDesktopManager Vdm { get {
    if (vdm == null) try { vdm = (IVirtualDesktopManager)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a"))); } catch {}
    return vdm; } }

  // 可见边界（物理像素）：DWMWA_EXTENDED_FRAME_BOUNDS 不含 Win10/11 窗口四周不可见的缩放边框
  public static RECT Rect(IntPtr h) { R r;
    if (DwmGetWindowAttribute(h, 9, out r, 16) != 0 && !GetRect(h, out r)) return null;
    return new RECT { L = r.L, T = r.T, R = r.R_, B = r.B }; }
  public static uint Dpi(IntPtr h) { try { var d = GetDpiForWindow(h); return d == 0 ? 96 : d; } catch { return 96; } }

  public static IntPtr LargestVisibleWindow(uint[] pids) {
    IntPtr best = IntPtr.Zero; long area = 0;
    EnumWindows((h,l) => { uint pid; GetWindowThreadProcessId(h, out pid); R r;
      if (Array.IndexOf(pids, pid) >= 0 && IsWindowVisible(h) && GetRect(h, out r)) { long a = (long)(r.R_-r.L)*(r.B-r.T); if (a > area) { area = a; best = h; } }
      return true; }, IntPtr.Zero);
    return best; }

  // 覆盖窗口：分层 + 鼠标穿透 + 不激活
  // allDesktops=true 时加 WS_EX_TOOLWINDOW：工具窗口不归属任何虚拟桌面（desktop id 为空），会出现在所有桌面上——适合边缘线；
  // 边框必须只在微信所在桌面，所以不加 TOOLWINDOW，才能被 MoveWindowToDesktop 挪过去
  [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
  // 把本进程的覆盖窗口设为“被目标窗口拥有”（只改我们自己窗口的属性）：被拥有的窗口跟随拥有者所在的虚拟桌面、
  // 不进任务栏，拥有者最小化时一起隐藏——正好是“边框只出现在微信所在桌面”需要的行为
  public static void SetOwner(IntPtr me, IntPtr owner) { SetWindowLongPtr(me, -8, owner); }
  [DllImport("user32.dll", EntryPoint = "PostMessageW")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  // 向窗口投递滚轮（delta>0 向上），坐标为屏幕坐标；不移动真实鼠标
  public static void PostWheel(IntPtr h, int delta, int sx, int sy) {
    PostMessage(h, 0x020A, (IntPtr)((delta & 0xFFFF) << 16), (IntPtr)(((sy & 0xFFFF) << 16) | (sx & 0xFFFF))); }

  // ---- 边框实时跟随：监听目标窗口的位置变化事件（只读的系统事件订阅），在回调里一次 SetWindowPos 完成移动+缩放 ----
  delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObj, int idChild, uint thread, uint time);
  [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
  [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
  [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public R rcMonitor; public R rcWork; public uint dwFlags; }
  static WinEventProc followProc, dragProc; static IntPtr followHook, dragHook; static IntPtr fMe, fTarget; static int fPadDip;
  // 用户正在拖动/缩放目标窗口（EVENT_SYSTEM_MOVESIZESTART..END）；期间边框淡出，松手后在新位置淡入
  public static volatile bool Dragging;

  // 把覆盖窗口摆到“目标窗口外扩 pad，并与目标所在显示器工作区求交”的位置（物理像素，一次调用）
  public static bool Place(IntPtr me, IntPtr target, int padDip) {
    var r = Rect(target); if (r == null || IsIconic(target)) return false;
    int pad = (int)(padDip * Dpi(target) / 96.0);
    var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(mi);
    GetMonitorInfo(MonitorFromWindow(target, 2), ref mi);
    int l = Math.Max(r.L - pad, mi.rcWork.L), t = Math.Max(r.T - pad, mi.rcWork.T);
    int rr = Math.Min(r.R + pad, mi.rcWork.R_), b = Math.Min(r.B + pad, mi.rcWork.B);
    // SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER
    return SetWindowPos(me, IntPtr.Zero, l, t, rr - l, b - t, 0x0010 | 0x0004 | 0x0200); }

  public static void StartFollow(IntPtr me, IntPtr target, int padDip) {
    fMe = me; fTarget = target; fPadDip = padDip;
    uint pid; GetWindowThreadProcessId(target, out pid);
    followProc = (hk, ev, hwnd, idObj, idChild, th, tm) => { if (hwnd == fTarget && idObj == 0) Place(fMe, fTarget, fPadDip); };
    // EVENT_OBJECT_LOCATIONCHANGE(0x800B)，WINEVENT_OUTOFCONTEXT(0)：回调在本线程的消息循环里执行
    followHook = SetWinEventHook(0x800B, 0x800B, IntPtr.Zero, followProc, pid, 0, 0);
    // EVENT_SYSTEM_MOVESIZESTART(0x000A) / MOVESIZEEND(0x000B)
    dragProc = (hk, ev, hwnd, idObj, idChild, th, tm) => { if (hwnd != fTarget) return;
      if (ev == 0x000A) Dragging = true; else { Dragging = false; Place(fMe, fTarget, fPadDip); } };
    dragHook = SetWinEventHook(0x000A, 0x000B, IntPtr.Zero, dragProc, pid, 0, 0);
    Place(me, target, padDip); }
  public static void StopFollow() {
    if (followHook != IntPtr.Zero) UnhookWinEvent(followHook); if (dragHook != IntPtr.Zero) UnhookWinEvent(dragHook);
    followHook = dragHook = IntPtr.Zero; }
  // clickThrough=false：去掉 WS_EX_TRANSPARENT，窗口里完全透明的像素仍然点不中（分层窗口按像素透明度命中），只有画出来的部分可点
  public static void MakeOverlay(IntPtr me, bool allDesktops) { MakeOverlay(me, allDesktops, true); }
  public static void MakeOverlay(IntPtr me, bool allDesktops, bool clickThrough) {
    int ex = GetWindowLong(me, -20) | 0x80000 | 0x08000000;
    if (clickThrough) ex |= 0x20; else ex &= ~0x20;
    ex = allDesktops ? (ex | 0x80) : (ex & ~0x80);
    SetWindowLong(me, -20, ex); }

  // 诊断用：窗口所在桌面 id，以及是否在用户当前桌面
  public static string DesktopInfo(IntPtr h) {
    var v = Vdm; if (v == null) return "VDM 不可用"; Guid g; bool on;
    int r1 = v.GetWindowDesktopId(h, out g); int r2 = v.IsWindowOnCurrentVirtualDesktop(h, out on);
    return string.Format("desk={0} (hr={1:X}) 在当前桌面={2} (hr={3:X})", g, r1, on, r2); }

  // 让覆盖窗口待在目标窗口所在的桌面；返回 true 表示已与目标同桌面（调用方据此决定是否显示）
  public static bool FollowDesktop(IntPtr me, IntPtr target) {
    var v = Vdm; if (v == null) return true; Guid t, m;
    if (v.GetWindowDesktopId(target, out t) != 0 || t == Guid.Empty) return true;   // 取不到就不限制
    if (v.GetWindowDesktopId(me, out m) == 0 && m == t) return true;
    v.MoveWindowToDesktop(me, ref t);
    return v.GetWindowDesktopId(me, out m) == 0 && m == t; }

  // 让覆盖窗口始终出现在“当前”桌面（公开接口无法“固定到所有桌面”，所以跟随前台窗口所在的桌面）
  public static void FollowCurrentDesktop(IntPtr me) {
    var v = Vdm; if (v == null) return; bool on;
    if (v.IsWindowOnCurrentVirtualDesktop(me, out on) == 0 && on) return;
    var fg = GetForegroundWindow(); Guid d;
    if (fg != IntPtr.Zero && fg != me && v.GetWindowDesktopId(fg, out d) == 0 && d != Guid.Empty) v.MoveWindowToDesktop(me, ref d); }
}
'@

[void][WinTools]::EnablePerMonitorDpi()

# 值守状态文件：{"litUntil": <Unix 毫秒>}。值守脚本读取时把 litUntil 推到“现在 + 几秒”，边缘线/边框据此亮灭
function Test-Lit([string]$stateFile) {
  try { $s = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json; return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt [long]$s.litUntil } catch { return $false }
}
function Set-Lit([string]$stateFile, [int]$seconds) {
  $until = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $seconds * 1000
  [IO.File]::WriteAllText($stateFile, "{`"litUntil`": $until}", (New-Object Text.UTF8Encoding $false))
}

# 权限开关：config.json 的 "permissions"。缺省值即用户批准的默认；type_or_send 在本原型里锁定为 false，无论配置如何
$script:PermDefaults = [ordered]@{ read_screen = $true; scroll = $true; click_sessions = $true; cloud_images = $true; cloud_text = $true; type_or_send = $false }
$script:PermLabels = [ordered]@{
  read_screen    = '在后台截图读取微信窗口'
  scroll         = '在后台滚动聊天记录'
  click_sessions = '点击会话列表，进入有未读的会话读取'
  cloud_images   = '把聊天里的图片发给 Claude 看图'
  cloud_text     = '把新消息文字发给 Claude 整理今天清单'
  type_or_send   = '输入或发送消息（本原型锁定为关）'
}
# 功能开关：config.json 的 "features"，默认全开；关掉后对应功能在下一轮（≤1 秒到几秒）停止，不影响其它功能
$script:FeatDefaults = [ordered]@{ autostart = $false; watch_wechat = $true
                                   border = $true; today_list = $true; image_describe = $true; save_attachments = $true; long_memory = $true; watcher = $true; paused = $false; proactive = $true }
$script:FeatLabels = [ordered]@{
  autostart        = '开机自动启动秘书（只在你自己打开 设置 → 开机自动启动 时才放快捷方式）'
  watch_wechat     = '值守微信'
  border           = '借用微信时的边框'
  today_list       = '整理今天清单'
  image_describe   = '看图（识别聊天里的图片内容）'
  save_attachments = '记下图片和文件（本机有的记位置，没有的截图加密存下）'
  long_memory      = '记住长期记忆（人、答应的事、偏好、决定；每条有出处）'
  watcher          = '值守（自动读取）：秘书开着时在后台读已接入的软件'
  paused           = '暂时暂停读取（托盘里点的，重启秘书后恢复）'
  proactive        = '主动提醒（到期、答应的事、等你回复、早上简报）'
}
function Get-Feature([string]$name) {
  try { $v = (Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).features.$name; if ($null -ne $v) { return [bool]$v } } catch {}
  [bool]$script:FeatDefaults[$name]
}

function Get-Permission([string]$name) {
  if ($name -eq 'type_or_send') { return $false }
  try { $v = (Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).permissions.$name; if ($null -ne $v) { return [bool]$v } } catch {}
  [bool]$script:PermDefaults[$name]
}

# 秘书名字：读 config.json 的 "name"，缺省“秘书”
$script:CfgPath = Join-Path $PSScriptRoot 'config.json'
function Get-SecretaryName {
  try { $n = (Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).name; if ($n) { return [string]$n } } catch {}
  '秘书'
}