# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# build.ps1 — 从源码生成能运行的文件（不需要 Visual Studio，用 Windows 自带的 .NET Framework 编译器 csc.exe）
#   秘书.exe          ← v0.2\启动器\秘书启动器.cs（带图标的启动器）
#   Ed25519.dll       ← v0.2\签名\Ed25519.cs（商城插件 / 更新包的签名校验）
#   测试窗口 *.exe    ← v0.2\tests\*.cs（只有加 -Tests 才编，给测试用的假窗口）
#   lib\webview2\     ← 只有加 -FetchWebView2 才从 nuget.org 下载 Microsoft.Web.WebView2，并按下面钉死的 SHA256 核对
# 用法：powershell -ExecutionPolicy Bypass -File .\build.ps1 [-FetchWebView2] [-Tests]
param([switch]$FetchWebView2, [switch]$Tests)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot; $v2 = Join-Path $root 'v0.2'
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path $csc)) { throw "没找到 .NET Framework 自带的 csc.exe：$csc" }
function Compile([string[]]$CscArgs) { & $csc /nologo /codepage:65001 /optimize+ @CscArgs; if ($LASTEXITCODE) { throw "编译失败：$($CscArgs -join ' ')" } }

Compile @('/target:winexe', "/win32icon:$v2\ui\secretary.ico", "/out:$v2\秘书.exe", '/reference:System.Windows.Forms.dll', "$v2\启动器\秘书启动器.cs")
Compile @('/target:library', '/r:System.Numerics.dll', "/out:$v2\签名\Ed25519.dll", "$v2\签名\Ed25519.cs")
"built 秘书.exe, Ed25519.dll"

if ($Tests) {
  $wpf = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'WPF'
  Compile @('/target:winexe', "/out:$v2\tests\仿微信.exe", '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll', '/r:System.Core.dll', "$v2\tests\仿微信.cs")
  Compile @('/target:winexe', "/out:$v2\tests\秘书测试窗口.exe", '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll', "$v2\tests\测试窗口.cs")
  Compile @('/target:winexe', "/out:$v2\tests\模拟聊天.exe", "/r:$wpf\PresentationFramework.dll", "/r:$wpf\PresentationCore.dll", "/r:$wpf\WindowsBase.dll", "/r:$wpf\UIAutomationProvider.dll", "/r:$wpf\UIAutomationTypes.dll", '/r:System.Xaml.dll', '/r:System.Core.dll', "$v2\tests\模拟聊天.cs")
  "built test windows"
}

if ($FetchWebView2) {
  # Microsoft.Web.WebView2 1.0.2365.46（BSD 许可，微软发布）；只取这三个文件，并核对 SHA256
  # 钉的是这个 nuget 包里 lib\net45 的 Core / WinForms（.NET Framework 用）和 x64 的 WebView2Loader.dll（Windows PowerShell 5.1 是 64 位进程）
  $ver = '1.0.2365.46'
  $pins = @{ 'Microsoft.Web.WebView2.Core.dll' = 'A7BAA548C354EF9223F4FD19D2BAE33C3EB8CB987BF7B577828897388110740F'
             'Microsoft.Web.WebView2.WinForms.dll' = '3BF5B0990756E5B8E6502D51BC228962D9D3E59A358EACA9BA8DC87BEA86C1DE'
             'WebView2Loader.dll' = '5EBDA0B70E04873607FF0E8CEEA8FB29074B14717C2A67C2086F4EE42404EC7A' }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wv2_' + [guid]::NewGuid().ToString('n')); New-Item -ItemType Directory $tmp | Out-Null
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$ver/microsoft.web.webview2.$ver.nupkg" -OutFile "$tmp\wv2.zip" -UseBasicParsing
    Expand-Archive "$tmp\wv2.zip" "$tmp\x"
    $out = Join-Path $root 'lib\webview2'; New-Item -ItemType Directory -Force $out | Out-Null
    foreach ($name in $pins.Keys) {
      $match = Get-ChildItem "$tmp\x" -Recurse -Filter $name | Where-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash -eq $pins[$name] } | Select-Object -First 1
      if (-not $match) { throw "$name：下载的包里没有 SHA256 对得上的文件，停止" }
      Copy-Item $match.FullName (Join-Path $out $name) -Force
    }
    "fetched WebView2 SDK $ver (3 files, SHA256 verified)"
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
