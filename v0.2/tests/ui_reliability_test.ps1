# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
param([string]$SourceRoot, [switch]$Baseline)
$ErrorActionPreference = 'Stop'
$v2 = if ($SourceRoot) { $SourceRoot } else { Split-Path $PSScriptRoot -Parent }
$args2 = @((Join-Path $PSScriptRoot 'ui_reliability_test.js'), $v2)
if ($Baseline) { $args2 += '--baseline' }
& node @args2
exit $LASTEXITCODE
