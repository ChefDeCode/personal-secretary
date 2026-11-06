# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 合成集成测试：真正的主程序函数/后台函数，所有数据、配置和窗口均为测试替身。
$ErrorActionPreference='Stop'
$v2=Split-Path $PSScriptRoot -Parent
$script:pass=0;$script:fail=0
function Check([string]$Name,[bool]$Ok){if($Ok){$script:pass++}else{$script:fail++};'[{0}] {1}' -f $(if($Ok){'PASS'}else{'FAIL'}),$Name}
# Preserve complete function definitions, including param clauses preceding the body.
$mainAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 '秘书.ps1'),[ref]$null,[ref]$null)
$needed=@('Get-ReadWorkerModules','Request-ReadSnapshot','Watch-Watcher','Sync-Watcher','Tick-Memory','Finish-MemReflect','Tick-Proactive','Step-Events','Start-Claude','Convert-BackgroundValue')
foreach($fn in $mainAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $needed -contains $n.Name},$true)){. ([scriptblock]::Create($fn.Extent.Text))}
. (Join-Path $v2 'lib_主后台.ps1')
$chatAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 'lib_v2.ps1'),[ref]$null,[ref]$null)
$chatViewFunction=($chatAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ChatViewItems'},$true)|Select-Object -First 1).Extent.Text
. ([scriptblock]::Create($chatViewFunction))
$providerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 'lib_AI源.ps1'),[ref]$null,[ref]$null)
$fn=$providerAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-ProviderBody'},$true)|Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
$testRoot=Join-Path $env:TEMP ('secretary_integration_'+[guid]::NewGuid().ToString('n'))
$script:Root=$testRoot;$script:DataDir=Join-Path $testRoot 'data';$script:V2Data=Join-Path $testRoot 'v0.2\data';$script:MemDir=$script:V2Data
[void][IO.Directory]::CreateDirectory($script:DataDir);[void][IO.Directory]::CreateDirectory($script:V2Data)
$script:MemMsgFile=Join-Path $script:DataDir 'messages.jsonl';$script:MemChatFile=Join-Path $script:V2Data 'chat_archive.jsonl'
$script:jobs=New-Object System.Collections.ArrayList;$script:posts=New-Object System.Collections.ArrayList;$script:miniPosts=New-Object System.Collections.ArrayList;$script:providerBodies=New-Object System.Collections.ArrayList
$script:counts=@{settings=0;cim=0;material=0;apply=0;reminders=0;save=0;cooling=0;cost=0}
$script:cfg=@{ui_theme='dark';dnd=$true};$script:features=@{watcher=$true;long_memory=$true;proactive=$true};$script:pending=@{}
$script:form=[pscustomobject]@{Visible=$true;WindowState='Normal'};$script:miniOpen=$true;$script:quitting=$false
function Start-SecWork {param($Key,$Code,$InputObject,[string[]]$Modules,[scriptblock]$Then,[int]$TimeoutMs,[switch]$Replace);[void]$script:jobs.Add(@{key=$Key;code=$Code;input=$InputObject;modules=$Modules;then=$Then;replace=[bool]$Replace});$true}
function Get-ReadWorkerModules { @() }
function Test-SecWorkPending([string]$Key){[bool]$script:pending[$Key]}
function Post($o){[void]$script:posts.Add($o)}
function Post-MiniRaw($o){[void]$script:miniPosts.Add($o)}
function Show-Notice($text){}
function Write-ErrorLog($ex,$where,$note){}
function Read-Config{$script:cfg}
function Get-Feature([string]$Name){[bool]$script:features[$Name]}
function Get-Permission([string]$Name){$Name -eq 'cloud_text'}
function Unprotect([string]$Text){$Text}
function MemU([string]$Text){$Text}
function MemP([string]$Text){$Text}
function Get-Today{@{id='item-a';group='reply';done=$false;due_bucket='today'};@{id='item-b';group='promise';done=$true;due_bucket='undated'}}
function Get-ActiveReminders{@{id='reply|t:item-a';text='synthetic'}}
function Get-Activity{@{id='act-a';status='queued'}}
function Get-Upcoming{@{date='2030-01-01';items=@()}}
function Get-WaveState{@{state='idle';text='synthetic'}}
function Get-SecretaryName{'synthetic'}
function Get-Settings{$script:counts.settings++;Start-Sleep -Milliseconds 200;@{dnd=$true;theme='dark'}}
function Get-Summary{'synthetic summary'}
function Get-ChatItems{@{id='chat-a';role='ai';text='synthetic'}}
function Get-AppsState{@{id='synthetic';state='closed'}}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction);$script:counts.cim++;Start-Sleep -Milliseconds 200;[pscustomobject]@{CommandLine=('powershell -File "'+(Join-Path $script:Root '12_值守.ps1')+'"')}}
function Test-MemBudget{$true}
$script:memoryState=[pscustomobject]@{msgOff=0;chatOff=0;lastRun=(Get-Date).AddMinutes(-15).ToString('s');read=0}
function Get-MemState{$script:memoryState}
function Save-MemState($s){$script:counts.save++;$script:memoryState=$s}
function Get-MemMaterial{$script:counts.material++;Start-Sleep -Milliseconds 200;@{msgOff=6;chatOff=5;items=@(@{id='msg-a';text='synthetic'})}}
function New-SyntheticBody{@{model='claude-synthetic';max_tokens=10;messages=@(@{role='user';content=@(@{type='text';text='synthetic'})});output_config=@{format=@{schema=@{type='object';properties=@{ok=@{type='boolean'}}}}}}}
function Build-MemRequest($items){New-SyntheticBody}
function Apply-MemResult($result,$items){$script:counts.apply++;Start-Sleep -Milliseconds 200;@{promoted=1;conflicts=0;count=@($items).Count}}
function Add-MemCost($usage){$script:counts.cost++}
function Update-MemCooling{$script:counts.cooling++}
function Start-ProviderAI($body){[void]$script:providerBodies.Add($body);[pscustomobject]@{IsCompleted=$false}}
function Read-Claude($task){@{content=@(@{type='text';text='{"items":[]}'});usage=@{input_tokens=1;output_tokens=1}}}
function Get-AiModel($p){'claude-synthetic'}
function Get-LocalBrief($now){'synthetic brief'}
function Test-PlanDue($now){@{days=@(@{date='2030-01-01'});hash='synthetic-hash'}}
function Build-PlanRequest($days,$now){New-SyntheticBody}
function Build-BriefRequest($now){New-SyntheticBody}
function Get-RemindCfg{@{brief=(Get-Date).ToString('HH:mm')}}
function At($now,$time){Get-Date}
function Invoke-ReminderTick {param($Now,$Brief,[switch]$Dnd);$script:counts.reminders++;$script:lastDnd=[bool]$Dnd;Start-Sleep -Milliseconds 200;@{id='rem-a';important=$true;text='synthetic'}}
function Write-FileAtomic([string]$Path,[string]$Text){if(-not ([IO.Path]::GetFullPath($Path)).StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'test path escaped'};[IO.File]::WriteAllText($Path,$Text)}
function Execute-Job($j){$value=& ([scriptblock]::Create([string]$j.code)) $j.input;$packet=@{ok=$true;data=$value}|ConvertTo-Json -Depth 30 -Compress|ConvertFrom-Json;if($j.then){& $j.then $packet};$packet}
try{
  [IO.File]::WriteAllText((Join-Path $script:V2Data 'reply_preds.json'),'{"item-a":{"opts":["synthetic"],"fallback":false}}')
  [IO.File]::WriteAllText((Join-Path $script:DataDir 'notice.json'),'{"seen":false,"kind":"important"}')
  [IO.File]::WriteAllText((Join-Path $script:V2Data 'edge_pos.json'),'{"side":"left"}')
  $view=Get-BackgroundView @{full=$false}
  Check 'background_view_links_predictions_and_reminder' ($view.today.Count -eq 2 -and $view.today[0].preds.Count -eq 1 -and $view.mini.reminders[0].item.id -eq 'item-a')
  Check 'background_view_filters_done_in_mini' ($view.mini.today.Count -eq 1 -and $view.mini.side -eq 'left' -and $view.mini.dnd)
  Check 'partial_snapshot_skips_expensive_settings' ($script:counts.settings -eq 0 -and -not $view.ContainsKey('chat'))

  $script:ReadView=$null;$script:ReadNext=[datetime]::MinValue;$clock=[Diagnostics.Stopwatch]::StartNew();Request-ReadSnapshot -Full -Force;$clock.Stop()
  $job=$script:jobs[-1]
  Check 'main_snapshot_submits_under100_without_scan' ($clock.ElapsedMilliseconds -lt 100 -and $job.key -eq 'view' -and $script:counts.settings -eq 0)
  $packet=Execute-Job $job
  Check 'main_snapshot_callback_uses_json_data' ($script:counts.settings -eq 1 -and $script:ReadView.today.Count -eq 2 -and $script:CachedSettings.theme -eq 'dark')
  Check 'main_snapshot_renders_both_visible_surfaces' (@($script:posts|Where-Object type -eq 'init').Count -eq 1 -and @($script:miniPosts|Where-Object type -eq 'mini').Count -eq 1)

  [IO.File]::WriteAllText((Join-Path $script:DataDir 'pid'),'123')
  $script:WatchNext=[datetime]::MinValue;$clock.Restart();Watch-Watcher;$clock.Stop();$job=$script:jobs[-1]
  Check 'main_watcher_submits_under100_without_cim' ($clock.ElapsedMilliseconds -lt 100 -and $job.key -eq 'watcher' -and $script:counts.cim -eq 0)
  $packet=Execute-Job $job
  Check 'watcher_queries_only_in_background_body' ($script:counts.cim -eq 1 -and -not $packet.data.restarted)

  [IO.File]::WriteAllText($script:MemMsgFile,'123456');[IO.File]::WriteAllText($script:MemChatFile,'12345')
  [IO.File]::WriteAllText((Join-Path $script:MemDir 'memory_state.json'),'{}')
  $script:MemTask=$null;$script:MemNext=[datetime]::MinValue;$clock.Restart();Tick-Memory;$clock.Stop();$job=$script:jobs[-1]
  Check 'main_memory_read_submits_under100_without_material' ($clock.ElapsedMilliseconds -lt 100 -and $job.key -eq 'memory-read' -and $script:counts.material -eq 0)
  $packet=Execute-Job $job
  Check 'memory_request_crosses_json_boundary' ($script:counts.material -eq 1 -and $script:providerBodies.Count -eq 1)
  $body=$script:providerBodies[-1]
  Check 'background_request_rehydrated_to_dictionary' ($body -is [Collections.IDictionary] -and $body.messages.Count -eq 1)
  $converted=ConvertTo-ProviderBody $body 'anthropic'
  Check 'provider_keeps_messages_after_worker_roundtrip' ($converted.messages.Count -eq 1 -and $converted.max_tokens -eq 10)
  Check 'provider_keeps_nested_schema_after_roundtrip' ($converted.output_config.format.schema.properties.ok.type -eq 'boolean')

  $clock.Restart();Finish-MemReflect;$clock.Stop();$job=$script:jobs[-1]
  Check 'main_memory_apply_submits_under100_without_write' ($clock.ElapsedMilliseconds -lt 100 -and $job.key -eq 'memory-apply' -and $script:counts.apply -eq 0)
  $packet=Execute-Job $job
  Check 'memory_apply_commits_offsets_after_result' ($script:counts.apply -eq 1 -and $script:memoryState.msgOff -eq 6 -and $script:memoryState.chatOff -eq 5 -and $script:memoryState.read -eq 1)
  Check 'memory_apply_preserves_usage_and_cooling' ($script:counts.cost -eq 1 -and $script:counts.cooling -eq 1)

  $script:PlanTask=$null;$script:BriefTask=$null;$script:RemNext=[datetime]::MinValue;$clock.Restart();Tick-Proactive;$clock.Stop();$job=$script:jobs[-1]
  Check 'main_proactive_submits_under100_without_read' ($clock.ElapsedMilliseconds -lt 100 -and $job.key -eq 'reminders' -and $script:counts.reminders -eq 0)
  $packet=Execute-Job $job
  Check 'background_proactive_keeps_existing_dnd' ($script:counts.reminders -eq 1 -and $script:lastDnd -and $packet.data.sent -eq 1)
  Check 'proactive_plan_and_brief_survive_json' ($script:providerBodies.Count -eq 3 -and $script:PlanTask -and $script:BriefTask)
  Check 'proactive_notice_written_only_to_fixture' ((Get-Content -LiteralPath (Join-Path $script:DataDir 'notice.json') -Raw|ConvertFrom-Json).kind -eq 'important')

  # Event collection may prepare data, while action dispatch remains in the UI callback.
  $script:eventReads=0;$script:eventChoices=0;$script:eventBodyChoices=0;$script:eventBodyActive=$false;$script:eventSeen=New-Object Collections.ArrayList
  function Get-NewEvents {$script:eventReads++;Start-Sleep -Milliseconds 200;@{key='event-a';类型='叫你做事';原文时间='2030-01-01T10:00:00';事情='synthetic';conv='synthetic'}}
  function Build-EventCard($e){@{kind='event';card=@{kind='event';status='open';etype='叫你做事';key=$e.key;action='synthetic'}}}
  function Get-CardRule($c){'do'}
  function Test-Quiet($now,$cfg){$false}
  function Add-ChatItem($item){$item.id='event-card';$item}
  function Update-ChatItem($item){}
  function Set-Prop($item,$name,$value){$item[$name]=$value}
  function Set-EventSeen($key){[void]$script:eventSeen.Add($key)}
  function On-Choose($id,$index,$text){$script:eventChoices++;if($script:eventBodyActive){$script:eventBodyChoices++}}
  $script:EvLast=[datetime]::MinValue;$clock.Restart();Step-Events;$clock.Stop();$eventJob=$script:jobs[-1]
  Check 'main_events_submits_under100_without_collection' ($clock.ElapsedMilliseconds -lt 100 -and $eventJob.key -eq 'events' -and $script:eventReads -eq 0)
  $postCount=$script:posts.Count;$script:eventBodyActive=$true
  try{$eventData=& ([scriptblock]::Create([string]$eventJob.code)) $eventJob.input}finally{$script:eventBodyActive=$false}
  Check 'event_worker_returns_posts_and_actions_as_data' ($script:eventReads -eq 1 -and @($eventData.posts).Count -eq 1 -and @($eventData.auto).Count -eq 1 -and $script:eventSeen.Count -eq 1)
  Check 'event_worker_does_not_dispatch_ui_or_actions' ($script:eventChoices -eq 0 -and $script:eventBodyChoices -eq 0 -and $script:posts.Count -eq $postCount)
  $eventPacket=@{ok=$true;data=$eventData}|ConvertTo-Json -Depth 30 -Compress|ConvertFrom-Json
  & $eventJob.then $eventPacket
  Check 'event_actions_dispatch_only_in_ui_callback' ($script:eventChoices -eq 1 -and $script:eventBodyChoices -eq 0 -and $script:posts.Count -gt $postCount)
  $before=$script:jobs.Count;$script:quitting=$true;Request-ReadSnapshot -Full -Force;Watch-Watcher
  Check 'quitting_suppresses_new_reads' ($script:jobs.Count -eq $before)
  # The final path uses the real runspace module, not the submit spy.
  $fixtureModule=Join-Path $testRoot 'background_fixture.ps1'
  $quotedRoot=$testRoot.Replace("'","''");$quotedBackground=(Join-Path $v2 'lib_主后台.ps1').Replace("'","''")
  $moduleLines=@('$script:Root='''+$quotedRoot+'''')
  $moduleLines+=@(
    '$script:DataDir=Join-Path $script:Root ''data''',
    '$script:V2Data=Join-Path $script:Root ''v0.2\data''',
    '$script:counts=@{settings=0}',
    '$script:cfg=@{ui_theme=''dark'';dnd=$true}')
  $fixtureAst=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$null,[ref]$null)
  foreach($name in @('Read-Config','Unprotect','MemU','Get-Today','Get-ActiveReminders','Get-Activity','Get-Upcoming','Get-WaveState','Get-SecretaryName','Get-Settings','Get-Summary','Get-ChatItems','Get-AppsState','New-SyntheticBody')){
    $moduleLines+=($fixtureAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)|Select-Object -First 1).Extent.Text
  }
  $moduleLines+=$chatViewFunction
  $moduleLines+=('. '''+$quotedBackground+'''')
  [IO.File]::WriteAllLines($fixtureModule,[string[]]$moduleLines,(New-Object Text.UTF8Encoding $true))
  . (Join-Path $v2 'lib_后台任务.ps1')
  $script:IntegrationWorkerModules=@($fixtureModule)
  function Get-ReadWorkerModules { $script:IntegrationWorkerModules }
  $script:quitting=$false;$script:ReadView=$null;$script:ReadNext=[datetime]::MinValue;$script:posts.Clear();$script:miniPosts.Clear()
  $clock.Restart();Request-ReadSnapshot -Full -Force;$clock.Stop()
  Check 'actual_main_worker_submission_under100' ($clock.ElapsedMilliseconds -lt 100 -and (Test-SecWorkPending 'view'))
  $deadline=[Diagnostics.Stopwatch]::StartNew()
  while((Test-SecWorkPending) -and $deadline.ElapsedMilliseconds -lt 8000){Step-SecWork;Start-Sleep -Milliseconds 5}
  Check 'actual_worker_loads_background_module_and_renders' (-not (Test-SecWorkPending) -and $script:ReadView.today.Count -eq 2 -and @($script:posts|Where-Object type -eq 'init').Count -eq 1 -and $script:miniPosts.Count -eq 2)
  $beforeBodies=$script:providerBodies.Count
  [void](Start-SecWork -Key 'contract' -Modules @($fixtureModule) -Code 'New-SyntheticBody' -Then {param($r)if($r.ok){[void](Start-Claude $r.data)}})
  $deadline.Restart();while((Test-SecWorkPending) -and $deadline.ElapsedMilliseconds -lt 8000){Step-SecWork;Start-Sleep -Milliseconds 5}
  Check 'actual_worker_json_preserves_provider_request_contract' ($script:providerBodies.Count -eq ($beforeBodies+1) -and $script:providerBodies[-1].messages.Count -eq 1 -and $script:providerBodies[-1].output_config.format.schema.properties.ok.type -eq 'boolean')
  Stop-SecWorkers
}catch{Check ('unexpected_'+$_.Exception.GetType().Name) $false}
finally{
  if(Get-Command Stop-SecWorkers -ErrorAction SilentlyContinue){Stop-SecWorkers}
  $path=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
  if($path.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($path).StartsWith('secretary_integration_')){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}
}
"integration_reliability_test: $script:pass pass, $script:fail fail"
if($script:fail){exit 1}