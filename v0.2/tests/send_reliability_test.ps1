# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
param([switch]$Baseline)
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
$testBase = Join-Path $v2 'data'
$root = Join-Path $testBase ('secretary-send-reliability-' + [guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($root)
$script:ActDir = Join-Path $root 'actions'; [void][IO.Directory]::CreateDirectory($script:ActDir)
$script:V2Data = $root
function Protect([string]$s) { $s }
function Unprotect([string]$s) { $s }
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; '[{0}] {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name }
try {
  if ($Baseline) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 '秘书.ps1'), [ref]$null, [ref]$null)
    foreach ($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Repair-SendingCards','Close-StuckScheduled'},$true)) { . ([scriptblock]::Create($f.Extent.Text)) }
    $script:card = [pscustomobject]@{id='c1';card=[pscustomobject]@{kind='send';status='sending';actionId='a1'}}
    $script:job = [pscustomobject]@{ actionId='a1';status='started';itemId='c1';at=(Get-Date).AddMinutes(-5) }
    $script:action = [pscustomobject]@{ id='a1';status='confirmed' }; $script:Sending=@{}
    function Get-ChatItems { $script:card }; function Get-Scheduled { $script:job }
    function Set-ScheduledStatus($id,$status) { $script:job.status=$status }
    function Update-ChatItem($x) { $script:card=$x }; function Post($x) {}
    function Set-Prop($x,$k,$v) { $x | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force }
    function Get-Action($id) { $script:action }; function Save-Action($a) { $script:action=$a }
    [IO.File]::WriteAllText((Join-Path $script:ActDir 'a1.result.json'), '{"id":"a1","ok":true,"steps":[]}')
    Repair-SendingCards
    Check 'current baseline recovery statements execute (reported comment defect already fixed)' ($script:card.card.status -eq 'closed' -and $script:job.status -eq 'done')
    [IO.File]::Delete((Join-Path $script:ActDir 'a1.result.json'))
    $script:job.status='started';$script:card.card.status='sending';$script:action.status='confirmed'
    Close-StuckScheduled
    Check 'interrupted legacy execution without evidence must remain unknown' ($script:action.status -eq 'unknown')
  } else {
    . (Join-Path $v2 'lib_动作.ps1')
    function New-Fake([string]$id) { $a=[pscustomobject]@{id=$id;status='confirmed';conv='synthetic';text='synthetic';file=''};Save-ReliableAction $a; $a }
    [void](New-Fake 'a1'); $a=Start-ActionAttempt 'a1' 0
    Check 'begin attempt persists running before UI' ((Get-ActionState (Get-ActionRecord 'a1')) -eq 'running')
    $r=Recover-Action 'a1' -KnownStopped
    Check 'crash before send is failed and retryable by explicit action' ($r.state -eq 'failed' -and $r.ok -eq $false)
    [void](New-Fake 'a2');[void](Start-ActionAttempt 'a2' 0);Set-ActionPhase 'a2' 'send_intent'
    $r=Recover-Action 'a2' -KnownStopped
    Check 'crash between durable intent and key is unknown' ($r.state -eq 'unknown' -and $null -eq $r.ok)
    $blocked=$false;try{$a=Get-ActionRecord 'a2';$a.status='confirmed';Save-ReliableAction $a}catch{$blocked=$true}
    Check 'unknown cannot be silently rearmed' $blocked
    [void](New-Fake 'a3');[void](Start-ActionAttempt 'a3' 0);Set-ActionPhase 'a3' 'send_intent';Set-ActionPhase 'a3' 'send_pressed'
    $r=Save-ActionResult 'a3' $false 'interrupted' @()
    Check 'post-send failure cannot claim unsent' ($r.state -eq 'unknown')
    [void](New-Fake 'a4');[void](Start-ActionAttempt 'a4' 0);Set-ActionPhase 'a4' 'send_intent';Set-ActionPhase 'a4' 'send_pressed';Set-ActionPhase 'a4' 'verified'
    $r=Recover-Action 'a4' -KnownStopped
    Check 'verified phase survives crash before result file' ($r.state -eq 'succeeded')
    $blocked=$false;try{$a=Get-ActionRecord 'a4';$a.status='confirmed';Save-ReliableAction $a}catch{$blocked=$true}
    Check 'successful action never rearms' $blocked
    Check 'explicit sent confirmation resolves unknown' (Resolve-ActionResult 'a2' 'sent')
    Check 'confirmed sent state is terminal' ((Get-ActionState (Get-ActionRecord 'a2')) -eq 'succeeded')
    Check 'explicit unsent choice allows manual retry' (Resolve-ActionResult 'a3' 'retry')
    $a=Get-ActionRecord 'a3';$a.status='confirmed';Save-ReliableAction $a;[void](Start-ActionAttempt 'a3' 0)
    Check 'retry has a fresh attempt identity' ((Get-ActionRecord 'a3').attempt_id -ne $r.attempt_id)
    Check 'prior unknown result retained as history' (@(Get-ChildItem -LiteralPath $script:ActDir -Filter 'a3.checked-*.result.json').Count -eq 1)
    [void](New-Fake 'rate');1..3 | ForEach-Object{[void](Start-ActionAttempt 'rate' 0);[void](Save-ActionResult 'rate' $false 'preflight' @());$a=Get-ActionRecord 'rate';$a.status='confirmed';Save-ReliableAction $a}
    $blocked=$false;try{[void](Start-ActionAttempt 'rate' 0)}catch{$blocked=$true}
    Check 'fourth attempt within two minutes blocked' $blocked
    Check 'three failed attempts retained' ((Get-ActionAttemptCount 'rate') -eq 3)
    [void](New-Fake 'legacy');$r=Recover-Action 'legacy' -KnownStopped
    Check 'legacy confirmed without phase remains unknown' ($r.state -eq 'unknown')
    [void](New-Fake 'stale');$a=Start-ActionAttempt 'stale' 0
    Write-ActionAtomic (Join-Path $script:ActDir 'stale.result.json') '{"id":"stale","attempt_id":"older","ok":true}'
    Check 'result from old attempt ignored' ($null -eq (Read-ActionResult 'stale'))
    $f=Join-Path $root 'atomic.json';Write-ActionAtomic $f '{"n":1}';Write-ActionAtomic $f '{"n":2}'
    Check 'atomic replacement retains valid complete JSON' (([IO.File]::ReadAllText($f)|ConvertFrom-Json).n -eq 2)
    Check 'no orphan write temporary files' (@(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.tmp').Count -eq 0)
    $lease=Enter-SendLease;Check 'sender lease acquired' ($null -ne $lease);Exit-SendLease $lease
    # Execute only pure/test-driver functions; no window, clipboard or real input is used.
    $af = [Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 'lib_发文件.ps1'),[ref]$null,[ref]$null)
    foreach($fn in $af.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Test-FileNameShown','Invoke-FileSend'},$true)){. ([scriptblock]::Create($fn.Extent.Text))}
    function Set-ClipFile($x){$script:clipWrites++;'synthetic-clipboard'}
    function Restore-Clip($x){$script:clipRestores++}
    $path=Join-Path $root 'synthetic.txt';[IO.File]::WriteAllText($path,'synthetic')
    function New-Driver {
      @{settleMs=0;summon={$true};title={'synthetic'};isForeground={$true};focusInput={};paste={};dialog={@{present=$false}};inputHasFile={$true};clearInput={};pressEnter={$script:pressed++;$script:sentFile=$true};lastMineHasFile={param($n)$script:sentFile};restore={$script:restored++}}
    }
    $script:clipWrites=0;$script:clipRestores=0;$script:pressed=0;$script:sentFile=$false;$script:restored=0
    [void](New-Fake 'file1');$a=Get-ActionRecord 'file1';$a.file=$path;Save-ReliableAction $a;[void](Start-ActionAttempt 'file1' 0)
    $drv=New-Driver;$drv.actionId='file1';$r=Invoke-FileSend (Get-ActionRecord 'file1') $drv {param($x,$y)$x -ceq $y}
    Check 'synthetic file sends exactly once with verified phase' ($r.ok -eq $true -and $script:pressed -eq 1 -and (Get-ActionState (Get-ActionRecord 'file1')) -eq 'succeeded')
    Check 'synthetic file restores clipboard and driver in finally' ($script:clipRestores -eq 1 -and $script:restored -eq 1)
    $script:sentFile=$false;$script:pressed=0;$script:restored=0
    [void](New-Fake 'file2');$a=Get-ActionRecord 'file2';$a.file=$path;Save-ReliableAction $a;[void](Start-ActionAttempt 'file2' 0)
    $drv=New-Driver;$drv.actionId='file2';$drv.pressEnter={$script:pressed++;throw 'synthetic interruption'}
    $r=Invoke-FileSend (Get-ActionRecord 'file2') $drv {param($x,$y)$x -ceq $y}
    Check 'interruption at send remains unknown and restores driver' ($null -eq $r.ok -and $script:pressed -eq 1 -and $script:restored -eq 1)
    $r=Recover-Action 'file2' -KnownStopped
    Check 'file send crash is recoverable from durable intent' ($r.state -eq 'unknown')
    $script:sentFile=$true;$script:pressed=0
    [void](New-Fake 'file3');$a=Get-ActionRecord 'file3';$a.file=$path;Save-ReliableAction $a;[void](Start-ActionAttempt 'file3' 0)
    $drv=New-Driver;$drv.actionId='file3';$r=Invoke-FileSend (Get-ActionRecord 'file3') $drv {param($x,$y)$x -ceq $y}
    Check 'pre-existing same file cannot prove a new send' ($null -eq $r.ok)
    $af=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 'lib_前台发送.ps1'),[ref]$null,[ref]$null)
    $fn=$af.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-NewSentText'},$true)[0];. ([scriptblock]::Create($fn.Extent.Text))
    $before=@{会话='synthetic';消息=@(@{发送方='我';文本='old'})};$after=@{会话='synthetic';消息=@(@{发送方='我';文本='new'})};$same={param($x,$y)$x -ceq $y}
    Check 'new outgoing text with exact title is evidence' (Test-NewSentText $before $after 'new' 'synthetic' $same)
    Check 'same old outgoing bubble is not fresh evidence' (-not(Test-NewSentText $after $after 'new' 'synthetic' $same))
    Check 'empty or unreadable screenshot is not success' (-not(Test-NewSentText $before $null 'new' 'synthetic' $same))
    Check 'other chat cannot satisfy send verification' (-not(Test-NewSentText $before $after 'new' 'other' $same))
    # Actual main functions, persisted synthetic cards, and a fake launcher.
    $ma=[Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 '秘书.ps1'),[ref]$null,[ref]$null)
    $names=@('Apply-SendResultToCard','Invoke-SendResolution','Invoke-SendRetry','Start-Send','Repair-SendingCards','Close-StuckScheduled','Poll-Sends')
    foreach($fn in $ma.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $names},$true)){. ([scriptblock]::Create($fn.Extent.Text))}
    function Get-Action($id){Get-ActionRecord $id};function Save-Action($a){Save-ReliableAction $a}
    function Set-Prop($o,$k,$v){Set-ActionField $o $k $v}
    $script:cards=@();$script:jobs=@();$script:Launches=0;$script:Sending=@{};$script:SendQueue=$null;$script:SendWorkers=@{};$script:FgLockUntil=$null;$script:AppDir=$v2
    function Get-ChatItems{$script:cards};function Get-Scheduled{$script:jobs}
    function Set-ScheduledStatus($id,$status){foreach($j in $script:jobs){if($j.actionId -eq $id){$j.status=$status}}}
    function Update-ChatItem($it){$script:cards=@($script:cards|Where-Object id -ne $it.id)+@($it);Write-ActionAtomic (Join-Path $root 'cards.json') (ConvertTo-Json @($script:cards) -Depth 8 -Compress)}
    function Post($o){};function Get-TodayView{@()};function Get-Switch($k){$true};function Read-Config{[pscustomobject]@{features=[pscustomobject]@{}}};function Unlock-Foreground{}
    function Start-Process{$script:Launches++;[pscustomobject]@{Id=0}}
    function Record-TodoSendEvidence{param($TodoId,$ActionId,[bool]$IsFile,$Text);@{changed=$false}}
    function New-Card($id){[pscustomobject]@{id=('card-'+$id);card=[pscustomobject]@{kind='send';status='sending';actionId=$id}}}
    [void](New-Fake 'restart1');[void](Start-ActionAttempt 'restart1' 0);Set-ActionPhase 'restart1' 'send_intent';Set-ActionPhase 'restart1' 'send_pressed'
    $it=New-Card 'restart1';Update-ChatItem $it
    $script:jobs=@([pscustomobject]@{actionId='restart1';status='started';itemId=$it.id;at=(Get-Date).AddMinutes(-5)})
    $script:cards=@(([IO.File]::ReadAllText((Join-Path $root 'cards.json'))|ConvertFrom-Json))
    Repair-SendingCards
    $c=(Get-ChatItems|Where-Object id -eq 'card-restart1').card
    Check 'actual restart recovery closes sending as unknown with two-choice marker' ($c.status -eq 'closed' -and $c.actionState -eq 'unknown' -and $c.needsVerification -and -not $c.failed)
    Check 'scheduled interrupted send uses unknown too' ($script:jobs[0].status -eq 'unknown')
    1..10|ForEach-Object{Poll-Sends}
    Check 'recovery and polling never automatically resend unknown' ($script:Launches -eq 0)
    Check 'ordinary retry cannot bypass unknown verification' ((Invoke-SendRetry 'card-restart1') -eq 'not-retryable' -and $script:Launches -eq 0)
    Check 'already-sent button confirms without launching sender' ((Invoke-SendResolution 'card-restart1' 'sent') -eq 'verified' -and $script:Launches -eq 0)
    Check 'already-sent button persists succeeded state' ((Get-ActionState (Get-ActionRecord 'restart1')) -eq 'succeeded')
    [void](New-Fake 'restart2');[void](Start-ActionAttempt 'restart2' 0);Set-ActionPhase 'restart2' 'send_intent';Set-ActionPhase 'restart2' 'send_pressed';Update-ChatItem (New-Card 'restart2');Repair-SendingCards
    $r=Invoke-SendResolution 'card-restart2' 'retry'
    Check 'explicit unsent-and-retry launches once' ($r -eq 'started' -and $script:Launches -eq 1)
    Check 'explicit retry retains exact original action and card identity' ($script:Sending.ContainsKey('restart2') -and $script:Sending['restart2'].id -eq 'card-restart2')
    [void](Invoke-SendResolution 'card-restart2' 'retry')
    Check 'double clicking resolution does not duplicate launch' ($script:Launches -eq 1)
    $script:Sending.Clear()
    [void](New-Fake 'restart3');[void](Start-ActionAttempt 'restart3' 0);Update-ChatItem (New-Card 'restart3');Repair-SendingCards
    $c=(Get-ChatItems|Where-Object id -eq 'card-restart3').card
    Check 'actual recovery before send presents failed manual retry' ($c.actionState -eq 'failed' -and $c.failed -and -not $c.needsVerification)
    [void](Set-LocalOperationState 'local-card-1' 'queued');[void](Set-LocalOperationState 'local-card-1' 'running')
    $recovered=@(Recover-LocalOperations)
    Check 'non-send interrupted operation becomes unknown after restart' ($recovered.Count -eq 1 -and $recovered[0].state -eq 'unknown')
    $blocked=$false;try{[void](Set-LocalOperationState 'local-card-1' 'running')}catch{$blocked=$true}
    Check 'unknown local operation is not replayed' $blocked
    [void](Set-LocalOperationState 'local-card-2' 'running');[void](Set-LocalOperationState 'local-card-2' 'succeeded')
    $blocked=$false;try{[void](Set-LocalOperationState 'local-card-2' 'running')}catch{$blocked=$true}
    Check 'successful local operation is not duplicated' $blocked
    Check 'local operation state persists independently of UI cards' ((Get-LocalOperationState 'local-card-2').state -eq 'succeeded')
    $all=@(Get-ChildItem -LiteralPath $script:ActDir -Filter '*.json' | Where-Object {$_.Name -notmatch '\.result\.'} | ForEach-Object {try{Get-ActionState (([IO.File]::ReadAllText($_.FullName))|ConvertFrom-Json)}catch{}})
    Check 'all execution states restricted to five values' (@($all | Where-Object {$_ -notin 'queued','running','succeeded','failed','unknown'}).Count -eq 0)
  }
} finally {
  $full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath($testBase).TrimEnd('\')+'\'
  if($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full).StartsWith('secretary-send-reliability-')) { Remove-Item -LiteralPath $full -Recurse -Force }
}
'send_reliability_test: {0} pass, {1} fail' -f $script:pass,$script:fail
if($script:fail){exit 1}
