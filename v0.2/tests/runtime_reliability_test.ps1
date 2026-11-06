# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 合成测试：后台调度、代次隔离、队列上限、取消、纯数字日志、严格重启判定。
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. (Join-Path $v2 'lib_后台任务.ps1')
$script:pass = 0; $script:fail = 0
function Check([string]$Name,[bool]$Ok) { if ($Ok) { $script:pass++ } else { $script:fail++ }; Write-Output ("[{0}] {1}" -f $(if ($Ok) {'PASS'} else {'FAIL'}),$Name) }
function Drain([int]$Timeout = 8000) { $clock=[Diagnostics.Stopwatch]::StartNew(); while ((Test-SecWorkPending) -and $clock.ElapsedMilliseconds -lt $Timeout) { Step-SecWork; Start-Sleep -Milliseconds 5 }; if(Test-SecWorkPending){throw 'test worker timeout'} }
$testRoot = Join-Path $env:TEMP ('secretary_runtime_' + [guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
  # Baseline reproduction: the actual UI Step wrapper executes its body synchronously.
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $v2 '秘书.ps1'),[ref]$null,[ref]$null)
  $stepAst = $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Step'},$true) | Select-Object -First 1
  . ([scriptblock]::Create($stepAst.Extent.Text))
  $script:StepStats = @{}; $script:stepWarned = @{}
  function Write-ErrorLog {}; function Show-Problem {}
  $clock=[Diagnostics.Stopwatch]::StartNew(); Step 'synthetic' { Start-Sleep -Milliseconds 200 }; $clock.Stop()
  Check 'synchronous_body_reproduces_over100' ($clock.ElapsedMilliseconds -ge 150)

  $script:results = New-Object System.Collections.ArrayList
  $script:uiThread = [Threading.Thread]::CurrentThread.ManagedThreadId; $script:callbackThread = 0
  $payload=@{ value=42 }
  $clock.Restart(); $accepted=Start-SecWork -Key 'slow' -Code 'param($d) Start-Sleep -Milliseconds 200; @{ value=$d.value; thread=[Threading.Thread]::CurrentThread.ManagedThreadId }' -InputObject $payload -Then {param($r) $script:callbackThread=[Threading.Thread]::CurrentThread.ManagedThreadId; [void]$script:results.Add($r)}; $clock.Stop()
  # 计时判断：取几次的中位数；在 CI 或电脑很忙（CPU ≥ 60%）时放宽到 180 ms。放宽后仍低于后台工作本身的 200 ms，真的在界面线程上同步跑还是会被抓出来
  $busy = [bool]($env:CI -or $env:GITHUB_ACTIONS) -or ($(try { [int](Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object LoadPercentage -Average).Average } catch { 0 }) -ge 60)
  $limitMs = if ($busy) { 180 } else { 100 }
  function Median([long[]]$xs) { $s = @($xs | Sort-Object); $s[[int][Math]::Floor(($s.Count - 1) / 2)] }
  $submitMs = New-Object System.Collections.Generic.List[long]; $submitMs.Add($clock.ElapsedMilliseconds)
  foreach ($n in 1..4) { $clock.Restart(); [void](Start-SecWork -Key "probe$n" -Code 'param($d) $d' -InputObject @{ n = $n } -Then { param($r) }); $clock.Stop(); $submitMs.Add($clock.ElapsedMilliseconds) }
  Check "submit_under$limitMs (median of 5: $(Median $submitMs.ToArray()) ms; busy=$busy)" ($accepted -and (Median $submitMs.ToArray()) -lt $limitMs)
  $payload.value=99
  $maxPoll=0; $polls=New-Object System.Collections.Generic.List[long]; $timeout=[Diagnostics.Stopwatch]::StartNew()
  while ((Test-SecWorkPending) -and $timeout.ElapsedMilliseconds -lt 8000) { $clock.Restart(); Step-SecWork; $clock.Stop(); $maxPoll=[Math]::Max($maxPoll,$clock.ElapsedMilliseconds); $polls.Add($clock.ElapsedMilliseconds); Start-Sleep -Milliseconds 5 }
  Check 'slow_work_returns_correct_snapshot' (@($script:results | Where-Object { $_.data.value -eq 42 -or $_.data.value -eq 99 }).Count -eq 1 -and $script:results[0].ok -and $script:results[0].data.value -eq 42)
  Check "poll_during_slow_read (median $(Median $polls.ToArray()) ms, worst $maxPoll ms, limit $limitMs ms)" ((Median $polls.ToArray()) -lt $limitMs -and $maxPoll -lt 180)
  Check 'callback_returns_to_original_thread' ($script:callbackThread -eq $script:uiThread -and $script:results[0].data.thread -ne $script:uiThread)

  $moduleFile=Join-Path $testRoot 'synthetic_module.ps1'
  [IO.File]::WriteAllText($moduleFile,'$script:SyntheticCounter=0; function Read-SyntheticCounter { $script:SyntheticCounter++; $script:SyntheticCounter }')
  $script:results.Clear()
  [void](Start-SecWork -Key 'module1' -Modules @($moduleFile) -Code 'Read-SyntheticCounter' -Then {param($r)[void]$script:results.Add($r.data)}); Drain
  [void](Start-SecWork -Key 'module2' -Modules @($moduleFile) -Code 'Read-SyntheticCounter' -Then {param($r)[void]$script:results.Add($r.data)}); Drain
  Check 'module_loaded_once_and_script_state_persists' ($script:results.Count -eq 2 -and $script:results[0] -eq 1 -and $script:results[1] -eq 2)
  $script:results.Clear()
  [void](Start-SecWork -Key 'versioned' -Code 'param($d) Start-Sleep -Milliseconds 150; $d.value' -InputObject @{value=1} -Then {param($r)[void]$script:results.Add($r.data)})
  Step-SecWork
  Check 'same_key_deduplicated' (-not (Start-SecWork -Key 'versioned' -Code '2'))
  [void](Start-SecWork -Key 'versioned' -Replace -Code 'param($d) $d.value' -InputObject @{value=2} -Then {param($r)[void]$script:results.Add($r.data)})
  Drain
  Check 'stale_generation_not_applied' ($script:results.Count -eq 1 -and $script:results[0] -eq 2 -and $script:SecWorkStats.discarded -ge 1)

  $script:results.Clear()
  [void](Start-SecWork -Key 'timeout' -TimeoutMs 50 -Code 'Start-Sleep -Milliseconds 1000; 1' -Then {param($r)[void]$script:results.Add($r)})
  Drain
  Check 'timeout_reports_failure' ($script:results.Count -eq 1 -and -not $script:results[0].ok -and $script:results[0].error_type -eq 'timeout')
  [void](Start-SecWork -Key 'cancel' -Code 'Start-Sleep -Milliseconds 1000; 1' -Then {throw 'cancelled callback must not run'})
  Step-SecWork; $clock.Restart(); Cancel-SecWork 'cancel'; $clock.Stop()
  Check "cancel_request_under$limitMs ($($clock.ElapsedMilliseconds) ms)" ($clock.ElapsedMilliseconds -lt $limitMs)
  Drain
  Check 'cancelled_work_drained' (-not (Test-SecWorkPending))

  $script:SecWorkLimit=2
  [void](Start-SecWork -Key 'one' -Code '1'); [void](Start-SecWork -Key 'two' -Code '2')
  Check 'bounded_queue_rejects_excess' (-not (Start-SecWork -Key 'three' -Code '3'))
  Cancel-SecWork 'one'; Cancel-SecWork 'two'; $script:SecWorkLimit=16

  $script:SecUiTiming=@{}
  Add-SecUiTiming 'fixed_test_step' 12; Add-SecUiTiming 'fixed_test_step' 120 $true
  $log=Join-Path $testRoot 'ui_steps.jsonl'; [void](Flush-SecUiTiming $log -Force); Drain
  $records=@(Get-Content -LiteralPath $log | ForEach-Object {$_|ConvertFrom-Json}); $r=$records[-1]
  Check 'timing_aggregates_persist' ($r.count -eq 2 -and $r.over100 -eq 1 -and $r.errors -eq 1 -and $r.max_ms -eq 120)
  Check 'timing_contains_no_text_or_paths' ((Get-Content -LiteralPath $log -Raw) -notmatch 'fixed_test_step|secretary_runtime_|message|window')

  $restart=Join-Path $v2 'tools\重启秘书.ps1'
  $ra=[Management.Automation.Language.Parser]::ParseFile($restart,[ref]$null,[ref]$null)
  foreach($fn in $ra.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($fn.Extent.Text))}
  $root='C:\Synthetic\Secretary\v0.2'; $main=@{Name='powershell.exe';ProcessId=11;CommandLine='powershell -File "C:\Synthetic\Secretary\v0.2\秘书.ps1"';ExecutablePath='C:\Windows\powershell.exe'}
  $other=@{Name='powershell.exe';ProcessId=12;CommandLine='powershell -File "C:\Other\v0.2\秘书.ps1"';ExecutablePath='C:\Windows\powershell.exe'}
  $sender=@{Name='powershell.exe';ProcessId=13;CommandLine='powershell -File "C:\Synthetic\Secretary\v0.2\发送.ps1"';ExecutablePath='C:\Windows\powershell.exe'}
  $active=@{pid=11;clean=$false}; $closed=@{pid=11;clean=$true;how='user-quit'}
  $plan=Get-SecretaryRestartPlan @($main,$other) $active $root $false $false 99
  Check 'restart_scoped_to_exact_project' ($plan.allowed -and $plan.pids.Count -eq 1 -and $plan.pids[0] -eq 11)
  Check 'restart_denied_when_sending' (-not (Get-SecretaryRestartPlan @($main,$sender) $active $root $false $false 99).allowed)
  Check 'restart_denied_when_busy_flag' (-not (Get-SecretaryRestartPlan @($main) $active $root $true $false 99).allowed)
  Check 'startonly_cannot_override_user_exit' (-not (Get-SecretaryRestartPlan @() $closed $root $false $true 99).allowed)
  Check 'restart_requires_recorded_state' (-not (Get-SecretaryRestartPlan @() $null $root $false $true 99).allowed)
  Check 'recorded_crash_can_use_startonly' ((Get-SecretaryRestartPlan @() $active $root $false $true 99).allowed)
  Check 'normal_restart_does_not_open_inactive_app' (-not (Get-SecretaryRestartPlan @() $active $root $false $false 99).allowed)
  $source=Get-Content -LiteralPath $restart -Raw
  Check 'restart_uses_explorer_and_sender_lease' ($source -match 'Start-Process explorer.exe -WindowStyle Hidden' -and $source -match 'Enter-SendLease' -and $source -match 'finally \{ Exit-SendLease')
} finally {
  Stop-SecWorkers
  $resolved=[IO.Path]::GetFullPath($testRoot); $tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
  if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('secretary_runtime_')) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Output "runtime_reliability_test: $script:pass pass, $script:fail fail"
if ($script:fail) { exit 1 }