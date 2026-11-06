# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 事项状态是原始 todos.jsonl 上的一层版本记录。原始消息、事项和每次修改均保留。
# 状态变化逐条加密追加；同一事项的 id 不随内容、日期、类别变化。
function Get-TaskJournalPath { Join-Path $script:V2Data 'task_history.jsonl' }
function Get-TodoId($todo) {
  if ($todo.id) { return [string]$todo.id }
  # 已有卡片、done.json、提醒都引用这个旧编号；迁移不换号。
  ($todo.ts + '|' + $todo.事情).GetHashCode().ToString('x8')
}
function Get-TaskHash([string]$s) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Copy-TaskMap($x) {
  $h = [ordered]@{}
  if ($x -is [Collections.IDictionary]) { foreach ($k in $x.Keys) { $h[$k] = $x[$k] } }
  else { foreach ($p in $x.PSObject.Properties) { $h[$p.Name] = $p.Value } }
  $h
}
function Get-TaskHistory {
  $file = Get-TaskJournalPath
  if (-not (Test-Path -LiteralPath $file)) { return @() }
  $fi = Get-Item -LiteralPath $file
  $sig = "$file|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
  if ($script:TaskHistorySig -eq $sig) { return @($script:TaskHistoryCache) }
  $records = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in [IO.File]::ReadLines($file, [Text.Encoding]::UTF8)) {
    if (-not $line.Trim()) { continue }
    try { $r = (Unprotect $line) | ConvertFrom-Json; if ($r.id -and $r.task) { $records.Add($r) } } catch { }
  }
  $script:TaskHistorySig = $sig; $script:TaskHistoryCache = $records.ToArray()
  @($script:TaskHistoryCache)
}
function Get-TaskCompletionOverrides {
  $out = @{}
  foreach ($r in Get-TaskHistory) { $out[[string]$r.id] = ([string]$r.task.status -in 'completed','cancelled','dismissed') }
  $out
}
function Get-TrackedTodos([switch]$IncludeClosed) {
  $by = [ordered]@{}; $done = @{};$kept=@{}
  if (Get-Command Get-DoneSet -ErrorAction SilentlyContinue) { $done = Get-DoneSet }
  else { $legacyDone=Join-Path $script:V2Data 'done.json';if(Test-Path -LiteralPath $legacyDone){try{foreach($id in @((Get-Content -LiteralPath $legacyDone -Raw|ConvertFrom-Json))){$done[[string]$id]=$true}}catch{}} }
  $autoFile=Join-Path $script:V2Data 'auto_replied.json'
  if(Test-Path -LiteralPath $autoFile){try{(Get-Content -LiteralPath $autoFile -Raw|ConvertFrom-Json).PSObject.Properties|ForEach-Object {if($_.Value -eq 'kept'){$kept[$_.Name]=$true}}}catch{}}
  foreach ($t in Read-Jsonl 'todos.jsonl') {
    $id = Get-TodoId $t; if (-not $id) { continue }
    $base = try { [datetime]$t.原文时间 } catch { [datetime]$t.ts }; if ($base -eq [datetime]::MinValue) { $base = [datetime]$t.ts }
    $due = [string](Unprotect $t.截止); $parsed = Resolve-TaskDue $due $base
    $by[$id] = [ordered]@{ id=$id; created=[string]$t.ts; updated=[string]$t.ts; since=$base.ToString('s'); app=$(if($t.app){[string]$t.app}else{'微信'}); conv=[string](Unprotect $t.conv)
      who=[string](Unprotect $t.谁); what=[string](Unprotect $t.事情); category=[string]$t.类别; due_text=$due; due_at=[string]$parsed.at; has_time=[bool]$parsed.has_time
      quote=[string](Unprotect $t.原文); speaker=[string]$t.发言; source_keys=@($t.source_keys | Where-Object { $_ }); message_key=[string]$t.message_key; source_sequence=[long]$t.source_sequence
      status=$(if($done[$id]){'completed'}else{'open'}); response_state=''; reason=''; no_auto_complete=[bool]$kept[$id]; needs_time=$false; time_question_asked=$false; revision=0 }
  }
  foreach ($r in Get-TaskHistory) { $by[[string]$r.id] = Copy-TaskMap $r.task }
  foreach ($t in $by.Values) {
    if (-not $IncludeClosed -and $t.status -in 'completed','cancelled','dismissed') { continue }
    [pscustomobject]$t
  }
}
function Resolve-TaskDue([string]$said, [datetime]$base = (Get-Date)) {
  if (-not $said) { return @{at='';has_time=$false} }
  $iso = [datetime]::MinValue
  if ($said -match '^\d{4}-\d{2}-\d{2}' -and [datetime]::TryParse($said, [ref]$iso)) { return @{at=$iso.ToString('s');has_time=($said -match '[T ]\d\d:\d\d')} }
  # “等我一下”没有可靠期限，不能凭空指定两小时后。
  if ($said -match '等我|稍后|晚点|待会|回头|改天|有空|过阵子' -and $said -notmatch '今天|明天|后天|周|星期|\d+[点:：]') { return @{at='';has_time=$false} }
  $r = $null; if (Get-Command Resolve-Due -ErrorAction SilentlyContinue) { $r = Resolve-Due $said $base }
  if (-not $r -and $said -match '晚上|今晚') { return @{at=$base.Date.AddHours(20).ToString('s');has_time=$true} }
  if ($r) {
    $at = [datetime]$r.at;$hasTime=[bool]$r.time
    if ($said -match '晚上|今晚|明晚' -and $said -notmatch '\d+[点:：]') { $at = $at.Date.AddHours(20);$hasTime=$true }
    return @{at=$at.ToString('s');has_time=$hasTime}
  }
  @{at='';has_time=$false}
}
function Get-TaskDueBucket($task, [datetime]$now = (Get-Date)) {
  if (-not $task.due_at) { return 'undated' }
  $at = [datetime]$task.due_at
  if ($at -lt $now -and ($task.has_time -or $at.Date -lt $now.Date)) { return 'overdue' }
  if ($at.Date -eq $now.Date) { return 'today' }
  'soon'
}
function Update-TrackedTask([string]$Id, [hashtable]$Changes, [string]$Reason, [string]$EvidenceId='', [datetime]$Now=(Get-Date)) {
  $path = Get-TaskJournalPath; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
  $mutex = New-Object Threading.Mutex($false, ('Local\SecretaryTask_' + (Get-TaskHash $path).Substring(0,24))); $held=$false
  try {
    try { $held=$mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (-not $held) { throw 'Task history is busy' }
    $history = @(Get-TaskHistory)
    if ($EvidenceId -and @($history | Where-Object { $_.id -eq $Id -and $_.evidence_id -eq $EvidenceId }).Count) { return $null }
    $task = Get-TrackedTodos -IncludeClosed | Where-Object id -eq $Id | Select-Object -First 1
    if (-not $task) { return $null }
    $next = Copy-TaskMap $task
    if ($Changes.status -eq 'completed' -and $Changes.automatic -eq $true -and $task.no_auto_complete) { return $null }
    foreach ($k in $Changes.Keys) { if ($k -notin 'id','created','quote','source_keys','message_key','automatic') { $next[$k]=$Changes[$k] } }
    $next.updated=$Now.ToString('s'); $next.revision=[int]$task.revision+1
    $record=[ordered]@{id=$Id;ts=$Now.ToString('s');event=$Reason;evidence_id=$EvidenceId;task=$next}
    $bytes=[Text.Encoding]::UTF8.GetBytes((Protect ($record|ConvertTo-Json -Depth 12 -Compress))+[Environment]::NewLine)
    $fs=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try {
      # 崩溃遗留的半行保持原样，隔开后写入新版本，不覆盖任何历史。
      if($fs.Length -gt 0){[void]$fs.Seek(-1,[IO.SeekOrigin]::End);$last=$fs.ReadByte();[void]$fs.Seek(0,[IO.SeekOrigin]::End);if($last -ne 10){$lf=[Text.Encoding]::UTF8.GetBytes([Environment]::NewLine);$fs.Write($lf,0,$lf.Length)}}
      $fs.Write($bytes,0,$bytes.Length);$fs.Flush($true)
    } finally {$fs.Dispose()}
    $script:TaskHistorySig=$null
    [pscustomobject]$next
  } finally { if($held){$mutex.ReleaseMutex()};$mutex.Dispose() }
}
function Set-TaskManualDone([string]$Id,[bool]$Done,[datetime]$Now=(Get-Date)) {
  $changes=@{status=$(if($Done){'completed'}else{'open'});response_state=$(if($Done){'completed'}else{'acknowledged'});reason=$(if($Done){'你已标为完成'}else{'你已撤销完成，之后由你确认完成'})}
  if(-not $Done){$changes.no_auto_complete=$true}
  Update-TrackedTask $Id $changes $(if($Done){'manual_complete'}else{'undo_complete'}) '' $Now
}
function Get-TaskWords([string]$s) {
  $s=($s -replace '(今天|明天|后天|昨天|晚上|下午|上午|周[一二三四五六日天]|星期[一二三四五六日天]|改到|改成|给你|发你|发给|资料|文件|事情|处理|完成|搞定|答应|需要|一下|稍后|再说|已经|我|你|的|了|吧)',' ').ToLowerInvariant()
  $out=New-Object 'System.Collections.Generic.HashSet[string]'
  foreach($m in [regex]::Matches($s,'[a-z0-9]{2,}|[\u4e00-\u9fff]{2,}')){if($m.Value -match '^[a-z0-9]+$'){[void]$out.Add($m.Value)}else{for($i=0;$i -lt $m.Length-1;$i++){[void]$out.Add($m.Value.Substring($i,2))}}}
  @($out)
}
function Test-TaskTextReference($Task,[string]$Text) {
  # 完整任务短语之后只能有时间/处理状态；“会议室”不能匹配“会议室空调维修”。
  $needle=([string]$Task.what -replace '\s|[，。！？、：:;；]','').ToLowerInvariant()
  $hay=($Text -replace '\s|[，。！？、：:;；]','').ToLowerInvariant()
  if(-not $needle -or -not $hay.Contains($needle)){return $false}
  $rest=$hay.Replace($needle,'')
  $rest=$rest -replace '发给你了|发过去了|发你了|发好了|已经发送|已发送|已经发了|搞定了|完成了|已完成|提交了|已提交|取消了|不用了|改到|改成|推迟到|延期到|稍后|晚点|待会|再说|再回|明天|后天|今天|今晚|晚上|下?周[一二三四五六日天]|星期[一二三四五六日天]|\d+[点时分:：]|[\d/年月日-]+',''
  $rest=$rest -replace '^(我|把|已经|刚刚|都|也|这件事|这个|已)+|[了啦吧的]$',''
  -not $rest
}
function Get-TaskReplyDecision($Task,[string]$Text,[datetime]$At=(Get-Date),[switch]$Explicit,[switch]$FileVerified) {
  $s=($Text -replace '\s+','').Trim();$change=@{};$event='responded'
  $change.response_state='acknowledged';$change.reason='已回应，尚无完成这件事的证据'
  if($Task.status -eq 'promised'){$change.status='promised'}else{$change.status='acknowledged'}
  $delayed=$s -match '等我一下|等我会|等一下|稍后|晚点|待会|回头|晚上再说|明天再说|(?:明天|后天|周[一二三四五六日天]|星期[一二三四五六日天]|晚上|今晚).*(?:发|给|做|处理|再说|再回)|改到|改成|推迟|延期'
  $completed=$FileVerified -or ($s -match '发你了|发给你了|发过去了|已经发送|已发送|已经发了|发好了|搞定了|完成了|已经完成|提交了|已提交' -and $s -notmatch '没|未|还没|没有|等|再|之后|以后|到时候|如果|假如|要是|能不能|[?？]')
  if($Explicit -and $s -match '^(取消|不用|不用了|不用管|不用再做了)[。！!]*$'){$change.status='dismissed';$change.reason='你已明确说不用处理';$event='dismissed'}
  elseif($completed -and $Explicit -and -not $Task.no_auto_complete){$change.status='completed';$change.response_state='completed';$change.reason=$(if($FileVerified){'已核对这件事的文件发送结果'}else{'已找到与这件事对应的完成说明'});$change.automatic=$true;$event='evidence_complete'}
  elseif($delayed -and $Explicit){
    $due=Resolve-TaskDue $s $At;$change.status='promised';$change.response_state='promised';$change.category='你答应别人的';$change.needs_time=(-not $due.at);$change.reason=$(if($due.at){'答应稍后处理，时间按本机时间推断'}else{'答应稍后处理，时间待你确认'})
    if($due.at){$change.due_at=$due.at;$change.due_text=$s;$change.has_time=$due.has_time;$change.time_question_asked=$false}
    $event='promise_or_reschedule'
  }
  elseif($completed -and $Task.no_auto_complete){$change.reason='你撤销过自动完成，保留到你手动确认'}
  @{changes=$change;event=$event}
}
function Get-TaskMessages([datetime]$Since=[datetime]::MinValue) {
  $script:TaskMessageOrder=@{};$order=0
  foreach($m in Read-Jsonl 'messages.jsonl'){
    $order++;$mid=$(if($m.key){[string]$m.key}else{Get-TaskHash ([string]$m.ts+'|'+[string]$m.conv+'|'+[string]$m.text)})
    $script:TaskMessageOrder[$mid]=$order
    $at=try{[datetime]$m.ts}catch{continue}
    if($at -lt $Since){continue}
    $sender=[string](Unprotect $m.sender);if($sender -ne '我'){continue}
    [pscustomobject]@{id=$mid;at=$at;order=$order;sequence=[long]$m.queue_sequence;app=$(if($m.app){[string]$m.app}else{'微信'});conv=[string](Unprotect $m.conv);text=[string](Unprotect $m.text);task_id=[string]$m.task_id;reply_key=[string]$m.reply_key;file_verified=[bool]$m.file_verified}
  }
}
function Test-TaskMessageAfter($Task,$Message) {
  if([long]$Task.source_sequence -gt 0 -and [long]$Message.sequence -gt 0){return ([long]$Message.sequence -gt [long]$Task.source_sequence)}
  $since=[datetime]$Task.since
  if($Message.at -gt $since){return $true};if($Message.at -lt $since){return $false}
  # 秒级时间相同时，只有显式任务/引用关联或持久消息顺序才能认作后续回复。
  if($Message.task_id -eq $Task.id -and $Message.task_id){return $true}
  if($Message.reply_key -and ($Message.reply_key -eq $Task.message_key -or @($Task.source_keys) -contains $Message.reply_key)){return $true}
  $anchors=@(@($Task.message_key)+@($Task.source_keys)|Where-Object {$_ -and $script:TaskMessageOrder.ContainsKey([string]$_)}|ForEach-Object {[int]$script:TaskMessageOrder[[string]$_]})
  if($anchors.Count){$first=$anchors|Measure-Object -Minimum;return ([int]$Message.order -gt [int]$first.Minimum)}
  $false
}
function Get-TaskReplyTransitions([datetime]$Now=(Get-Date)) {
  $changed=New-Object 'System.Collections.Generic.List[object]';$history=@(Get-TaskHistory);$seen=@{}
  foreach($r in $history){if($r.evidence_id){$seen[[string]$r.id+'|'+[string]$r.evidence_id]=$true};if($r.task.last_source_message_key){$seen[[string]$r.id+'|msg:'+[string]$r.task.last_source_message_key]=$true}}
  $active=@(Get-TrackedTodos);if(-not $active.Count){return @()};$first=($active|ForEach-Object {[datetime]$_.since}|Sort-Object|Select-Object -First 1)
  foreach($m in @(Get-TaskMessages $first | Sort-Object at)){
    $tasks=@($active | Where-Object {$_.app -eq $m.app -and $_.conv -eq $m.conv -and (Test-TaskMessageAfter $_ $m) -and -not $seen[([string]$_.id+'|msg:'+ $m.id)]})
    if(-not $tasks.Count){continue};$selected=@();$explicit=$false
    if($m.task_id){$selected=@($tasks|Where-Object id -eq $m.task_id);$explicit=$true}
    elseif($m.reply_key){$selected=@($tasks|Where-Object {$_.message_key -eq $m.reply_key -or @($_.source_keys) -contains $m.reply_key});$explicit=$true}
    else{
      $words=@(Get-TaskWords $m.text)
      $scores=@(foreach($t in $tasks){$tw=@(Get-TaskWords $t.what);$n=@($tw|Where-Object {$words -contains $_}).Count;if($tw.Count -and $n -eq $tw.Count){[pscustomobject]@{task=$t;score=$n}}})
      $top=@($scores|Sort-Object score -Descending)
      if($top.Count -and ($top.Count -eq 1 -or $top[0].score -gt $top[1].score)){$selected=@($top[0].task);$explicit=Test-TaskTextReference $top[0].task $m.text}
      elseif($tasks.Count -eq 1){
        $selected=@($tasks[0])
        # 没有事项关键词时，只接收指向上一件事的短回复；“别的事搞定了”不能算本事项完成。
        $compact=($m.text -replace '\s+','').Trim()
        $explicit=($compact -match '^(?:取消|不用|不用了|不用管|不用再做了)[。！!]*$|^(?:已经)?(?:发你了|发给你了|发过去了|搞定了|完成了|发好了|已发|已发送|提交了|已提交)[。！!]*$|^(?:改到|改成|推迟到|延期到)|^(?:等我一下|等我会|等一下|稍后|晚点|待会|回头|晚上再说|明天再说)|^(?:明天|后天|周[一二三四五六日天]|星期[一二三四五六日天]|晚上|今晚).*(?:发你|给你|处理|再说|再回)')
      }
    }
    if(-not $selected.Count){
      if($m.text -match '搞定|完成|发你了|改到|改成|等我'){
        foreach($t in $tasks){$u=Update-TrackedTask $t.id @{reason='同一会话有多件事，尚不能确定这条回复对应哪一件'} 'ambiguous_reply' ('msg:'+$m.id) $m.at;if($u){$seen[$t.id+'|msg:'+$m.id]=$true;$changed.Add(@{id=$t.id;completed=$false;response_state=$u.response_state})}}
        $active=@(Get-TrackedTodos)
      }
      continue
    }
    foreach($t in $selected){
      $decision=Get-TaskReplyDecision $t $m.text $m.at -Explicit:$explicit -FileVerified:($m.file_verified -and $explicit)
      $updated=Update-TrackedTask $t.id $decision.changes $decision.event ('msg:'+$m.id) $m.at
      if($updated){$seen[$t.id+'|msg:'+$m.id]=$true;$changed.Add(@{id=$t.id;completed=($updated.status -eq 'completed');response_state=$updated.response_state})}
    }
    $active=@(Get-TrackedTodos)
  }
  @($changed.ToArray())
}
function Record-TodoSendEvidence([string]$TodoId,[string]$ActionId,[switch]$IsFile,[string]$Text='', [datetime]$Now=(Get-Date)) {
  $t=Get-TrackedTodos -IncludeClosed | Where-Object id -eq $TodoId | Select-Object -First 1
  if(-not $t -or $t.status -in 'completed','cancelled','dismissed'){return @{changed=$false;completed=$false;id=$TodoId}}
  $d=Get-TaskReplyDecision $t $Text $Now -Explicit -FileVerified:$IsFile
  $u=Update-TrackedTask $TodoId $d.changes $d.event ('send:'+$ActionId) $Now
  @{changed=[bool]$u;completed=[bool]($u -and $u.status -eq 'completed');id=$TodoId;response_state=$(if($u){$u.response_state}else{$t.response_state})}
}
function Claim-TaskTimeQuestions([datetime]$Now=(Get-Date)) {
  foreach($t in @(Get-TrackedTodos | Where-Object {$_.needs_time -and -not $_.time_question_asked})){
    if($t.time_question_claimed_until -and [datetime]$t.time_question_claimed_until -gt $Now){continue}
    $u=Update-TrackedTask $t.id @{time_question_claimed_until=$Now.AddSeconds(60).ToString('s')} 'time_question_claim' '' $Now
    if($u){@{id=$t.id;key=('task-time:'+$t.id);title='这件事准备什么时候处理？';what=$t.what;reason=$t.reason}}
  }
}
function Confirm-TaskTimeQuestion([string]$Id,[datetime]$Now=(Get-Date)) {
  # 在问题卡写入聊天档案后确认；崩溃发生在此前时一分钟后可重新领取。
  [void](Update-TrackedTask $Id @{time_question_asked=$true;time_question_claimed_until=''} 'time_question_delivered' ('task-time-delivered:'+$Id) $Now)
}
function Set-TaskDueAnswer([string]$Id,[string]$Text,[datetime]$Now=(Get-Date)) {
  if($Text -match '^(不用|取消|不用管|不用了)$'){return (Update-TrackedTask $Id @{status='dismissed';reason='你已说不用处理';needs_time=$false} 'dismiss' '' $Now)}
  $r=Resolve-TaskDue $Text $Now
  if(-not $r.at){return $null}
  Update-TrackedTask $Id @{due_at=$r.at;due_text=$Text;has_time=$r.has_time;needs_time=$false;reason='已按你确认的时间更新';status='promised';category='你答应别人的';response_state='promised'} 'time_answer' '' $Now
}
function Merge-TaskCandidate($Candidate) {
  # 只有明确引用原事项的修改/承诺才复用编号；主体换了或有多个候选时保留待判断。
  $quote=[string](Unprotect $Candidate.原文);$what=[string](Unprotect $Candidate.事情)
  $isRevision=($quote+' '+$what) -match '改到|改成|推迟|延期|取消|不用再|不用了'
  $isPromise=([string]$Candidate.发言 -eq 'self' -and [string]$Candidate.类别 -eq '你答应别人的')
  if(-not $isRevision -and -not $isPromise){return @{updated=$false;candidate=$Candidate}}
  $app=$(if($Candidate.app){[string]$Candidate.app}else{'微信'});$conv=[string](Unprotect $Candidate.conv)
  $history=@(Get-TaskHistory);$evidence='queue:'+[string]$Candidate.id
  $prior=@($history|Where-Object evidence_id -eq $evidence)|Select-Object -Last 1
  if($prior){return @{updated=$true;candidate=$null;id=[string]$prior.id}}
  $candidates=@(Get-TrackedTodos|Where-Object {$_.app -eq $app -and $_.conv -eq $conv -and $_.id -ne [string]$Candidate.id})
  if($isPromise -and -not $isRevision){$candidates=@($candidates|Where-Object {$_.category -eq '需要你回的'})}
  if(-not $candidates.Count){return @{updated=$false;candidate=$Candidate}}
  $chosen=$null;$revisionTail=$quote
  $direct=@($candidates|Where-Object {Test-TaskTextReference $_ $quote})
  if($direct.Count -eq 1){$chosen=$direct[0]}
  # 明确修改句的主体要精确对应；“会议室空调维修”不是“会议室”。旧日期不属于主体。
  $normalizeSubject={param([string]$text,[bool]$revision)
    $n=($text -replace '\s|[，。！？、：:;；]','').ToLowerInvariant()
    $n=$n -replace '今天|明天|后天|昨天|今晚|下?周[一二三四五六日天]|星期[一二三四五六日天]|上午|下午|晚上|\d+[点时](?:\d+分)?',''
    $n=$n -replace '^(?:我|请|能不能|能|可以|帮我|麻烦|把)+|(?:吗|呢|吧|了)$',''
    $n=$n -replace '^给.{1,12}?(?=发|发送|提交|交)',''
    $n=$n -replace '^(?:发给|发送|提交|交付|发|交|提供)|(?:发给我|发我|给我|发给你|发你|给你)$',''
    if($revision){$n=$n -replace '^(?:预订|预定|预约|维修|修理)',''}
    $n
  }
  if($isRevision){
    $match=[regex]::Match(($quote -replace '\s',''),'^(?<subject>.+?)(?<op>改到|改成|推迟到?|延期到?|取消了?|不用了)(?<tail>.*)$')
    if($match.Success){
      $subject=& $normalizeSubject $match.Groups['subject'].Value $true
      $matchesExact=@($candidates|Where-Object { $candidateSubject=& $normalizeSubject $_.what $true; $subject.Length -ge 2 -and $candidateSubject -ceq $subject })
      if($matchesExact.Count -eq 1 -and (-not $chosen -or $chosen.id -eq $matchesExact[0].id)){$chosen=$matchesExact[0];$revisionTail=$match.Groups['tail'].Value}
    }
  }
  if(-not $chosen -and $isPromise -and -not $isRevision){
    $subject=& $normalizeSubject $quote $false
    $same=@($candidates|Where-Object { $candidateSubject=& $normalizeSubject $_.what $false; $subject.Length -ge 2 -and $subject -ceq $candidateSubject })
    if($same.Count -eq 1){$chosen=$same[0]}
    elseif($candidates.Count -eq 1 -and ($quote -replace '\s','') -match '^(?:我)?(?:(?:明天|后天|今晚|晚上|下?周[一二三四五六日天]|星期[一二三四五六日天])(?:发你|发给你|给你|处理|再说|再回|做完|交给你)|等我一下|等一下|等我会|稍后|晚点|待会|回头|晚上再说|明天再说)[。！!]*$'){$chosen=$candidates[0]}
  }
  if(-not $chosen -and $isRevision -and $candidates.Count -eq 1 -and ($quote -replace '\s','') -match '^(?:取消|不用了|不用管|不用再做了)[。！!]*$|^(?:改到|改成|推迟到|延期到)(?:今天|明天|后天|大后天|下?周[一二三四五六日天]|星期[一二三四五六日天]|\d{1,4}[年/月日点:：]).*[。！!]*$'){$chosen=$candidates[0]}
  if(-not $chosen){return @{updated=$false;candidate=$Candidate}}
  $at=try{[datetime]$Candidate.原文时间}catch{[datetime]$Candidate.ts};if($at -eq [datetime]::MinValue){$at=Get-Date}
  if($isPromise -and -not $isRevision){
    $decision=Get-TaskReplyDecision $chosen $quote $at -Explicit
    $changes=$decision.changes;$reason=$decision.event
  }else{
    $text=($revisionTail+' '+[string](Unprotect $Candidate.截止)).Trim();$due=Resolve-TaskDue $text $at
    $changes=@{reason='已更新原事项，原文和修改历史均保留'};$reason='source_revision'
    if($quote -match '取消|不用再|不用了'){
      if($chosen.no_auto_complete){$changes.reason='你撤销过自动收起，保留到你手动确认'}
      else{$changes.status='cancelled';$changes.reason='已明确取消这件事'}
    }else{
      if($due.at){$changes.due_at=$due.at;$changes.due_text=$text;$changes.has_time=$due.has_time;$changes.needs_time=$false}
      elseif($quote -match '改到|推迟|延期'){$changes.needs_time=$true;$changes.reason='事项已更新，新时间待你确认'}
      # 单纯改期只改时间；明确“改成某内容”才更新事项正文。
      if($quote -match '改成' -and -not $due.at -and $revisionTail){$changes.what=$revisionTail}
    }
  }
  if($Candidate.message_key){$changes.last_source_message_key=[string]$Candidate.message_key}
  $updated=Update-TrackedTask $chosen.id $changes $reason $evidence $at
  @{updated=[bool]$updated;candidate=$(if($updated){$null}else{$Candidate});id=$chosen.id}
}
