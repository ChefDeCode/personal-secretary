# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 每个测试用自己的临时数据文件夹：在加载秘书的任何代码之前调用 Use-TestDataFolder
# 之后秘书的数据（data、v0.2\data）和设置（config.json）都落在这个临时文件夹里，不会碰到你真正的数据；
# 同时打开测试保护（SECRETARY_TEST=1）：万一还有代码要往真正的数据文件夹写日志，会被拒绝并记一笔
function Use-TestDataFolder([string]$Name = 'test', [switch]$NoConfig) {
  $safe = ($Name -replace '[^\w-]', '_'); if (-not $safe) { $safe = 'test' }
  $T = Join-Path ([IO.Path]::GetTempPath()) ('secretary_td_' + $safe + '_' + [guid]::NewGuid().ToString('n').Substring(0, 6))
  foreach ($d in "$T\data", "$T\v0.2data") { [void][IO.Directory]::CreateDirectory($d) }
  $realCfg = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config.json'
  if (-not $NoConfig -and (Test-Path -LiteralPath $realCfg)) {
    # 设置的副本（去掉 AI 密钥）：测试改设置不会改到你的，临时文件夹里也不留密钥
    try { $c = [IO.File]::ReadAllText($realCfg) | ConvertFrom-Json; if ($c.ai -and $c.ai.keys) { $c.ai.keys = [pscustomobject]@{} }; [IO.File]::WriteAllText("$T\config.json", ($c | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false)) } catch {}
  }
  $env:SECRETARY_TEST = '1'; $env:SECRETARY_TEST_DATA = $T
  $T
}
