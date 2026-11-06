# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
. "$PSScriptRoot\lib_synthetic_test.ps1"
. "$v2\lib_v2.ps1"; . "$v2\lib_商店.ps1"
Import-TestFunctions "$productRoot\12_值守.ps1" @('Watch-Plugins')
$testDir=Join-Path $env:TEMP ('secretary_plugin_'+[guid]::NewGuid().ToString('n'));[void][IO.Directory]::CreateDirectory("$testDir\adapters");$script:V2Data=$testDir
function Get-Permission($p){$true};function Get-PluginProcs($name){@([pscustomobject]@{Id=98765})};function Get-PluginWindow($ps){[IntPtr]1}
$script:ReadText="sample1`nsample2";function Invoke-PluginAction($id,$action){@{ok=$true;data=@{text=$script:ReadText}}}
$stats=@{错误=0};$script:Saved=0;function Save-Messages($c,$m,$b,$app){$script:Saved+=@($m).Count}
$script:PlugLast=@{};$script:PlugFail=@{};$script:PlugTxt=@{}
try{
 $d="$testDir\adapters\sample-plugin";[void][IO.Directory]::CreateDirectory("$d\local_backup")
 [IO.File]::WriteAllText("$d\script.json",'{"actions":{"read_open_chat":[{"op":"find_window"},{"op":"read_region","region":"message_area","as":"text"},{"op":"emit","field":"text"}]}}')
 [IO.File]::WriteAllText("$d\local_backup\synthetic.json",'{"proc":"synthetic"}')
 [IO.File]::WriteAllText("$d\installed.json",(@{id='sample-plugin';version='1.0.0';source='store';app_process='synthetic.exe';app='synthetic';name='synthetic';enabled=$true;withdrawn=$false;backup="$d\local_backup"}|ConvertTo-Json))
 Watch-Plugins;Check 'synthetic plugin data reaches storage' ($script:Saved -eq 2)
 $script:PlugLast=@{};Watch-Plugins;Check 'duplicate snapshot does not re-enter storage' ($script:Saved -eq 2)
 $script:ReadText='';1..3|ForEach-Object{$script:PlugLast=@{};Watch-Plugins};Check '3 empty reads mark adapter broken' (Test-Path "$d\broken.json")
 $repair=Repair-PluginRead 'sample-plugin' 'watch';$inf=Get-InstalledPlugins|Select-Object -First 1
 Check 'broken adapter disabled and local backup restored' (-not $inf.enabled -and $repair.restored -and (Test-Path "$testDir\adapters\synthetic.json"))
 $before=[int]$stats.插件读空;$script:PlugLast=@{};Watch-Plugins;Check 'disabled adapter not polled' ([int]$stats.插件读空 -eq $before)
 Check 'no errors' ($stats.错误 -eq 0)
}finally{if([IO.Path]::GetFullPath($testDir).StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $testDir -Recurse -Force}}
Done-Test
