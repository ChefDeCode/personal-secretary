# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# lib_文件夹读.ps1 — 本机文件夹当来源（桌面 / 文档 / 下载）：只看「连接以后」新建或改过的文件，读出文字交给整理（要回的、要做的、截止时间）
# 名字检查只看文件 / 文件夹自己的名字（一层层往下走时每层都查过），不看整条路径（路径里的用户名之类会误伤）
# 只读；第一次只记下现有文件（不读旧文件）；跳过大文件、隐藏 / 系统文件、开发目录；名字或内容像密钥、密码、凭据的一律不读
. (Join-Path $PSScriptRoot 'lib_文件.ps1')   # 用它的 Get-FileText（txt/md/csv、Word/Excel/PPT 读包里的文字、PDF 前几页本机认字）
$script:FolderExt = '\.(txt|md|csv|docx|xlsx|pptx|pdf|rtf)$'
$script:SecretName = '(^|\\)\.(env|ssh|aws|gnupg|azure|kube|docker|git)(\\|$)|\.env(\.|$)|id_(rsa|ed25519|ecdsa|dsa)|\.(pem|key|pfx|p12|kdbx|ppk|crt|cer|jks|keystore)$|passw|密码|token|secret|credential|凭据|私钥|recovery|恢复码|恢复代码|backup.?code|wallet|钱包|seed|助记词|license.?key|激活码'
$script:SecretText = '-----BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE)|(?i)\b(password|passwd|pwd|api[_-]?key|secret[_-]?key|access[_-]?token|client[_-]?secret)\s*[:=]|\bsk-[A-Za-z0-9_-]{16,}|\bAKIA[0-9A-Z]{16}\b|密码\s*[:：]|口令\s*[:：]|验证码\s*[:：]|助记词'
$script:SkipDirs = '^(node_modules|\.git|\.venv|venv|__pycache__|AppData|\$RECYCLE\.BIN|System Volume Information)$'
function Get-FolderRoots { @('Desktop', 'MyDocuments') | ForEach-Object { [Environment]::GetFolderPath($_) } | Where-Object { $_ -and (Test-Path $_) }; $dl = Join-Path $env:USERPROFILE 'Downloads'; if (Test-Path $dl) { $dl } }
function Get-FolderFiles([int]$depth = 3, [long]$maxSize = 2MB) {
  $out = New-Object System.Collections.Generic.List[IO.FileInfo]
  $walk = { param($d, $lv)
    try { foreach ($f in [IO.DirectoryInfo]::new($d).EnumerateFiles()) { if ($f.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) { continue }; if ($f.Name -notmatch $script:FolderExt -or $f.Length -gt $maxSize -or $f.Length -eq 0 -or $f.Name -match $script:SecretName -or $f.Name.StartsWith('~$')) { continue }; $out.Add($f) } } catch {}
    if ($lv -ge $depth) { return }
    try { foreach ($s in [IO.DirectoryInfo]::new($d).EnumerateDirectories()) { if ($s.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint)) { continue }; if ($s.Name -match $script:SkipDirs -or $s.Name -match $script:SecretName) { continue }; & $walk $s.FullName ($lv + 1) } } catch {} }
  foreach ($r in Get-FolderRoots) { & $walk $r 1 }
  $out
}
function Get-PathKey([string]$p) { [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($p.ToLowerInvariant()))).Replace('-', '').Substring(0, 20) }   # 状态文件里只存路径的指纹，不存文件名
# 新建 / 改过的文件（最新的在前，最多 $max 个）；第一次只记下现有的，返回空
function Get-FolderChanges([string]$stateFile, [int]$max = 3) {
  $files = @(Get-FolderFiles); $st = @{}; $first = -not (Test-Path $stateFile)
  if (-not $first) { try { (Get-Content $stateFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $st[$_.Name] = [long]$_.Value } } catch { $first = $true } }
  $chg = New-Object System.Collections.Generic.List[IO.FileInfo]
  foreach ($f in $files) { $k = Get-PathKey $f.FullName; $tk = $f.LastWriteTimeUtc.Ticks; if (-not $first -and $st[$k] -ne $tk) { $chg.Add($f) }; if ($first) { $st[$k] = $tk } }
  $pick = @($chg | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $max)
  foreach ($f in $pick) { $st[(Get-PathKey $f.FullName)] = $f.LastWriteTimeUtc.Ticks }
  [IO.File]::WriteAllText($stateFile, ($st | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
  @{ first = $first; files = $files.Count; changed = $chg.Count; pick = $pick }
}
# 文件的文字 → 前 60 行；内容像密钥 / 密码就整份不要
function Get-FolderText([IO.FileInfo]$f) {
  $t = [string](Get-FileText $f.FullName); if (-not $t) { return @{ skip = 'empty'; lines = @() } }
  if ($t -match $script:SecretText) { return @{ skip = 'secret'; lines = @() } }
  @{ skip = ''; lines = @($t -split "`r?`n" | ForEach-Object { $x = ($_ -replace '\s+', ' ').Trim(); if ($x.Length -gt 300) { $x.Substring(0, 300) } else { $x } } | Where-Object { $_ } | Select-Object -First 60) }
}
