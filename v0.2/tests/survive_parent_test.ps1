# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 秘书会不会跟着「把它叫起来的程序」一起被关：这个测试进程先把自己放进一个「关掉就杀光里面所有进程」的作业（和 Claude Code 一样），
# 在里面用 重启秘书.ps1 重启秘书，再顺手开一个普通子进程做对照；然后测试进程退出（作业关闭）。对照的子进程应该被杀，秘书应该还在。
param([switch]$Inner)
$v2 = Split-Path $PSScriptRoot -Parent; $out = Join-Path $env:TEMP 'survive_parent_test.txt'
if ($Inner) {
  Add-Type 'using System; using System.Runtime.InteropServices; public static class KJ { [StructLayout(LayoutKind.Sequential)] public struct BASIC { public long a, b; public uint LimitFlags; public UIntPtr c, d; public uint e; public UIntPtr f; public uint g, h; } [StructLayout(LayoutKind.Sequential)] public struct IO { public ulong a, b, c, d, e, f; } [StructLayout(LayoutKind.Sequential)] public struct EXT { public BASIC Basic; public IO Io; public UIntPtr p, j, pp, pj; } [DllImport("kernel32.dll")] public static extern IntPtr CreateJobObject(IntPtr a, string n); [DllImport("kernel32.dll")] public static extern bool SetInformationJobObject(IntPtr j, int c, ref EXT i, uint n); [DllImport("kernel32.dll")] public static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p); [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    public static bool Make() { var j = CreateJobObject(IntPtr.Zero, null); var e = new EXT(); e.Basic.LimitFlags = 0x2000; if (!SetInformationJobObject(j, 9, ref e, (uint)Marshal.SizeOf(typeof(EXT)))) return false; return AssignProcessToJobObject(j, GetCurrentProcess()); } }'
  $ok = [KJ]::Make(); Add-Content $out "inner job made: $ok"
  $ctl = Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', 'Start-Sleep 300' -PassThru; Add-Content $out "control pid: $($ctl.Id)"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $v2 'tools\重启秘书.ps1') | Out-Null; Start-Sleep 20
  Add-Content $out 'inner exiting (job closes now)'; exit
}
Remove-Item $out -ErrorAction SilentlyContinue
$p = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Inner' -PassThru -WindowStyle Hidden; $p.WaitForExit(); Start-Sleep 5
$lines = Get-Content $out; $lines
$ctlId = [int](($lines | Where-Object { $_ -like 'control pid:*' }) -replace '\D', '')
$sec = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'v0.2\\秘书\.ps1' })
"control child killed with the job: $(-not (Get-Process -Id $ctlId -ErrorAction SilentlyContinue))"
"secretary still running after the job closed: $($sec.Count -ge 1)"
