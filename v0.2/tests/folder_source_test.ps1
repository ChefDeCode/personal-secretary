# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 文件夹来源：临时文件夹代替桌面 / 文档 / 下载（不碰你的真文件）
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent
. "$v2\lib_v2.ps1"; . "$v2\lib_文件夹读.ps1"
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$T = Join-Path $env:TEMP 'secretary_folder_src'; Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force "$T\docs\sub", "$T\docs\.ssh", "$T\docs\node_modules" | Out-Null
function Get-FolderRoots { "$T\docs" }; $state = "$T\state.json"
[IO.File]::WriteAllText("$T\docs\old.txt", '旧文件：上个月的会议记录')
$r0 = Get-FolderChanges $state; Check "first run only takes a baseline ($($r0.files) files, nothing read)" ($r0.first -and @($r0.pick).Count -eq 0)
Start-Sleep -Milliseconds 50
[IO.File]::WriteAllText("$T\docs\sub\新通知.txt", "测试通知`r`n周五下午3点前交周报`r`n请回复确认")
[IO.File]::WriteAllText("$T\docs\.env", 'KEY=abc'); [IO.File]::WriteAllText("$T\docs\密码.txt", 'x'); [IO.File]::WriteAllText("$T\docs\.ssh\id_rsa", 'x'); [IO.File]::WriteAllText("$T\docs\node_modules\readme.md", 'x')
[IO.File]::WriteAllText("$T\docs\notes.txt", "备忘`r`npassword: hunter2")
$big = New-Object byte[] (3MB); [IO.File]::WriteAllBytes("$T\docs\big.txt", $big)
Add-Type -AssemblyName System.IO.Compression.FileSystem; $dx = "$T\docs\合同.docx"; $za = [IO.Compression.ZipFile]::Open($dx, 'Create'); $e = $za.CreateEntry('word/document.xml'); $sw = New-Object IO.StreamWriter ($e.Open()); $sw.Write('<w:document><w:p>合同请在下周一前签回</w:p></w:document>'); $sw.Dispose(); $za.Dispose()
$r1 = Get-FolderChanges $state 10; $names = @($r1.pick | ForEach-Object Name)
Check "new / changed files picked up ($($names -join ', '))" ($names -contains '新通知.txt' -and $names -contains '合同.docx' -and $names -contains 'notes.txt')
Check 'secret-looking names, .ssh, node_modules, big files are never listed' (-not ($names | Where-Object { $_ -in '.env', '密码.txt', 'id_rsa', 'readme.md', 'big.txt' }))
Check 'old file not re-read' ($names -notcontains 'old.txt')
$g = Get-FolderText ($r1.pick | Where-Object Name -eq '新通知.txt'); Check "text read ($(@($g.lines).Count) lines)" (@($g.lines).Count -eq 3)
$d = Get-FolderText ($r1.pick | Where-Object Name -eq '合同.docx'); Check 'Word text read' (($d.lines -join '') -match '签回')
$s = Get-FolderText ($r1.pick | Where-Object Name -eq 'notes.txt'); Check 'file whose text looks like a password is skipped entirely' ($s.skip -eq 'secret' -and -not @($s.lines).Count)
$r2 = Get-FolderChanges $state 10; Check 'nothing new -> nothing picked' (@($r2.pick).Count -eq 0)
Check 'state file stores fingerprints, not file names' (-not ((Get-Content $state -Raw) -match '通知|合同|notes'))
Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
"folder_source_test: $pass pass, $fail fail"
