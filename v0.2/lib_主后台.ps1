# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# Data-only background operations. No UI handles, no focus changes, no sends.
function Invoke-BackgroundWatcher {
  $out=@{notice='';restarted=$false}
  if(-not $script:BgWatchRestarts){$script:BgWatchRestarts=New-Object System.Collections.ArrayList}
  $pf=Join-Path $script:DataDir 'pid';$watchPid=0
  if(Test-Path -LiteralPath $pf){try{$watchPid=[int]([IO.File]::ReadAllText($pf))}catch{}}
  $alive=$false
  if($watchPid){$p=Get-CimInstance Win32_Process -Filter "ProcessId=$watchPid" -ErrorAction Stop;$alive=$p -and ([string]$p.CommandLine).IndexOf((Join-Path $script:Root '12_值守.ps1'),[StringComparison]::OrdinalIgnoreCase)-ge 0}
  if(-not (Get-Feature 'watcher')){if($alive){& (Join-Path $script:Root '12_值守.ps1') -Stop | Out-Null};return $out}
  if($alive -or $script:BgWatchGaveUp){return $out}
  try{$s=[IO.File]::ReadAllText((Join-Path $script:V2Data 'run_state.json'))|ConvertFrom-Json;if($s.clean -and $s.how -eq 'user-quit'){return $out}}catch{}
  $now=Get-Date
  while($script:BgWatchRestarts.Count -and ($now-$script:BgWatchRestarts[0]).TotalMinutes -gt 10){$script:BgWatchRestarts.RemoveAt(0)}
  if($script:BgWatchRestarts.Count -ge 3){$script:BgWatchGaveUp=$true;$out.notice='值守连续退出，已暂停自动恢复。';return $out}
  $wait=@(0,20,60)[$script:BgWatchRestarts.Count]
  if($script:BgWatchRestarts.Count -and ($now-$script:BgWatchRestarts[-1]).TotalSeconds -lt $wait){return $out}
  [void]$script:BgWatchRestarts.Add($now)
  & (Join-Path $script:Root '12_值守.ps1') -Start | Out-Null
  $out.restarted=$true
  $out
}
function Invoke-BackgroundEvents {
  if(-not $script:QAsked){$script:QAsked=New-Object Collections.ArrayList}
  if(-not $script:AskStats){$script:AskStats=@{}}
  $script:BgEventPosts=New-Object Collections.ArrayList
  $script:BgAutoChoices=New-Object Collections.ArrayList
  $script:BgEventNotice=''
  function Post($o){[void]$script:BgEventPosts.Add($o)}
  function Show-Notice([string]$text){$script:BgEventNotice=$text}
  $null=Invoke-EventCollectionCore
  @{posts=@($script:BgEventPosts);auto=@($script:BgAutoChoices);notice=$script:BgEventNotice}
}
function Get-BackgroundPredictions {
  $h = @{}; $path = Join-Path $script:V2Data 'reply_preds.json'
  if (Test-Path -LiteralPath $path) { try { ((Unprotect ([IO.File]::ReadAllText($path))) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } } catch {} }
  $h
}
function Get-BackgroundView($request) {
  $preds = Get-BackgroundPredictions
  $today = @(Get-Today | ForEach-Object { $p = $preds[$_.id]; if ($p -and $_.group -eq 'reply') { $_.preds = @($p.opts); $_.predFallback = [bool]$p.fallback }; $_ })
  $map = @{}; foreach ($t in $today) { $map[$t.id] = $t }
  $reminders = @(Get-ActiveReminders | ForEach-Object {
    if ([string]$_.id -match '^reply\|t:(.+)$') { $_.todoId = $Matches[1]; if ($map[$_.todoId]) { $_.item = $map[$_.todoId] } }; $_
  })
  $cfg = Read-Config; $notice = $null; $side = 'right'
  try { $notice = [IO.File]::ReadAllText((Join-Path $script:DataDir 'notice.json')) | ConvertFrom-Json } catch {}
  try { $side = [string]([IO.File]::ReadAllText((Join-Path $script:V2Data 'edge_pos.json')) | ConvertFrom-Json).side } catch {}
  $result = @{ today = $today; activity = @(Get-Activity); upcoming = @(Get-Upcoming); wave = (Get-WaveState)
    mini = @{ type = 'mini'; name = Get-SecretaryName; wave = (Get-WaveState); theme = [string]$cfg.ui_theme; dnd = [bool]$cfg.dnd; side = $side
      notice = $(if ($notice -and -not $notice.seen) { [string]$notice.kind } else { $null }); today = @($today | Where-Object { -not $_.done }); reminders = $reminders } }
  if ($request.full) {
    $result.settings = Get-Settings
    $allChat = @(Get-ChatItems); $chatView = @(Get-ChatViewItems -Items $allChat)
    $result.chat = @{ summary = Get-Summary; items = $chatView; hasOlder = ($allChat.Count -gt $chatView.Count) }
    $result.apps = @(Get-AppsState)
  }
  $result
}
function Get-BackgroundMemoryRequest {
  if (-not (Get-Feature 'long_memory') -or -not (Get-Permission 'cloud_text') -or -not (Test-MemBudget)) { return $null }
  $st = Get-MemState; $mf = Get-Item $script:MemMsgFile -ErrorAction SilentlyContinue; $cf = Get-Item $script:MemChatFile -ErrorAction SilentlyContinue
  if (-not (Test-Path (Join-Path $script:MemDir 'memory_state.json'))) {
    $st.msgOff = $(if ($mf) { $mf.Length } else { 0 }); $st.chatOff = $(if ($cf) { $cf.Length } else { 0 }); $st.lastRun = (Get-Date).ToString('s'); Save-MemState $st; return $null
  }
  if (-not (($mf -and $mf.Length -gt [long]$st.msgOff) -or ($cf -and $cf.Length -gt [long]$st.chatOff))) { return $null }
  $lastW = @(@($mf,$cf) | Where-Object { $_ } | ForEach-Object LastWriteTime | Sort-Object)[-1]
  $sinceRun = if ($st.lastRun) { ((Get-Date) - [datetime]$st.lastRun).TotalMinutes } else { 999 }
  if (-not ((((Get-Date) - $lastW).TotalSeconds -ge 120 -and $sinceRun -ge 2) -or $sinceRun -ge 10)) { return $null }
  $b = Get-MemMaterial
  if (-not $b.items.Count) { $st.msgOff = $b.msgOff; $st.chatOff = $b.chatOff; Save-MemState $st; return $null }
  @{ batch = $b; body = (Build-MemRequest $b.items) }
}
function Complete-BackgroundMemory($d) {
  [void](Add-MemCost $d.usage)
  $r = Apply-MemResult $d.result $d.batch.items
  $s = Get-MemState; $s.msgOff = $d.batch.msgOff; $s.chatOff = $d.batch.chatOff; $s.lastRun = (Get-Date).ToString('s')
  $s | Add-Member lastResult ([pscustomobject]$r) -Force; $s | Add-Member read ([int]$s.read + @($d.batch.items).Count) -Force
  Save-MemState $s; [void](Update-MemCooling)
  $r
}
function Get-BackgroundBrief([datetime]$now) {
  try { $b = (MemU ([IO.File]::ReadAllText((Join-Path $script:V2Data 'brief.json')))) | ConvertFrom-Json
    if ($b.date -eq $now.ToString('yyyy-MM-dd') -and $b.text) { return [string]$b.text } } catch {}
  Get-LocalBrief $now
}
function Invoke-BackgroundProactive($inputData) {
  $now = Get-Date; $result = @{ sent = 0; plan = $null; brief = $null; upcoming = @(Get-Upcoming) }
  if (-not (Get-Feature 'proactive')) { return $result }
  if (Get-Permission 'cloud_text') {
    if (-not $inputData.planBusy) { $pd = Test-PlanDue $now; if ($pd) { $result.plan = @{ days = $pd; body = (Build-PlanRequest $pd.days $now) } } }
    $bt = At $now (Get-RemindCfg).brief; $bf = Join-Path $script:V2Data ("brief_try_" + $now.ToString('yyyyMMdd'))
    if (-not $inputData.briefBusy -and $now -ge $bt.AddMinutes(-10) -and $now -lt $bt.AddHours(2) -and (Get-BackgroundBrief $now) -eq (Get-LocalBrief $now) -and -not (Test-Path $bf)) {
      [IO.File]::WriteAllText($bf,''); $result.brief = Build-BriefRequest $now
    }
  }
  $sent = @(Invoke-ReminderTick $now { param($n) Get-BackgroundBrief $n } -Dnd:([bool](Read-Config).dnd))
  $result.sent = $sent.Count
  if ($sent.Count) {
    $imp = @($sent | Where-Object important) | Select-Object -First 1
    $first = if ($imp) { $imp } else { $sent[0] }
    Write-FileAtomic (Join-Path $script:DataDir 'notice.json') (@{ ts=$now.ToString('o');kind=$(if($imp){'important'}else{'new'});summary="提醒：$($first.text)";seen=$false } | ConvertTo-Json -Compress)
  }
  $result
}

