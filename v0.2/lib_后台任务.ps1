# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 可靠性修改：只把 JSON 值送进串行后台，界面线程只提交和接收已完成结果。
# Start-SecWork 不执行输入代码；Then 始终由调用 Step-SecWork 的界面线程执行。
$script:SecWorkQueue = New-Object System.Collections.ArrayList
$script:SecWorkGenerations = @{}
$script:SecWorkActive = $null
$script:SecWorkPool = $null
$script:SecWorkPoolOpen = $null
$script:SecWorkLimit = 16
$script:SecUiTiming = @{}
$script:SecUiFlushAt = [datetime]::MinValue
$script:SecWorkStats = @{ completed = 0; discarded = 0; timedout = 0; rejected = 0; failed = 0 }

function Start-SecWork {
  param([Parameter(Mandatory=$true)][string]$Key,
    [Parameter(Mandatory=$true)][string]$Code, $InputObject = $null,
    [string[]]$Modules = @(), [scriptblock]$Then = $null,
    [int]$TimeoutMs = 60000, [switch]$Replace)
  if ($Key -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'worker key must be a fixed identifier' }
  $queued = @($script:SecWorkQueue | Where-Object { $_.key -eq $Key })
  $running = $script:SecWorkActive -and $script:SecWorkActive.key -eq $Key
  if (($queued.Count -or $running) -and -not $Replace) { return $false }
  if (-not $queued.Count -and $script:SecWorkQueue.Count -ge $script:SecWorkLimit) { $script:SecWorkStats.rejected++; return $false }
  # Serialize now, so a caller changing its hashtable cannot mutate a submitted job.
  $inputJson = ConvertTo-Json -InputObject $InputObject -Depth 30 -Compress
  $gen = [long]$script:SecWorkGenerations[$Key] + 1
  $script:SecWorkGenerations[$Key] = $gen
  foreach ($old in $queued) { [void]$script:SecWorkQueue.Remove($old) }
  $job = @{ key = $Key; generation = $gen; code = $Code; inputJson = $inputJson; modules = @($Modules); then = $Then; timeout = [Math]::Max(10,$TimeoutMs) }
  [void]$script:SecWorkQueue.Add($job)
  $true
}

function Cancel-SecWork([string]$Key) {
  $script:SecWorkGenerations[$Key] = [long]$script:SecWorkGenerations[$Key] + 1
  foreach ($j in @($script:SecWorkQueue | Where-Object { $_.key -eq $Key })) { [void]$script:SecWorkQueue.Remove($j) }
  $a = $script:SecWorkActive
  if ($a -and $a.key -eq $Key -and -not $a.stopHandle -and -not $a.handle.IsCompleted) {
    $a.cancelled = $true
    try { $a.stopHandle = $a.ps.BeginStop($null,$null) } catch {}
  }
}

