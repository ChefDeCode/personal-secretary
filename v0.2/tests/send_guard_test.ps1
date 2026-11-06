# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 发送程序的三道闸（用虚构的发送任务跑真的 发送.ps1，三种情况都在碰微信之前就停下；跑完把虚构任务和记录删掉）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$tr = Join-Path $script:V2Data 'send_trace.jsonl'; $trBak = "$tr.guardtest"; if (Test-Path $tr) { Copy-Item $tr $trBak -Force }
$busy = Join-Path $script:V2Data 'send_busy.flag'; $made = @()
function Run($id) { $p = Start-Process powershell -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "$v2\发送.ps1", '-Id', $id -PassThru -WindowStyle Hidden; if (-not $p.WaitForExit(30000)) { $p.Kill(); return $null }
  $rf = Join-Path $script:ActDir "$id.result.json"; if (Test-Path $rf) { (Unprotect (Get-Content $rf -Raw)) | ConvertFrom-Json } }
function Fake { $a = New-SendAction '【秘书测试】不存在的聊天' '【秘书测试】闸门测试' ''; $a.status = 'confirmed'; Save-Action $a; $script:made += $a.id; $a.id }   # 发送程序只执行确认过的
$nTrace0 = @(Get-Content $tr -ErrorAction SilentlyContinue).Count
try {
  # 闸 2：已经发出去过的
  $id2 = Fake; [IO.File]::WriteAllText((Join-Path $script:ActDir "$id2.result.json"), (Protect (@{ id = $id2; ok = $true; message = '已发出' } | ConvertTo-Json -Compress)))
  $r = Run $id2; Check "already sent -> exits as sent, does not send again ($($r.message))" ($r.ok -eq $true -and (@($r.steps | ForEach-Object { $_.text }) -join '|') -match '没有再发一次')
  # 闸 3：两分钟里试了 3 次
  $id3 = Fake; 1..3 | ForEach-Object { Add-Content $tr (@{ ts = (Get-Date).ToString('s'); id = $id3; kind = 'fg'; ok = $false; msg = '测试' } | ConvertTo-Json -Compress) -Encoding UTF8 }
  $r = Run $id3; Check "tried 3 times in 2 minutes -> stops ($($r.message))" ($r.ok -eq $false -and $r.message -eq '尝试太多' -and -not $r.retryable)
  # 闸 1：别的发送程序正在发（用这个测试进程自己当「别的发送程序」）
  $id1 = Fake; [IO.File]::WriteAllText($busy, [string]$PID)
  $r = Run $id1; Check "another send running -> does not touch WeChat ($($r.message))" ($r.ok -eq $false -and $r.message -eq '另一条正在发')
  Check 'busy flag of the other sender left alone' ((Test-Path $busy) -and ((Get-Content $busy -Raw).Trim() -eq [string]$PID))
  $added = @(Get-Content $tr -ErrorAction SilentlyContinue).Count - $nTrace0 - 3; Check "no real send attempt was made (new trace lines: $added)" ($added -eq 0)
} finally {
  Remove-Item $busy -ErrorAction SilentlyContinue
  foreach ($id in $made) { Remove-Item (Join-Path $script:ActDir "$id.json"), (Join-Path $script:ActDir "$id.result.json") -ErrorAction SilentlyContinue }
  if (Test-Path $trBak) { Move-Item $trBak $tr -Force } }
"send_guard_test: $pass pass, $fail fail"