function Invoke-EventCollectionCore {
  $evs = @(Get-NewEvents); if (-not $evs.Count) { return }
  $items = @(Get-ChatItems); $quiet = $false; try { $quiet = Test-Quiet (Get-Date) (Get-RemindCfg) } catch {}
  while ($script:QAsked.Count -and ((Get-Date) - $script:QAsked[0]).TotalMinutes -gt 60) { $script:QAsked.RemoveAt(0) }
  $posted = 0
  foreach ($e in $evs) {
    if ($items | Where-Object { $_.card -and $_.card.key -eq $e.key }) { Set-EventSeen $e.key; continue }   # 同一件事只出一张
    if ([string]$e.类型 -eq '盯着的事') {   # 你让秘书盯着的事有动静了：只告诉你
      $w = Get-Watches -Active | Where-Object { $_.id -eq ([string]$e.指的是).Trim() } | Select-Object -First 1; Set-EventSeen $e.key; if (-not $w) { continue }
      Add-WatchHit $w.id; $wi = Get-ChatItems | Where-Object { $_.card -and $_.card.watchId -eq $w.id } | Select-Object -First 1; if ($wi) { Set-Prop $wi.card 'hits' ($w.hits + 1); Update-ChatItem $wi }
      $hc = Add-ChatItem @{ role = 'ai'; card = @{ kind = 'watchhit'; status = 'open'; key = $e.key; watchId = $w.id; title = "你让我盯着的「$($w.what)」有动静了"; src = '微信'; seen = "$($e.conv)：$($e.原文)"; action = [string]$e.事情; opts = @('知道了', '不用再盯了'); noInput = $true; ts = [string]$e.原文时间 } }
      $hc.card.itemId = $hc.id; Update-ChatItem $hc; Post @{ type = 'item'; item = $hc }; $posted++; continue }
    $b = Build-EventCard $e
    if ($b.kind -eq 'skip') { Set-EventSeen $e.key; continue }
    if ($b.kind -eq 'event' -and $b.card.etype -eq '提醒对方') {   # 你自己已经让秘书定过的（同一个聊天、30 分钟内）就不再出
      $dup = $items | Where-Object { $_.card -and $_.card.kind -eq 'send' -and $_.card.at -and $_.card.who -eq $e.conv -and [Math]::Abs((([datetime]$_.card.at) - ([datetime]$b.card.at)).TotalMinutes) -le 30 }; if ($dup) { Set-EventSeen $e.key; continue } }
    if ($b.kind -eq 'event' -and $b.card.etype -in '改时间', '取消') { $ref = Find-RefCard $items $e.conv $(if ($e.指的是) { [string]$e.指的是 } else { [string]$e.事情 }); if (-not $ref) { if ($b.card.etype -eq '改时间' -and $b.card.at) { $e.类型 = $(if ($e.草稿) { '提醒对方' } else { '叫你做事' }); $b = Build-EventCard $e; if ($b.kind -eq 'skip') { Set-EventSeen $e.key; continue } } else { Set-EventSeen $e.key; continue } } else { $b.card.refItem = $ref.id; $b.card.refText = $(if ($ref.card.action) { $ref.card.action } else { "$($ref.card.atText) 发给 $($ref.card.who)" }) } }   # 改时间但找不到原来那张：按新时间出一张新卡
    if ($b.kind -in 'question', 'pair') { if ($quiet -or $script:QAsked.Count -ge 3) { continue }; [void]$script:QAsked.Add((Get-Date)); $script:AskStats[[string]$e.类型] = [int]$script:AskStats[[string]$e.类型] + 1 }   # 记下每类事件多常需要问你（以后调）
    if ($b.kind -eq 'pair') { $b.card.ts = [string]$e.原文时间; $ti = Add-ChatItem @{ role = 'ai'; card = $b.time }; $ti.card.itemId = $ti.id; Update-ChatItem $ti
      $ai = Add-ChatItem @{ role = 'ai'; card = $b.card }; $ai.card.itemId = $ai.id; $ai.card.timeItem = $ti.id; Set-Prop $ai.card 'result' @(@{ ok = $true; text = '等你选时间' }); Update-ChatItem $ai; $ti.card.actItem = $ai.id; Update-ChatItem $ti
      Post @{ type = 'item'; item = $ti }; Post @{ type = 'item'; item = $ai }; Set-EventSeen $e.key; $posted++; continue }   # 先不标记看过：等安静时段过了 / 下个小时再问
    $b.card.ts = [string]$e.原文时间
    $ci = Add-ChatItem @{ role = 'ai'; card = $b.card }; $ci.card.itemId = $ci.id; Update-ChatItem $ci
    $rule = Get-CardRule $ci.card   # 设置 → 秘书可以自己做的事
    if ($rule -eq 'do') { Set-Prop $ci.card 'auto' $true; Update-ChatItem $ci; Post @{type='item';item=$ci}; [void]$script:BgAutoChoices.Add([string]$ci.id) }
    elseif ($rule -eq 'tell') { $ci.card.status = 'closed'; Set-Prop $ci.card 'result' @(@{ ok = $true; text = '只告诉你一声，按你的设置没有安排' }); Update-ChatItem $ci; Post @{ type = 'item'; item = $ci } }
    else { Post @{ type = 'item'; item = $ci } }
    Set-EventSeen $e.key; $posted++
  }
  if ($posted -and -not $quiet) { Show-Notice $(if ($posted -eq 1) { '聊天里有一件带时间的事，等你看一眼' } else { "聊天里有 $posted 件带时间的事，等你看一眼" }) } }
