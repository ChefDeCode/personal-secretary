# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 卸载干净（2026-11-06）：在临时文件夹里装一份「假秘书」，用只给测试用的「启动」文件夹、注册表键、环境变量、开机启动项，
# 打开开机自启、建临时文件夹、跑一个假的秘书进程，然后用两种方式卸载，检查一样不剩、该还原的都还原了、保留的数据里没有密钥。
# 也测：正在发消息时会等、连不上服务器、秘书文件坏了、改动记录坏了。绝不碰你真的秘书、真的「启动」文件夹和真的设置
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $realRoot = Split-Path $v2 -Parent
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$G = [guid]::NewGuid().ToString('n').Substring(0, 8)
$W = Join-Path $env:TEMP "secuninstall_$G"; New-Item -ItemType Directory -Force $W | Out-Null
$startup = "$W\startup"; $desk = "$W\desktop"; $tmpRoot = "$W\temp"; foreach ($d in $startup, $desk, $tmpRoot) { New-Item -ItemType Directory -Force $d | Out-Null }
$regKey = "HKCU:\Software\SecretaryUninstallTest_$G"; $runKey = "HKCU:\Software\SecretaryUninstallTestRun_$G"; $envName = "SECRETARY_UNINSTALL_TEST_$G"
function New-Install([string]$name) {
  $root = "$W\$name\个人秘书"; New-Item -ItemType Directory -Force "$root\v0.2\data\images", "$root\data\images", "$root\v0.2\data\webview2\cache", "$root\v0.2\tools" | Out-Null
  Copy-Item (Join-Path $realRoot '卸载秘书.ps1') $root; Copy-Item (Join-Path $v2 'lib_改动记录.ps1') "$root\v0.2"
  'x' | Set-Content "$root\v0.2\秘书.ps1"; 'x' | Set-Content "$root\v0.2\lib_v2.ps1"; 'fake exe' | Set-Content "$root\v0.2\秘书.exe"
  foreach ($f in 'messages.jsonl', 'todos.jsonl', 'attachments.jsonl') { '{"ts":"2026-01-01","text":"enc"}' | Set-Content "$root\data\$f" }
  foreach ($f in 'chat.jsonl', 'chat_archive.jsonl', 'memory.jsonl', 'people.jsonl', 'task_history.jsonl') { '{"x":1}' | Set-Content "$root\v0.2\data\$f" }
  'img' | Set-Content "$root\data\images\a1.img"
  'TOKEN-SECRET' | Set-Content "$root\v0.2\data\account.dat"; 'HMAC-SECRET' | Set-Content "$root\data\hmac.key"; 'ANTHROPIC_API_KEY=sk-ant-test' | Set-Content "$root\.env"
  '{"ai":{"keys":{"anthropic":"ENCKEY"}}}' | Set-Content "$root\config.json"; 'log' | Set-Content "$root\v0.2\data\errors.log"; 'cache' | Set-Content "$root\v0.2\data\webview2\cache\c.bin"
  $root }
function Set-Changes([string]$root) {
  # 和秘书里一样经过「改动记录」：开机自启、注册表、环境变量、临时文件夹
  . "$root\v0.2\lib_改动记录.ps1"; $script:ChangeJournal = "$root\v0.2\data\changes.jsonl"
  Set-JournaledStartupLink "$startup\个人秘书.lnk" $true "$root\v0.2\秘书.exe" '-Tray' "$root\v0.2"
  Set-JournaledHkcuValue $regKey 'Mode' 'on'; Set-JournaledUserEnv $envName 'test-value'
  $script:TmpWork = New-JournaledFolder "$tmpRoot\secretary_work_$G"; 'x' | Set-Content "$script:TmpWork\f.txt" }
function Start-Fake([string]$root) { Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', "Start-Sleep 120; # $root\v0.2\秘书.ps1") }
function Run-Uninstall([string]$root, [string]$mode, [string[]]$extra = @()) {
  $a = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "$root\卸载秘书.ps1", '-Mode', $mode, '-Quiet', '-DesktopDir', $desk, '-StartupDir', $startup, '-RunKey', $runKey, '-StartMenuDir', $startup, '-UninstallKey', "HKCU:\Software\SecretaryUninstallTestUn_$G", '-TempDir', $tmpRoot, '-TempPattern', '^secretary_') + $extra
  $o = & powershell @a 2>&1 | Out-String; @{ out = $o; code = $LASTEXITCODE } }
