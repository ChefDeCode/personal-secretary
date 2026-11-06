# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
. "$PSScriptRoot\lib_synthetic_test.ps1"
Import-TestFunctions "$productRoot\12_值守.ps1" @('Watch-Edge')
Import-TestFunctions "$v2\lib_网页读.ps1" @('ConvertTo-SiteHost','Test-SiteAllowed')
$root=Join-Path $env:TEMP ('secretary_web_'+[guid]::NewGuid().ToString('n'));[void][IO.Directory]::CreateDirectory($root)
function Set-TestCfg($on,$sites){[IO.File]::WriteAllText("$root\config.json",(@{features=@{watch_edge=$on};edge_sites=@($sites)}|ConvertTo-Json))}
function Get-EdgeWindow {[IntPtr]1}
function Read-EdgeUia($h,$sites){@{allowed=(Test-SiteAllowed 'https://work.example.com/tasks' $sites);url_host='work.example.com';lines=@('sample1','sample2','sample3')}}
function Invoke-GhostRead($h,$read){if($script:Blocked){return @{ok=$false}};@{ok=$true;value=(& $read)}}
function Save-Messages($c,$m,$b,$app){$script:Saved+=@($m).Count;$script:Source=$app}
$stats=@{错误=0};$script:Saved=0;$script:EdgeSig='';$script:Blocked=$false
try{
 Set-TestCfg $false @('example.com');$script:EdgeLast=[datetime]::MinValue;Watch-Edge;Check 'disabled source does not read' ($script:Saved -eq 0)
 Set-TestCfg $true @('other.org');$script:EdgeLast=[datetime]::MinValue;Watch-Edge;Check 'unlisted source stores nothing' ($script:Saved -eq 0)
 Set-TestCfg $true @('example.com');$script:EdgeLast=[datetime]::MinValue;Watch-Edge;Check '3 synthetic lines enter storage' ($script:Saved -eq 3 -and $script:Source -eq 'Edge')
 $script:EdgeLast=[datetime]::MinValue;Watch-Edge;Check 'unchanged page not duplicated' ($script:Saved -eq 3)
 $script:Blocked=$true;$script:EdgeSig='';$script:EdgeLast=[datetime]::MinValue;Watch-Edge;Check 'blocked read stores nothing' ($script:Saved -eq 3)
 Check 'no errors' ($stats.错误 -eq 0)
}finally{if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force}}
Done-Test
