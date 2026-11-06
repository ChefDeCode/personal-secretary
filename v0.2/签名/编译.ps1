# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 编译 Ed25519.cs → Ed25519.dll（Windows 自带的 .NET Framework 编译器，不下载任何东西）
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
& $csc /nologo /target:library /optimize+ /r:System.Numerics.dll /out:"$PSScriptRoot\Ed25519.dll" "$PSScriptRoot\Ed25519.cs"
