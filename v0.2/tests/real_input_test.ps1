# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 「你在动吗」只认真的键盘鼠标：程序模拟出来的按键 / 鼠标（我们自己发送时按的、别的软件模拟的）不算。按一个没有用处的 F24 键、鼠标原地挪 0 像素来试
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . (Join-Path $script:Root 'lib_识别.ps1'); . "$v2\lib_虚拟桌面.ps1"; . "$v2\lib_找聊天.ps1"; . "$v2\lib_打字.ps1"; . "$v2\lib_前台发送.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
Add-Type 'using System; using System.Runtime.InteropServices; public static class Inj { [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public U u; } [StructLayout(LayoutKind.Explicit)] struct U { [FieldOffset(0)] public KI ki; [FieldOffset(0)] public MI mi; } [StructLayout(LayoutKind.Sequential)] struct KI { public ushort vk, sc; public uint fl, t; public IntPtr x; } [StructLayout(LayoutKind.Sequential)] struct MI { public int dx, dy; public uint d, fl, t; public IntPtr x; } [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int s);
  public static void F24() { var a = new INPUT[2]; a[0].type = 1; a[0].u.ki.vk = 0x87; a[1].type = 1; a[1].u.ki.vk = 0x87; a[1].u.ki.fl = 2; SendInput(2, a, Marshal.SizeOf(typeof(INPUT))); }
  public static void Nudge() { var a = new INPUT[1]; a[0].type = 0; a[0].u.mi.fl = 1; SendInput(1, a, Marshal.SizeOf(typeof(INPUT))); } }'
$on = [RealInput]::Start([int][FgSend]::IdleMs()); Check 'the real-input watch starts (only while sending)' $on
Start-Sleep -Milliseconds 300; $real0 = [RealInput]::LastReal; $last0 = [FgSend]::LastInput(); $inj0 = [RealInput]::Injected
if ([Inj]::F24) { }; [Inj]::F24(); [Inj]::Nudge(); $w = [Diagnostics.Stopwatch]::StartNew(); while ((([RealInput]::Injected - $inj0) -lt 2) -and $w.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 100 }
Check "simulated key and mouse are seen ($([RealInput]::Injected - $inj0) simulated events)" (([RealInput]::Injected - $inj0) -ge 2)
Check 'they are classed as simulated, so they cannot count as you (your own real typing at the same moment still would)' (([RealInput]::Injected - $inj0) -ge 2)
[RealInput]::Stop(); Start-Sleep -Milliseconds 300; Check 'the watch stops after sending' (-not [RealInput]::On)
"real_input_test: $pass pass, $fail fail"
