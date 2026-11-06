# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 卸载秘书.ps1 — 把秘书从这台电脑上卸载干净，并把它动过的设置原样还原。秘书打不开的时候也能直接用（右键 → 用 PowerShell 运行）
# 设置 → 关于 → 「卸载秘书」用的也是它
# 步骤：等正在发的消息发完 → 关掉秘书的所有程序 → 能连上服务器就退出登录（作废这台电脑的登录） → 按「改动记录」倒序还原 →
#       （保留数据时）把你的消息、聊天、事项、记忆、截图打包到桌面（不含任何密钥和登录） → 删掉程序文件夹、浏览器缓存、临时文件夹 →
#       逐项检查有没有留下东西，写一份卸载报告到桌面
# 只动秘书自己的东西：不在「改动记录」里、也不在秘书自己文件夹里的，一律不碰（比如你自己建的计划任务）
param(
  [ValidateSet('', 'KeepData', 'DeleteAll')] [string]$Mode = '',   # 不填：弹窗问你
  [string]$AppRoot = $PSScriptRoot,
  [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
  [string]$StartupDir = [Environment]::GetFolderPath('Startup'),
  [string]$ServerBase = '',
  [switch]$NoServer,
  [int]$SendWaitSec = 300,
  [switch]$Quiet,                 # 不弹窗（测试 / 从界面调用时由界面提示）
  [string]$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
  [string]$StartMenuDir = (Join-Path ([Environment]::GetFolderPath('Programs')) ''),
  [string]$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PersonalSecretary',
  [string]$TempDir = $env:TEMP,
  [string]$TempPattern = '^(secretary_|sec_datacheck_|snap_\d)'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$AppRoot = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\'); $v2 = Join-Path $AppRoot 'v0.2'; $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
$report = New-Object System.Collections.ArrayList; function Note([string]$s) { [void]$report.Add($s) }
Set-Location $env:TEMP   # 不能站在要删的文件夹里
if (-not (Test-Path (Join-Path $v2 '秘书.ps1')) -and -not (Test-Path (Join-Path $AppRoot 'v0.2'))) { if (-not $Quiet) { [Windows.Forms.MessageBox]::Show("这里看起来不是秘书的文件夹：`n$AppRoot", '卸载秘书') | Out-Null }; exit 2 }

# 0) 问你：保留数据还是全部删除
if (-not $Mode) {
  $msg = "要把秘书从这台电脑上卸载吗？`n`n会删除：秘书程序、它的浏览器缓存和临时文件、登录信息和你保存在秘书里的 AI 密钥；开机自动启动等它改过的设置会还原。删除以后不能恢复。`n`n「是」= 保留我的数据（把消息、聊天、事项、记忆、截图打包放到桌面，不含任何密钥）`n「否」= 全部删除`n「取消」= 不卸载"
  $a = [Windows.Forms.MessageBox]::Show($msg, '卸载秘书', 'YesNoCancel', 'Warning', 'Button1')
  if ($a -eq 'Cancel') { exit 0 }; $Mode = if ($a -eq 'Yes') { 'KeepData' } else { 'DeleteAll' }
}
Note "卸载秘书 $ts（$(if ($Mode -eq 'KeepData') { '保留我的数据' } else { '全部删除' })）"

# 1) 等正在发的消息发完
$busy = Join-Path $v2 'data\send_busy.flag'; $sw = [Diagnostics.Stopwatch]::StartNew()
while ((Test-Path $busy) -and $sw.Elapsed.TotalSeconds -lt $SendWaitSec) { $op = 0; try { $op = [int](Get-Content $busy -Raw) } catch {}; if (-not $op -or -not (Get-Process -Id $op -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 500 }
if ($sw.Elapsed.TotalSeconds -ge 1) { Note "等正在发的消息发完：等了 $([int]$sw.Elapsed.TotalSeconds) 秒" }
if ((Test-Path $busy) -and $sw.Elapsed.TotalSeconds -ge $SendWaitSec) { Note '有一条消息一直没发完，已经不再等' }

# 2) 关掉秘书的所有程序（只认程序文件在秘书文件夹里、或者命令里带着秘书文件夹的）
$killed = 0
foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID -and (([string]$_.ExecutablePath).StartsWith($AppRoot, [StringComparison]::OrdinalIgnoreCase) -or ([string]$_.CommandLine).IndexOf($AppRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and ([string]$_.CommandLine) -notmatch '卸载秘书\.ps1' })) {
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed++ } catch {} }
Start-Sleep -Milliseconds 800; Note "关掉秘书的程序：$killed 个"

# 3) 退出登录：能连上服务器就作废这台电脑的登录；连不上就只删本机的登录信息（文件夹会整个删掉）
$acct = Join-Path $v2 'data\account.dat'
if (-not (Test-Path $acct)) { Note '没有登录过账号，不用退出' }
elseif ($NoServer) { Note '没有退出服务器上的登录（这次没连服务器）；本机的登录信息会删掉' }
else {
  $out = 'unknown'
  try { $base = if ($ServerBase) { $ServerBase } else { $df = try { [string]([IO.File]::ReadAllText((Join-Path $AppRoot 'v0.2\默认设置.json')) | ConvertFrom-Json).server_base } catch { '' }; if ($df) { $df } else { 'https://secretary.demandatlas.online' } }
    Add-Type -AssemblyName System.Net.Http; $hc = New-Object Net.Http.HttpClient; $hc.Timeout = [TimeSpan]::FromSeconds(10); $code = [int]$hc.GetAsync("$base/healthz").GetAwaiter().GetResult().StatusCode
    if ($code -ne 200) { $out = "服务器现在连不上（HTTP $code）" }
    else { $job = Start-Job -ScriptBlock { param($dir) . "$dir\lib_v2.ps1"; . "$dir\lib_账号.ps1"; [void](Invoke-Logout); 'ok' } -ArgumentList $v2; if (Wait-Job $job -Timeout 30) { $r = Receive-Job $job -ErrorAction SilentlyContinue; $out = if ($r -contains 'ok') { 'ok' } else { '退出登录没成功' } } else { Stop-Job $job; $out = '退出登录超时' }; Remove-Job $job -Force }
  } catch { $out = '服务器现在连不上' }
  Note $(if ($out -eq 'ok') { '已经退出服务器上的登录（这台电脑的登录已作废）' } else { "没能退出服务器上的登录：$out。本机的登录信息会删掉；你可以以后在网页上把这台设备移除" })
}

# 4) 按「改动记录」倒序还原
$lib = Join-Path $v2 'lib_改动记录.ps1'; $journal = Join-Path $v2 'data\changes.jsonl'; $journalOk = $false
if (Test-Path $lib) { . $lib; $script:ChangeJournal = $journal
  $u = Undo-ExternalChanges $journal; $journalOk = $u.exists -and -not $u.bad
  Note "还原改动记录：$(@($u.results).Count) 项，没还原成的 $(@($u.results | Where-Object { $_.result -ne 'ok' }).Count) 项$(if ($u.bad) { "；记录里有 $($u.bad) 行坏了，改用下面的检查兜底" })$(if (-not $u.exists) { '；没有找到改动记录，改用下面的检查兜底' })"
  foreach ($x in @($u.results | Where-Object { $_.result -ne 'ok' })) { Note "  没还原：$($x.kind) $($x.target)（$($x.result)）" } }
else { Note '没有找到改动记录的程序（秘书文件可能坏了），改用下面的检查兜底' }

# 5) 兜底：已知的几个地方再查一遍（只认指向秘书文件夹的）
$fixed = 0
$lnk = Join-Path $StartupDir '个人秘书.lnk'
if (Test-Path -LiteralPath $lnk) { $tgt = try { (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath } catch { '' }; if (-not $tgt -or $tgt.StartsWith($AppRoot, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $lnk -Force; $fixed++ } }
# 安装包放的「开始」菜单快捷方式、「应用和功能」里的卸载登记（指向秘书文件夹的才删）
$smLnk = Join-Path $StartMenuDir '个人秘书.lnk'
if (Test-Path -LiteralPath $smLnk) { $tgt = try { (New-Object -ComObject WScript.Shell).CreateShortcut($smLnk).TargetPath } catch { '' }; if (-not $tgt -or $tgt.StartsWith($AppRoot, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $smLnk -Force; $fixed++ } }
if (Test-Path $UninstallKey) { $loc = [string](Get-ItemProperty $UninstallKey -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation; if (-not $loc -or $loc.TrimEnd('\').Equals($AppRoot, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item $UninstallKey -Recurse -Force; $fixed++ } }if (Test-Path $RunKey) { foreach ($pr in (Get-Item $RunKey).Property) { $val = [string](Get-ItemProperty $RunKey -Name $pr).$pr; if ($val.IndexOf($AppRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Remove-ItemProperty $RunKey -Name $pr; $fixed++ } } }
foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { ((@($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments) $($_.WorkingDirectory)" }) -join ' ').IndexOf($AppRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) })) { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false; $fixed++ }
foreach ($d in @(Get-ChildItem $TempDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $TempPattern })) { try { Remove-Item -LiteralPath $d.FullName -Recurse -Force; $fixed++ } catch {} }
# 透明读时秘书要是意外退出，被放出来的窗口可能还是全透明、点不着的：恢复成正常样子
if (-not ('UnGhost' -as [type])) { Add-Type 'using System; using System.Runtime.InteropServices; public static class UnGhost { delegate bool P(IntPtr h, IntPtr l); [DllImport("user32.dll")] static extern bool EnumWindows(P p, IntPtr l); [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i); [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v); [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr h, out uint k, out byte a, out uint f); [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint k, byte a, uint f); public static int Fix() { int n = 0; EnumWindows((h, l) => { int ex = GetWindowLong(h, -20); if ((ex & 0x80000) != 0 && (ex & 0x20) != 0) { uint k, f; byte a; if (GetLayeredWindowAttributes(h, out k, out a, out f) && (f & 2) != 0 && a == 0) { SetLayeredWindowAttributes(h, 0, 255, 2); SetWindowLong(h, -20, ex & ~0x20 & ~0x80000); n++; } } return true; }, IntPtr.Zero); return n; } }' }
$ung = [UnGhost]::Fix(); if ($ung) { Note "恢复了 $ung 个被透明读留下的全透明窗口" }
Note "已知位置兜底检查：处理了 $fixed 项"

# 6) 保留数据：只打包你的内容（消息、聊天、事项、记忆、人、事件、提醒、截图），不含密钥、登录、日志、缓存
$zip = ''
if ($Mode -eq 'KeepData') {
  $stage = Join-Path $env:TEMP "秘书数据_$ts"; New-Item -ItemType Directory -Force $stage | Out-Null
  $want = '^(messages|todos|attachments|chat|chat_archive|memory|memory_pending|people|events|task_history|done|auto_replied|reminders_state|reminders_custom|scheduled|files_index|plan|list_latest)\.(jsonl|json)$'
  foreach ($dd in @((Join-Path $AppRoot 'data'), (Join-Path $v2 'data'))) { if (-not (Test-Path $dd)) { continue }; $sub = if ($dd -like '*v0.2*') { 'v0.2' } else { 'data' }
    foreach ($f in @(Get-ChildItem $dd -File | Where-Object { $_.Name -match $want })) { New-Item -ItemType Directory -Force (Join-Path $stage $sub) | Out-Null; Copy-Item $f.FullName (Join-Path $stage $sub) }
    if (Test-Path (Join-Path $dd 'images')) { Copy-Item (Join-Path $dd 'images') (Join-Path $stage "$sub\images") -Recurse } }
  [IO.File]::WriteAllText((Join-Path $stage '说明.txt'), "秘书保存的你的数据（$ts 卸载时导出）。内容用这台电脑上你的 Windows 账号加密，换电脑或换账号打不开。不含任何密钥、登录信息。", (New-Object Text.UTF8Encoding $true))
  $zip = Join-Path $DesktopDir "秘书数据-$ts.zip"; Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force; Remove-Item $stage -Recurse -Force
  Note "你的数据已经打包到桌面：$([IO.Path]::GetFileName($zip))（$([Math]::Round((Get-Item $zip).Length / 1MB, 1)) MB，不含密钥和登录）"
}

# 7) 删掉程序文件夹（包括里面的浏览器缓存、插件、日志、密钥）
$gone = $false
for ($i = 0; $i -lt 6 -and -not $gone; $i++) { try { if (Test-Path -LiteralPath $AppRoot) { Remove-Item -LiteralPath $AppRoot -Recurse -Force -ErrorAction Stop }; $gone = -not (Test-Path -LiteralPath $AppRoot) } catch { Start-Sleep -Seconds 2 } }
if (-not $gone) { $left = @(Get-ChildItem $AppRoot -Recurse -File -Force -ErrorAction SilentlyContinue).Count; Note "程序文件夹没能删干净：还剩 $left 个文件（可能有程序还开着），可以重启电脑后再运行一次" }

# 8) 最后检查：改动记录里的东西、已知位置、临时文件夹
$left = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $AppRoot) { [void]$left.Add("程序文件夹还在：$AppRoot") }
if (Get-Command Test-ExternalLeftovers -ErrorAction SilentlyContinue) { foreach ($x in @(Test-ExternalLeftovers $journal)) { [void]$left.Add("没还原：$x") } }
if (Test-Path -LiteralPath $lnk) { [void]$left.Add("开机快捷方式还在：$lnk") }
if (Test-Path -LiteralPath $smLnk) { [void]$left.Add("「开始」菜单快捷方式还在：$smLnk") }; if (Test-Path $UninstallKey) { [void]$left.Add("「应用和功能」里的登记还在") }
foreach ($d in @(Get-ChildItem $TempDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $TempPattern })) { [void]$left.Add("临时文件夹还在：$($d.FullName)") }
# 安装包放的「开始」菜单快捷方式、「应用和功能」里的卸载登记（指向秘书文件夹的才删）
$smLnk = Join-Path $StartMenuDir '个人秘书.lnk'
if (Test-Path -LiteralPath $smLnk) { $tgt = try { (New-Object -ComObject WScript.Shell).CreateShortcut($smLnk).TargetPath } catch { '' }; if (-not $tgt -or $tgt.StartsWith($AppRoot, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $smLnk -Force; $fixed++ } }
if (Test-Path $UninstallKey) { $loc = [string](Get-ItemProperty $UninstallKey -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation; if (-not $loc -or $loc.TrimEnd('\').Equals($AppRoot, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item $UninstallKey -Recurse -Force; $fixed++ } }if (Test-Path $RunKey) { foreach ($pr in (Get-Item $RunKey).Property) { if (([string](Get-ItemProperty $RunKey -Name $pr).$pr).IndexOf($AppRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$left.Add("开机启动项还在：$pr") } } }
Note ''
if (-not $left.Count) { Note '已卸载干净。' } else { Note "还有 $($left.Count) 项没能清掉："; foreach ($x in $left) { Note "  $x" } }
Note '提醒：你在 Claude / DeepSeek 等网站上自己创建的 AI 密钥还在你的账号里，秘书不会替你作废；如果不再用，可以到那个网站上自己作废。'
$rp = Join-Path $DesktopDir "秘书卸载报告-$ts.txt"; [IO.File]::WriteAllLines($rp, [string[]]$report, (New-Object Text.UTF8Encoding $true))
if (-not $Quiet) { [Windows.Forms.MessageBox]::Show(($report -join "`n"), '卸载秘书', 'OK', $(if ($left.Count) { 'Warning' } else { 'Information' })) | Out-Null }
$report
if ($left.Count) { exit 1 }; exit 0