function Step-SecWork {
  $a = $script:SecWorkActive
  if ($a) {
    if (-not $a.handle.IsCompleted) {
      if (-not $a.stopHandle -and $a.clock.ElapsedMilliseconds -ge $a.timeout) {
        $a.timedout = $true; $script:SecWorkStats.timedout++
        try { $a.stopHandle = $a.ps.BeginStop($null,$null) } catch {}
      }
      # Never call Stop/EndInvoke/Dispose until the asynchronous invocation completes.
      # A timed-out native call still owns this lane; do not run another writer concurrently.
      return
    }
    $result = $null
    try { $raw = @($a.ps.EndInvoke($a.handle)); if ($raw.Count) { $result = ([string]$raw[-1] | ConvertFrom-Json) } }
    catch { $result = [pscustomobject]@{ ok = $false; data = $null; error_type = $_.Exception.GetType().Name } }
    finally { if ($a.stopHandle -and $a.stopHandle.IsCompleted) { try { $a.ps.EndStop($a.stopHandle) } catch {} }; $a.ps.Dispose(); $script:SecWorkActive = $null }
    if ($a.timedout) { $result = [pscustomobject]@{ ok = $false; data = $null; error_type = 'timeout' } }
    if (-not $result) { $result = [pscustomobject]@{ ok = $false; data = $null; error_type = 'empty_result' } }
    $result | Add-Member -NotePropertyName elapsed_ms -NotePropertyValue $a.clock.ElapsedMilliseconds -Force
    $result | Add-Member -NotePropertyName generation -NotePropertyValue $a.generation -Force
    $result | Add-Member -NotePropertyName key -NotePropertyValue $a.key -Force
    if ($a.generation -eq $script:SecWorkGenerations[$a.key] -and -not $a.cancelled) {
      $script:SecWorkStats.completed++
      if (-not $result.ok) { $script:SecWorkStats.failed++ }
      if ($a.then) { & $a.then $result }
    } else { $script:SecWorkStats.discarded++ }
  }
  if (-not $script:SecWorkQueue.Count) { return }
  if (-not $script:SecWorkPool) {
    $script:SecWorkPool = [runspacefactory]::CreateRunspacePool(1,1)
    $script:SecWorkPool.ApartmentState = 'STA'
    $script:SecWorkPoolOpen = $script:SecWorkPool.BeginOpen($null,$null)
    return
  }
  if ($script:SecWorkPoolOpen) {
    if (-not $script:SecWorkPoolOpen.IsCompleted) { return }
    $script:SecWorkPool.EndOpen($script:SecWorkPoolOpen); $script:SecWorkPoolOpen = $null
  }
  $j = $script:SecWorkQueue[0]; $script:SecWorkQueue.RemoveAt(0)
  if ($j.generation -ne $script:SecWorkGenerations[$j.key]) { $script:SecWorkStats.discarded++; return }
  $ps = [powershell]::Create(); $ps.RunspacePool = $script:SecWorkPool
  $wrapper = {
    param([string]$body,[string]$json,[string[]]$paths)
    $ErrorActionPreference = 'Stop'
    try {
      if (-not $global:SecWorkLoadedModules) { $global:SecWorkLoadedModules = @{} }
      foreach ($modulePath in $paths) {
        if (-not $global:SecWorkLoadedModules[$modulePath]) { $null = . $modulePath; $global:SecWorkLoadedModules[$modulePath] = $true }
      }
      $inputData = if ($json -and $json -ne 'null') { $json | ConvertFrom-Json } else { $null }
      $value = & ([scriptblock]::Create($body)) $inputData
      @{ ok = $true; data = $value; error_type = '' } | ConvertTo-Json -Depth 30 -Compress
    } catch { @{ ok = $false; data = $null; error_type = $_.Exception.GetType().Name } | ConvertTo-Json -Compress }
  }
  [void]$ps.AddScript($wrapper.ToString()).AddArgument($j.code).AddArgument($j.inputJson).AddArgument([string[]]$j.modules)
  $j.ps = $ps; $j.clock = [Diagnostics.Stopwatch]::StartNew(); $j.handle = $ps.BeginInvoke()
  $j.stopHandle = $null; $j.timedout = $false; $j.cancelled = $false
  $script:SecWorkActive = $j
}

function Test-SecWorkPending([string]$Key = '') {
  if ($Key) { return [bool](($script:SecWorkActive -and $script:SecWorkActive.key -eq $Key) -or @($script:SecWorkQueue | Where-Object { $_.key -eq $Key }).Count) }
  [bool]($script:SecWorkActive -or $script:SecWorkQueue.Count)
}
function Add-SecUiTiming([string]$Name,[double]$Milliseconds,[bool]$Failed = $false) {
  # Fixed step names only; persisted identifiers are hashes, never message/window text.
  $key = $Name
  if (-not $script:SecUiTiming.ContainsKey($key)) { $script:SecUiTiming[$key] = @{ count = 0; total_ms = 0.0; max_ms = 0.0; over100 = 0; errors = 0 } }
  $r = $script:SecUiTiming[$key]; $r.count++; $r.total_ms += $Milliseconds
  if ($Milliseconds -gt $r.max_ms) { $r.max_ms = $Milliseconds }; if ($Milliseconds -gt 100) { $r.over100++ }; if ($Failed) { $r.errors++ }
}
function Flush-SecUiTiming([string]$Path,[switch]$Force) {
  if (-not $script:SecUiTiming.Count -or (-not $Force -and (Get-Date) -lt $script:SecUiFlushAt)) { return $false }
  $rows = @(foreach ($kv in $script:SecUiTiming.GetEnumerator()) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $id = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($kv.Key)))).Replace('-','').Substring(0,12) } finally { $sha.Dispose() }
    @{ ts = (Get-Date).ToString('s'); step = $id; count = $kv.Value.count; total_ms = [Math]::Round($kv.Value.total_ms,3); max_ms = [Math]::Round($kv.Value.max_ms,3); over100 = $kv.Value.over100; errors = $kv.Value.errors }
  })
  $ok = Start-SecWork -Key 'ui-metrics' -InputObject @{ path = $Path; rows = $rows } -Code {
    param($d)
    $lines = [string[]]@($d.rows | ForEach-Object { $_ | ConvertTo-Json -Compress })
    if ($lines.Length) { [IO.File]::AppendAllLines([string]$d.path,$lines,(New-Object Text.UTF8Encoding $false)) }
    @{ count = $lines.Length }
  }.ToString()
  if ($ok) { $script:SecUiTiming = @{}; $script:SecUiFlushAt = (Get-Date).AddSeconds(30) }
  $ok
}
function Stop-SecWorkers {
  foreach ($key in @($script:SecWorkGenerations.Keys)) { Cancel-SecWork $key }
  # Process shutdown owns final disposal. BeginClose is asynchronous and cannot hold the UI.
  if ($script:SecWorkPool) { try { [void]$script:SecWorkPool.BeginClose($null,$null) } catch {} }
}
