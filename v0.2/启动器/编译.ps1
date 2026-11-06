# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 编译.ps1 — 用 Windows 自带的 .NET Framework C# 编译器把 秘书启动器.cs 编成 v0.2\秘书.exe，并嵌入 ui\secretary.ico
# 换了图标后重新运行一次即可：powershell -ExecutionPolicy Bypass -File .\编译.ps1
$here = $PSScriptRoot; $v2 = Split-Path $here -Parent
$csc = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework64\v4*\csc.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
if (-not $csc) { throw '没找到 .NET Framework 自带的 csc.exe' }
$ico = Join-Path $v2 'ui\secretary.ico'; $out = Join-Path $v2 '秘书.exe'
& $csc.FullName /nologo /target:winexe /codepage:65001 /optimize+ "/win32icon:$ico" "/out:$out" /reference:System.Windows.Forms.dll (Join-Path $here '秘书启动器.cs')
if ($LASTEXITCODE -eq 0) { "已生成 $out（$((Get-Item $out).Length) 字节）" } else { "编译失败（$LASTEXITCODE）" }
