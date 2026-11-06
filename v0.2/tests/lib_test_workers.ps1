# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# Actual runspace pipeline, with only source paths and input catalogue replaced by synthetic fixtures.
. (Join-Path $v2 'lib_后台任务.ps1')
$script:TestAppRoot=$v2
$script:TestWorkerFixture=Join-Path $T 'worker-fixture.ps1'
$assignments=New-Object Collections.Generic.List[string]
foreach($name in @('Root','DataDir','V2Data','CfgPath','ChatFile','ChatArchive','SummaryFile','ActDir','PeopleFile','AttData','FileIdxFile','FileStatsFile','MemDir','MemMsgFile','MemChatFile','RemDir')){
 $value=Get-Variable -Name $name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
 if($null -ne $value){$assignments.Add('$script:'+$name+" = '"+([string]$value).Replace("'","''")+"'")}
}
$sources=(Get-PeopleSources)|ConvertTo-Json -Depth 20 -Compress
$assignments.Add('$script:SyntheticSources = '+"'"+$sources.Replace("'","''")+"' | ConvertFrom-Json")
$assignments.Add('function Get-PeopleSources { $script:SyntheticSources }')
$assignments.Add('function Get-ConvNames { @($script:SyntheticSources.chats | ForEach-Object title) }')
$assignments.Add('function Get-Switch([string]$key) { $key -in @(''send_messages'',''cloud_text'') }')
[IO.File]::WriteAllLines($script:TestWorkerFixture,$assignments,[Text.UTF8Encoding]::new($true))
function Get-ReadWorkerModules { @((Join-Path $script:TestAppRoot 'lib_v2.ps1'),$script:TestWorkerFixture) }
