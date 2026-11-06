# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
param([switch]$Worker, [string]$DataRoot, [int]$WriterId = 0, [int]$Records = 40, [string]$Mode = 'write')
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. (Join-Path $v2 'lib_版本.ps1')
if ($Worker) {
  $script:V2Data = $DataRoot
  . (Join-Path $v2 'lib_质量.ps1')
  function Get-SecretaryProcs { @{} }
  function Get-CimInstance { @() }
  [IO.File]::WriteAllText((Join-Path $DataRoot ('ready-' + $WriterId)), '1')
  $until = (Get-Date).AddSeconds(15)
  while (-not (Test-Path -LiteralPath (Join-Path $DataRoot 'go'))) { if ((Get-Date) -gt $until) { exit 8 }; Start-Sleep -Milliseconds 10 }
  if ($Mode -eq 'timeout') {
    $caught = $false
    try { Add-SecretaryLogLines -Path (Join-Path $DataRoot 'quality.jsonl') -Lines @('{"ev":"synthetic","n":-1}') -TimeoutMs 100 }
    catch [TimeoutException] { $caught = $true }
    [IO.File]::WriteAllText((Join-Path $DataRoot 'timeout-result'), [string]$caught)
    if ($caught) { exit 0 } else { exit 9 }
  }
  for ($i = 0; $i -lt $Records; $i++) {
    Write-Quality @{ ev = 'synthetic'; id = ($WriterId * 1000 + $i); n = 1 }
    [void](Write-ReliabilityVersionMark -DataPath $DataRoot -Component 'worker' -Version 'concurrent-1')
    [void](Write-ResourceSample @{ synthetic = $true; id = ($WriterId * 1000 + $i) })
  }
  exit 0
}
$testBase = Join-Path (Split-Path $v2 -Parent) 'review\test-temp'
$dir = Join-Path $testBase ('secretary_revision_' + [guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($dir)
$pass=0;$fail=0
function Check($id,$ok){if($ok){$script:pass++}else{$script:fail++};'[{0}] {1}' -f $(if($ok){'PASS'}else{'FAIL'}),$id}
$procs = @(); $heldLock = $null; $heldStream = $null
function Start-Writer([string]$Root, [int]$Id, [string]$TestMode = 'write') {
  $args2 = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'),'-Worker','-DataRoot',('"' + $Root + '"'),'-WriterId',[string]$Id,'-Mode',$TestMode)
  Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList $args2
}
function Wait-Ready([string]$Root, [int]$Count) {
  $until=(Get-Date).AddSeconds(20)
  while (@(Get-ChildItem -LiteralPath $Root -Filter 'ready-*' -File).Count -lt $Count) { if ((Get-Date) -gt $until) { throw 'Synthetic writer readiness timeout.' }; Start-Sleep -Milliseconds 20 }
}
try {
  $path=Join-Path $dir 'quality.jsonl';$prefix='{"ev":"synthetic","n":9}'+"`r`n"
  [IO.File]::WriteAllText($path,$prefix,[Text.UTF8Encoding]::new($false))
  Check 'revision-first' (Write-ReliabilityVersionMark $dir 'main' 'test-1')
  Check 'revision-once' (-not (Write-ReliabilityVersionMark $dir 'main' 'test-1'))
  Check 'revision-component' (Write-ReliabilityVersionMark $dir 'watcher' 'test-1')
  Check 'revision-next' (Write-ReliabilityVersionMark $dir 'main' 'test-2')
  Check 'existing-log-prefix' ([IO.File]::ReadAllText($path).StartsWith($prefix))
  Check 'append-only-count' (@([IO.File]::ReadAllLines($path)).Count -eq 4)
  Check 'same-full-path-same-lock' ((Get-SecretaryLogMutexName $path) -eq (Get-SecretaryLogMutexName $path.ToUpperInvariant()))
  $parallel=Join-Path $dir 'parallel';[void][IO.Directory]::CreateDirectory($parallel)
  $parallelPath=Join-Path $parallel 'quality.jsonl';[IO.File]::WriteAllText($parallelPath,$prefix,[Text.UTF8Encoding]::new($false))
  $heldLock=Enter-SecretaryLogLock $parallelPath
  $heldStream=[IO.FileStream]::new($parallelPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
  for($i=1;$i-le4;$i++){$procs+=Start-Writer $parallel $i}
  Wait-Ready $parallel 4
  [IO.File]::WriteAllText((Join-Path $parallel 'go'),'1')
  Start-Sleep -Milliseconds 300
  Check 'writers-wait-during-log-lock' (@($procs|Where-Object HasExited).Count -eq 0)
  $heldStream.Dispose();$heldStream=$null;$heldLock.ReleaseMutex();$heldLock.Dispose();$heldLock=$null
  foreach($p in $procs){if(-not$p.WaitForExit(20000)){throw 'Synthetic writer completion timeout.'}}
  Check 'four-writers-exit-successfully' (@($procs|Where-Object ExitCode -ne 0).Count-eq0)
  $all=@([IO.File]::ReadAllLines($parallelPath)|ForEach-Object{$_|ConvertFrom-Json})
  $events=@($all|Where-Object{ $_.ev-eq'synthetic' -and $null-ne$_.id })
  Check '160-concurrent-events-no-loss' ($events.Count-eq160)
  Check '160-event-ids-no-duplicates' (@($events|Select-Object -ExpandProperty id -Unique).Count-eq160)
  Check 'one-concurrent-revision-only' (@($all|Where-Object ev -eq 'revision').Count-eq1)
  Check 'concurrent-log-prefix-unchanged' ([IO.File]::ReadAllText($parallelPath).StartsWith($prefix))
  $resources=@([IO.File]::ReadAllLines((Join-Path $parallel 'resources.jsonl'))|ForEach-Object{$_|ConvertFrom-Json})
  Check '160-resource-records-no-loss' ($resources.Count-eq160-and@($resources|Select-Object -ExpandProperty id -Unique).Count-eq160)
  $timeoutDir=Join-Path $dir 'timeout';[void][IO.Directory]::CreateDirectory($timeoutDir)
  $timeoutPath=Join-Path $timeoutDir 'quality.jsonl';$heldLock=Enter-SecretaryLogLock $timeoutPath
  $tp=Start-Writer $timeoutDir 1 'timeout';$procs+= $tp;Wait-Ready $timeoutDir 1
  [IO.File]::WriteAllText((Join-Path $timeoutDir 'go'),'1')
  if(-not$tp.WaitForExit(10000)){throw 'Synthetic timeout worker did not exit.'}
  Check 'lock-timeout-is-visible' ($tp.ExitCode-eq0-and([IO.File]::ReadAllText((Join-Path $timeoutDir 'timeout-result'))-eq'True'))
  Check 'timeout-does-not-fake-a-record' (-not(Test-Path -LiteralPath $timeoutPath))
  $heldLock.ReleaseMutex();$heldLock.Dispose();$heldLock=$null
  . (Join-Path $v2 'lib_质量.ps1')
  $badDir=Join-Path $dir 'blocked';[void][IO.Directory]::CreateDirectory((Join-Path $badDir 'quality.jsonl'));$script:V2Data=$badDir
  $caught=$false;try{Write-Quality @{ev='synthetic';id=1}}catch{$caught=$true}
  Check 'write-error-is-visible' $caught
  $item=[pscustomobject]@{id='synthetic-retry';ts=(Get-Date).ToString('s');card=[pscustomobject]@{kind='send';status='open';failed=$false;cancelled=$false}}
  $caught=$false;try{Write-QualityCard $item}catch{$caught=$true}
  Check 'failed-card-append-remains-retryable' ($caught-and-not$script:QualCardSeen.ContainsKey('synthetic-retry'))
  $script:V2Data=Join-Path $dir 'retry';Write-QualityCard $item;Write-QualityCard $item
  Check 'retried-card-written-once' (@([IO.File]::ReadAllLines((Join-Path $script:V2Data 'quality.jsonl'))).Count-eq1)
  $tail=Join-Path $dir 'unterminated.jsonl';$old='{"ev":"synthetic","n":7}'
  [IO.File]::WriteAllText($tail,$old,[Text.UTF8Encoding]::new($false));Add-SecretaryLogLines $tail @('{"ev":"synthetic","n":8}')
  Check 'unterminated-prefix-preserved-and-separated' ([IO.File]::ReadAllText($tail).StartsWith($old)-and@([IO.File]::ReadAllLines($tail)|ForEach-Object{$_|ConvertFrom-Json}).Count-eq2)
} finally {
  if($heldStream){$heldStream.Dispose()};if($heldLock){$heldLock.ReleaseMutex();$heldLock.Dispose()}
  foreach($p in $procs){if(-not$p.HasExited){$p.Kill();[void]$p.WaitForExit(3000)}}
  $resolved=[IO.Path]::GetFullPath($dir);$tempBase=[IO.Path]::GetFullPath($testBase).TrimEnd('\')+'\'
  if($resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)-and([IO.Path]::GetFileName($resolved)-like 'secretary_revision_*')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
'revision_reliability_test: {0} pass, {1} fail' -f $pass,$fail
if($fail){exit 1}
