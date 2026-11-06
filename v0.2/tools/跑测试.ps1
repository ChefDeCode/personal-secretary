# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 所有后台用例在独立代码/合成数据副本执行；不接触真实配置、消息或密钥。
# 前台/native用例单列待测，本脚本不会自动运行任何真实微信操作。
param([switch]$Foreground,[switch]$Now,[string[]]$Only)
$ErrorActionPreference='Stop'
$v2=Split-Path $PSScriptRoot -Parent; $product=Split-Path $v2 -Parent
$Only=@($Only|ForEach-Object{$_ -split ','}|ForEach-Object{$_.Trim()}|Where-Object{$_})
if($Only -contains 'picker_test'){throw 'picker_test is permanently disabled'}
$stamp=(Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('n').Substring(0,6)
$runRoot=Join-Path $v2 ('data\test-runs\'+$stamp)
$copyRoot=Join-Path $runRoot 'project'
[void][IO.Directory]::CreateDirectory($copyRoot)
$oldTemp=$env:TEMP;$oldTmp=$env:TMP
$env:TEMP=Join-Path $runRoot 'temp';$env:TMP=$env:TEMP;[void][IO.Directory]::CreateDirectory($env:TEMP)
$background=@('code_check_test','queue_incremental_test','uninstall_test', 'device_name_test', 'install_register_test','ghost_fg_test','quality_test','quote_name_test','sources_test','old_config_test','att_cap_test','reminder_resolved_test','layout_test','window_state_test','activity_test','events_test','schedule_test','retry_cancel_test','roundtrip_test','rules_test','replied_test','older_chat_test','stability_test','stale_result_test','send_guard_test','files_test','people_test','guard_test','extract_speaker_test','speaker_test','plugin_format_test','update_test','account_test','ai_provider_test','plugin_watch_test','mail_watch_test','web_watch_test','folder_source_test','mail_uia_test','web_source_test','live_noaccount_test','live_account_test','verify_official_plugins')
$background += @(Get-ChildItem -LiteralPath (Join-Path $v2 'tests') -Filter '*_reliability_test.ps1' -File | ForEach-Object{$_.BaseName})
$background=@($background|Select-Object -Unique)
$unknown=@($Only|Where-Object {$background -notcontains $_});if($unknown.Count){throw ('Unknown or disabled test group count: '+$unknown.Count)}
$held=@('guard_test_foreground_original','plugin_watch_test_foreground_original','mail_watch_test_foreground_original','web_watch_test_foreground_original','mail_uia_test_foreground_original','web_source_test_foreground_original','layout_native','updater_process_native','pdf_winrt_native','wechat_minimized','wechat_tray','unlock','resume')
function Invoke-IsolatedTest([string]$name){
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $file=Join-Path $copyRoot ('v0.2\tests\'+$name+'.ps1')
  $native=Join-Path $PSHOME 'powershell.exe'
  if(-not (Test-Path -LiteralPath $native)){$native=(Get-Command powershell.exe).Source}
  # Only this runner's child receives a lower scheduling priority.
  $launcher=Join-Path $runRoot 'launch-test.ps1'
  if(-not (Test-Path -LiteralPath $launcher)){
    $launchText=@'
param([string]$TestFile)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$global:LASTEXITCODE=0
& $TestFile
$testSucceeded=$?
$testExit=$LASTEXITCODE
if(-not $testSucceeded){if($testExit){exit $testExit};exit 1}
exit 0
'@
    [IO.File]::WriteAllText($launcher,$launchText,[Text.UTF8Encoding]::new($true))
  }
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$native
  $psi.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$launcher+'" -TestFile "'+$file+'"'
  $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle='Hidden'
  $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  $psi.StandardOutputEncoding=[Text.Encoding]::UTF8;$psi.StandardErrorEncoding=[Text.Encoding]::UTF8
  $child=New-Object Diagnostics.Process;$child.StartInfo=$psi
  $output='';$exitCode=1;$childId=0
  try{
    [void]$child.Start();$childId=$child.Id
    try{$child.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal}catch{
      if(-not $child.HasExited){$child.Kill()};throw 'Could not lower owned test process priority'
    }
    [IO.File]::WriteAllText((Join-Path $runRoot 'active.json'),(@{pid=$childId;group=$name;active=$true}|ConvertTo-Json -Compress))
    $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(180000)){$child.Kill();$child.WaitForExit();$exitCode=124}else{$exitCode=$child.ExitCode}
    $output=$stdout.GetAwaiter().GetResult()+[Environment]::NewLine+$stderr.GetAwaiter().GetResult()
  }finally{
    [IO.File]::WriteAllText((Join-Path $runRoot 'active.json'),(@{pid=$childId;group=$name;active=$false}|ConvertTo-Json -Compress))
    $child.Dispose()
  }
  [IO.File]::WriteAllText((Join-Path $runRoot ($name+'.diagnostic.txt')),$output,[Text.UTF8Encoding]::new($true))
  $passed=([regex]::Matches($output,'\[PASS\]')).Count;$failed=([regex]::Matches($output,'\[FAIL\]')).Count
  if(-not $passed -and -not $failed){$m=[regex]::Match($output,'(\d+) pass, (\d+) fail');if($m.Success){$passed=[int]$m.Groups[1].Value;$failed=[int]$m.Groups[2].Value}}
  if(-not $passed -and -not $failed){$m=[regex]::Match($output,'RESULT: (\d+) / (\d+)');if($m.Success){$passed=[int]$m.Groups[1].Value;$failed=[int]$m.Groups[2].Value-$passed}}
  $status='passed'
  if($exitCode -eq 53 -and $output -match '\[SERVER530\] status=530'){$status='server530'}
  elseif($exitCode -eq 54 -and $output -match '\[ENVIRONMENT\]'){$status='environment'}
  elseif($exitCode -ne 0 -or $failed -gt 0 -or -not $passed){$status='failed'}
  $index=0;$failedAt=@();foreach($m in [regex]::Matches($output,'\[(PASS|FAIL)\]')){$index++;if($m.Groups[1].Value -eq 'FAIL'){$failedAt+=$index}}
  $diagnostics=@([regex]::Matches($output,'(?m)^(SYNTAX|COMMENT) ([^\r\n]+)$')|ForEach-Object{$_.Value})
  [pscustomobject]@{name=$name;pass=$passed;fail=$failed;exit=$exitCode;ms=$sw.ElapsedMilliseconds;status=$status;failed_assertions=$failedAt;diagnostics=$diagnostics;native_pending=($output -match '\[PENDING_NATIVE\]')}
}
$rows=@();$started=Get-Date
try{
  foreach($file in Get-ChildItem -LiteralPath $product -Recurse -File){
    $rel=$file.FullName.Substring($product.Length+1)
    if($rel -match '(^|\\)(data|review|test-runs|旧东西|\.git|node_modules)(\\|$)' -or $rel -match '(^|\\)\.env($|\.)' -or $rel -eq 'config.json' -or $rel -match '\.bak($|_)'){continue}
    $dest=Join-Path $copyRoot $rel;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));[IO.File]::Copy($file.FullName,$dest,$false)
  }
  [void][IO.Directory]::CreateDirectory((Join-Path $copyRoot 'data'))
  [void][IO.Directory]::CreateDirectory((Join-Path $copyRoot 'v0.2\data'))
  # Only the clone's synthetic permissions are set; the user's file is never read or changed.
  $cfg=@{name='synthetic';permissions=@{read_screen=$false;scroll=$false;click_sessions=$false;cloud_images=$false;cloud_text=$true;send_messages=$true};features=@{watch_wechat=$false;watch_folders=$false;watch_outlook=$false};apps=@()}
  [IO.File]::WriteAllText((Join-Path $copyRoot 'config.json'),($cfg|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
  foreach($name in $background){
    if($Only.Count -and $Only -notcontains $name){continue}
    $row=Invoke-IsolatedTest $name;$rows+= $row
    '{0}: pass={1}, fail={2}, exit={3}, status={4}, ms={5}' -f $name,$row.pass,$row.fail,$row.exit,$row.status,$row.ms
    [IO.File]::WriteAllText((Join-Path $runRoot 'results.json'),($rows|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds 200
  }
}finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
# —— 前台测试（会动测试窗口、借用前台、透明地读一下真微信）：只在你说「可以测」以后加 -Foreground 才跑；开始时你没离开 2 分钟就不跑，除非加 -Now
#    在真正的安装目录里跑（要用测试窗口程序）；你一动鼠标键盘，那一组自己停下 → 这里暂停，等你再离开 2 分钟从这一组接着跑；45 分钟没等到空就放弃。永远不跑 picker_test（会打开记事本）
$fgRows=@(); $fgNote='没跑（要跑：你说「可以测」后加 -Foreground）'; $pauses=0
if($Foreground){
  Add-Type 'using System; using System.Runtime.InteropServices; public static class RunIdle2 { [StructLayout(LayoutKind.Sequential)] struct L { public uint cb, t; } [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref L l); public static uint Ms() { var l = new L { cb = 8 }; GetLastInputInfo(ref l); return (uint)Environment.TickCount - l.t; } }'
  $fgList=@('real_input_test','fg_send_test_now','fg_cap_test','fg_queue_test_now','fg_options_test_now','ghost_read_test_now','ghost_all_test','ghost_snap_test','border_when_test','jump_test','file_send_test','float_click_test','picker_test2','own_border_test','store_e2e_test','guard_test_foreground_original','plugin_watch_test_foreground_original','mail_watch_test_foreground_original','web_watch_test_foreground_original','mail_uia_test_foreground_original','web_source_test_foreground_original')
  if(-not $Now -and [RunIdle2]::Ms() -lt 120000){$fgNote='没跑：开始时你没离开电脑 2 分钟（你说了「可以测」就加 -Now）'}
  else{ $fgNote=''
    foreach($name in $fgList){
      if($Only.Count -and $Only -notcontains $name){continue}; $file=Join-Path $v2 ('tests\'+$name+'.ps1'); if(-not (Test-Path -LiteralPath $file)){continue}
      $sw=[Diagnostics.Stopwatch]::StartNew(); $o=''
      for($try=1;$try -le 6;$try++){
        $j=Start-Job -ScriptBlock {param($p) & powershell -NoProfile -STA -ExecutionPolicy Bypass -File $p 2>&1 | Out-String} -ArgumentList $file
        $o=if(Wait-Job $j -Timeout 420){Receive-Job $j}else{Stop-Job $j;'TIMEOUT'}; Remove-Job $j -Force
        if($o -match '检测到你动|用户输入，已停|你动了鼠标' -and $try -lt 6){ $pauses++; $since=Get-Date; while([RunIdle2]::Ms() -lt 120000){ if(((Get-Date)-$since).TotalMinutes -gt 45){break}; Start-Sleep -Seconds 2 }; if([RunIdle2]::Ms() -lt 120000){$o='GAVE_UP';break}; continue }
        break }
      $p=([regex]::Matches($o,'\[PASS\]')).Count; $fl=([regex]::Matches($o,'\[FAIL\]')).Count; $m=[regex]::Match($o,'(\d+) pass, (\d+) fail'); if($m.Success -and -not $p -and -not $fl){$p=[int]$m.Groups[1].Value;$fl=[int]$m.Groups[2].Value}
      $st=if($o -eq 'TIMEOUT'){'failed'}elseif($o -eq 'GAVE_UP'){'skipped'}elseif($fl){'failed'}elseif($p){'passed'}else{'failed'}
      $fgRows+=[pscustomobject]@{name=$name;pass=$p;fail=$fl;ms=$sw.ElapsedMilliseconds;status=$st}; '{0} (前台): pass={1}, fail={2}, status={3}' -f $name,$p,$fl,$st
    } } }
$passTotal=($rows|Measure-Object pass -Sum).Sum;$failTotal=($rows|Measure-Object fail -Sum).Sum
$bad=@($rows|Where-Object status -eq 'failed').Count;$offline=@($rows|Where-Object status -eq 'server530').Count;$envBlocked=@($rows|Where-Object status -eq 'environment').Count
$okGroups=@($rows|Where-Object status -eq 'passed').Count; $skipGroups=$offline+$envBlocked
$summary=@("后台测试 $($started.ToString('yyyy-MM-dd HH:mm'))","合计 $($rows.Count) 组：通过 $okGroups 组 / 失败 $bad 组 / 跳过 $skipGroups 组（服务器连不上 $offline、环境不具备 $envBlocked，比如没登录）；断言 通过 $passTotal、失败 $failTotal",'')
$summary+=@($rows|ForEach-Object{"$($_.name): $($_.pass) / $($_.fail), exit=$($_.exit), $($_.status)"})
$fgPass=@($fgRows|Where-Object status -eq 'passed').Count; $fgFail=@($fgRows|Where-Object status -eq 'failed').Count; $fgSkip=@($fgRows|Where-Object status -eq 'skipped').Count
$summary+=@('',$(if($fgNote){"前台测试：$fgNote"}else{"前台测试：$($fgRows.Count) 组，通过 $fgPass / 失败 $fgFail / 跳过 $fgSkip，中途你动了暂停 $pauses 次"}),"真实发送：未执行。")
$summary+=@($fgRows|ForEach-Object{"$($_.name)（前台）: $($_.pass) / $($_.fail), $($_.status)"})
[IO.File]::WriteAllLines((Join-Path $runRoot 'summary.txt'),$summary,[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllLines((Join-Path $v2 'data\test_results.txt'),$summary,[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText((Join-Path $v2 'data\test_results.json'),(@{run=$stamp;groups=$rows;pending=$held}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
'TOTAL groups={0}, passed={1}, failed={2}, skipped={3} (server530={4}, environment={5}); assertions pass={6}, fail={7}' -f $rows.Count,$okGroups,$bad,$skipGroups,$offline,$envBlocked,$passTotal,$failTotal
if($bad -or $fgFail){exit 1};exit 0