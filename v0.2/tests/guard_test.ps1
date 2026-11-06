# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
. "$PSScriptRoot\lib_synthetic_test.ps1"
# Compile a pure in-memory input backend. No user32 entry point exists in this test.
Add-Type @'
using System;
public class TestAbort : Exception { public TestAbort(string s):base(s){} }
public static class TIn { public static int Sent; public static uint OurLast; public static uint Input=0; public static uint ForegroundPid=22; public static uint TopPid=22;
 public struct P{public int X,Y;} public static IntPtr RootAt(int x,int y){return new IntPtr(TopPid);} public static uint PidOf(IntPtr h){return (uint)h.ToInt64();} public static string ClassOf(IntPtr h){return "Synthetic";}
 public static bool ShowWindow(IntPtr h,int c){TopPid=11;return true;} public static IntPtr GetForegroundWindow(){return new IntPtr(ForegroundPid);} public static uint LastInput(){return Input;}
 public static bool GetCursorPos(out P p){p=new P();return true;} public static void RawClick(int x,int y,bool r){Sent+=2;} public static void RawKey(ushort k){Sent+=2;} public static void RawText(string s){Sent+=s.Length*2;}
}
'@
Import-TestFunctions "$PSScriptRoot\lib_测试输入.ps1" @('Assert-NoUserInput','Assert-OursAt','Invoke-TestClick','Invoke-TestClickElement','Assert-OursForeground','Send-TestKey','Restore-MovedWindows')
function Get-OurPids { @(11) }
$script:MovedWindows=New-Object 'Collections.Generic.List[IntPtr]';$script:ShellClasses=@('Shell');$script:TestNoMove=$true;$script:WatchOn=$false
try{
 $threw=$false;try{Invoke-TestClick 1 1}catch [TestAbort]{$threw=$true};Check 'foreign synthetic window blocks all input' ($threw -and [TIn]::Sent -eq 0)
 $threw=$false;try{Invoke-TestClickElement $null}catch [TestAbort]{$threw=$true};Check 'missing element blocks input' ($threw -and [TIn]::Sent -eq 0)
 $threw=$false;try{Send-TestKey 27}catch [TestAbort]{$threw=$true};Check 'foreign foreground blocks key' ($threw -and [TIn]::Sent -eq 0)
 [TIn]::ForegroundPid=11;Send-TestKey 27;Check 'registered foreground permits synthetic key only' ([TIn]::Sent -eq 2)
 $script:WatchOn=$true;[TIn]::OurLast=0;[TIn]::Input=900;$threw=$false;try{Send-TestKey 27}catch [TestAbort]{$threw=$true};Check 'new user input aborts before backend' ($threw -and [TIn]::Sent -eq 2)
}finally{Restore-MovedWindows}
Done-Test
