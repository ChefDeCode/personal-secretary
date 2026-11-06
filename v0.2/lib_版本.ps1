# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# Appends a release boundary only when the corresponding component actually starts.
# All log writers share a lock based on the normalized full path.
function Get-SecretaryLogMutexName([string]$Path) {
  if (-not $Path) { throw [ArgumentException]::new('A log path is required.') }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToLowerInvariant()))).Replace('-','').Substring(0,24)
  } finally { $sha.Dispose() }
  'Local\SecretaryLog_' + $key
}
function Enter-SecretaryLogLock([string]$Path, [int]$TimeoutMs = 10000) {
  $mutex = New-Object Threading.Mutex($false, (Get-SecretaryLogMutexName $Path))
  $held = $false
  try {
    try { $held = $mutex.WaitOne($TimeoutMs) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw [TimeoutException]::new('Log append lock timed out; the record was not written.') }
    $mutex
  } catch { $mutex.Dispose(); throw }
}
function Add-SecretaryLogLines {
  param([string]$Path, [string[]]$Lines, [int]$TimeoutMs = 10000)
  if (-not $Lines -or -not $Lines.Count) { return }
  $full = [IO.Path]::GetFullPath($Path)
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
  $mutex = Enter-SecretaryLogLock $full $TimeoutMs
  $stream = $null
  try {
    # Retry opening for old readers, never a possibly partial write.
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
      try {
        $stream = [IO.FileStream]::new($full,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
        break
      } catch [IO.IOException] { if ($attempt -eq 5) { throw }; Start-Sleep -Milliseconds (10 * ($attempt + 1)) }
    }
    $separator = ''
    if ($stream.Length -gt 0) {
      [void]$stream.Seek(-1,[IO.SeekOrigin]::End)
      $lastByte = $stream.ReadByte()
      if ($lastByte -ne 10 -and $lastByte -ne 13) { $separator = "`r`n" }
    }
    [void]$stream.Seek(0,[IO.SeekOrigin]::End)
    $bytes = [Text.Encoding]::UTF8.GetBytes($separator + ($Lines -join "`r`n") + "`r`n")
    $stream.Write($bytes,0,$bytes.Length)
    $stream.Flush($true)
  } finally {
    if ($stream) { $stream.Dispose() }
    $mutex.ReleaseMutex(); $mutex.Dispose()
  }
}

# 当前版本和这一版改了什么（一句话）。每次改动只改这两行：值守和秘书启动时各在 quality.jsonl 里写一行版本标记，一周的数字能按改动前后分开看
$script:SecretaryVersion = '0.2.0-reliability.20261106.4'
$script:SecretaryChange = '卸载能卸干净：秘书在自己文件夹以外的改动都记进 data\changes.jsonl（开机快捷方式、注册表、环境变量、临时文件夹等，老改动已补记），设置→关于→「卸载秘书」或单独运行 卸载秘书.ps1 按倒序还原并核对剩余；修好「添加软件」列表打开就出错（concat 笔误）'
function Write-ReliabilityVersionMark {
  param([string]$DataPath, [string]$Component, [string]$Version = $script:SecretaryVersion, [string]$Change = $script:SecretaryChange)
  if (-not $DataPath -or -not $Component) { return $false }
  [void][IO.Directory]::CreateDirectory($DataPath)
  $path = Join-Path $DataPath 'quality.jsonl'
  $mutex = Enter-SecretaryLogLock $path
  try {
    if (Test-Path -LiteralPath $path) {
      $reader = [IO.StreamReader]::new($path,[Text.Encoding]::UTF8)
      try {
        while (-not $reader.EndOfStream) {
          $line = $reader.ReadLine()
          if ($line -notmatch '"ev"\s*:\s*"revision"') { continue }
          try { $r = $line | ConvertFrom-Json } catch { continue }
          if ($r.version -eq $Version -and $r.component -eq $Component) { return $false }
        }
      } finally { $reader.Dispose() }
    }
    $line = [ordered]@{ ts = (Get-Date).ToString('s'); ev = 'revision'; version = $Version; component = $Component; change = $Change; schema = 1 } | ConvertTo-Json -Compress
    # Reentrant ownership keeps duplicate checking and the append in one transaction.
    Add-SecretaryLogLines -Path $path -Lines @($line)
    return $true
  } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