function Leftovers([string]$root) { @(
  $(if (Test-Path $root) { 'app folder' }); $(if (Test-Path "$startup\个人秘书.lnk") { 'startup link' })
  $(if (Test-Path $regKey) { 'registry key' }); $(if ($null -ne [Environment]::GetEnvironmentVariable($envName, 'User')) { 'env var' })
  $(if (@(Get-ChildItem $tmpRoot -Directory | Where-Object Name -match '^secretary_').Count) { 'temp folder' })) | Where-Object { $_ } }
try {
  # 一个开机启动项（测试用的 Run 键）：指向秘书文件夹的要被兜底检查删掉，别的不能碰
  New-Item -Path $runKey -Force | Out-Null; Set-ItemProperty $runKey 'NotOurs' 'C:\Other\app.exe'
  # 1) 保留我的数据
  $root = New-Install 'keep'; Set-Changes $root; $p = Start-Fake $root; Set-ItemProperty $runKey 'Secretary' "$root\v0.2\秘书.exe"; Start-Sleep 1
  Check 'before: autostart link, registry value, env var, temp folder and a running secretary process all exist' ((Test-Path "$startup\个人秘书.lnk") -and (Test-Path $regKey) -and [Environment]::GetEnvironmentVariable($envName, 'User') -and (Test-Path $script:TmpWork) -and -not $p.HasExited)
  $r = Run-Uninstall $root 'KeepData' @('-NoServer')
  $left = @(Leftovers $root); Check "保留我的数据: nothing left ($($left -join ', '))" (-not $left.Count -and $r.code -eq 0 -and $r.out -match '已卸载干净')
  Check 'the running secretary process was stopped' ($p.HasExited -or -not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue))
  Check 'only the Run entry pointing at the secretary was removed; the other one is untouched' (-not (Get-ItemProperty $runKey -Name 'Secretary' -ErrorAction SilentlyContinue) -and (Get-ItemProperty $runKey -Name 'NotOurs').NotOurs -eq 'C:\Other\app.exe')
  $zip = @(Get-ChildItem $desk -Filter '秘书数据-*.zip')[0]; $names = if ($zip) { $zr = [IO.Compression.ZipFile]::OpenRead($zip.FullName); try { @($zr.Entries | ForEach-Object FullName) } finally { $zr.Dispose() } } else { @() }
  Check "data zip on the desktop opens ($($names.Count) files) and has messages, to-dos, chats, memory and screenshots" ($zip -and ($names -match 'messages\.jsonl') -and ($names -match 'todos\.jsonl') -and ($names -match 'chat_archive\.jsonl') -and ($names -match 'memory\.jsonl') -and ($names -match 'images/a1\.img|images\\a1\.img'))
  Check 'no keys, login, config or logs in the zip' (-not @($names | Where-Object { $_ -match 'account\.dat|hmac\.key|\.env|config\.json|errors\.log|webview2' }).Count)
  $zipText = if ($zip) { $z = [IO.Compression.ZipFile]::OpenRead($zip.FullName); try { ($z.Entries | ForEach-Object { $sr = New-Object IO.StreamReader($_.Open()); $sr.ReadToEnd(); $sr.Dispose() }) -join "`n" } finally { $z.Dispose() } } else { '' }
  Check 'no secret text inside any zipped file' ($zipText -notmatch 'TOKEN-SECRET|HMAC-SECRET|sk-ant|ENCKEY')
  Check 'a report was written to the desktop and reminds you about the AI key on the provider site' (@(Get-ChildItem $desk -Filter '秘书卸载报告-*.txt').Count -ge 1 -and $r.out -match 'AI 密钥')
  # 2) 全部删除
  Get-ChildItem $desk | Remove-Item -Force; $root = New-Install 'all'; Set-Changes $root
  $r = Run-Uninstall $root 'DeleteAll' @('-NoServer'); $left = @(Leftovers $root)
  Check "全部删除: nothing left ($($left -join ', ')), and no data zip" (-not $left.Count -and -not @(Get-ChildItem $desk -Filter '*.zip').Count -and $r.out -match '已卸载干净')
  # 3) 正在发消息：等它发完
  $root = New-Install 'sending'; Set-Changes $root; $sender = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep 4')
  [IO.File]::WriteAllText("$root\v0.2\data\send_busy.flag", [string]$sender.Id); $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Run-Uninstall $root 'DeleteAll' @('-NoServer'); $waited = $sw.Elapsed.TotalSeconds
  Check "a send in progress: it waited for the send to finish first ($([int]$waited) s) and then removed everything" ($waited -ge 3 -and $r.out -match '等正在发的消息发完' -and -not @(Leftovers $root).Count)
  # 4) 连不上服务器：如实说没退出服务器上的登录，本机照样删干净
  $root = New-Install 'offline'; Set-Changes $root
  $r = Run-Uninstall $root 'DeleteAll' @('-ServerBase', 'http://127.0.0.1:9')
  Check 'server unreachable: says the server sign-out did not happen, still removes everything locally' ($r.out -match '没能退出服务器上的登录' -and -not @(Leftovers $root).Count)
  # 5) 秘书本身坏了（主程序和库都没了）：独立卸载程序照样能用
  $root = New-Install 'broken'; Set-Changes $root; Remove-Item "$root\v0.2\秘书.ps1", "$root\v0.2\lib_v2.ps1" -Force
  $r = Run-Uninstall $root 'DeleteAll' @('-NoServer')
  Check 'secretary broken (main files gone): the standalone uninstaller still removes everything' (-not @(Leftovers $root).Count -and $r.code -eq 0)
  # 6) 改动记录坏了几行：好的照样还原，并说明有坏行
  $root = New-Install 'corrupt'; Set-Changes $root; Add-Content "$root\v0.2\data\changes.jsonl" '{broken line' -Encoding UTF8
  $r = Run-Uninstall $root 'DeleteAll' @('-NoServer')
  Check 'journal with a broken line: reports it and still restores everything else' ($r.out -match '坏了' -and -not @(Leftovers $root).Count)
  # 7) 改动记录整个没了：按已知位置兜底（开机快捷方式、临时文件夹），记录才知道的东西（注册表、环境变量）如实报告没还原
  $root = New-Install 'nojournal'; Set-Changes $root; Remove-Item "$root\v0.2\data\changes.jsonl" -Force
  $r = Run-Uninstall $root 'DeleteAll' @('-NoServer')
  Check 'no journal at all: falls back to the known places (startup link, temp folders, app folder) and says so' ($r.out -match '没有找到改动记录' -and -not (Test-Path "$startup\个人秘书.lnk") -and -not (Test-Path $root))
  if (Test-Path $regKey) { Remove-Item $regKey -Recurse -Force }; [Environment]::SetEnvironmentVariable($envName, $null, 'User')   # 记录没了就还原不了这两项：测试自己收拾
  # 8) 你自己建的计划任务不是秘书的：卸载程序只删动作里指向秘书文件夹的计划任务
  $un = [IO.File]::ReadAllText((Join-Path $realRoot '卸载秘书.ps1')); $taskLine = @($un -split "`n" | Where-Object { $_ -match 'Unregister-ScheduledTask' -and $_ -match 'Get-ScheduledTask' })[0]; Check 'the uninstaller only removes scheduled tasks whose action points into the program folder' ($taskLine -and $taskLine -match 'IndexOf\(\$AppRoot')
} finally {
  foreach ($k in $regKey, $runKey) { if (Test-Path $k) { Remove-Item $k -Recurse -Force } }; [Environment]::SetEnvironmentVariable($envName, $null, 'User')
  Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -match [regex]::Escape($W) } catch { $false } } | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item $W -Recurse -Force -ErrorAction SilentlyContinue
}
"uninstall_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
