# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 安装后登记 → 卸载：「开始」菜单快捷方式和「应用和功能」登记都记进改动记录，卸载后一样不剩
# 全在临时文件夹和测试专用的注册表键里做，不碰真的「开始」菜单和真的卸载登记
$ErrorActionPreference = 'Stop'
$v2 = Split-Path $PSScriptRoot -Parent; $root = Split-Path $v2 -Parent
$pass = 0; $fail = 0; function Check($n, $ok) { if ($ok) { $script:pass++ } else { $script:fail++ }; "  [$(if ($ok) { 'PASS' } else { 'FAIL' })] $n" }
$G = [guid]::NewGuid().ToString('n').Substring(0, 6)
$S = Join-Path $env:TEMP "instcheck_$G"; $app = "$S\app"
New-Item -ItemType Directory -Force "$app\v0.2\ui", "$app\installer", "$S\sm", "$S\desk", "$S\startup", "$S\tmp" | Out-Null
Copy-Item "$v2\lib_改动记录.ps1" "$app\v0.2\"; Copy-Item "$v2\ui\secretary.ico" "$app\v0.2\ui\"; Copy-Item "$root\卸载秘书.ps1" "$app\"
Copy-Item "$root\installer\安装后登记.ps1" "$app\installer\"; [IO.File]::WriteAllText("$app\v0.2\秘书.exe", 'placeholder')
$key = "HKCU:\Software\SecretaryInstallTest_$G"; $run = "HKCU:\Software\SecretaryInstallTestRun_$G"
try {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File "$app\installer\安装后登记.ps1" -AppRoot $app -StartMenuDir "$S\sm" -UninstallKey $key 2>&1
  Check "post-install script ran ($(@($out)[-1]))" (@($out)[-1] -eq 'ok')
  Check 'Start Menu shortcut created' (Test-Path "$S\sm\个人秘书.lnk")
  $p = Get-ItemProperty $key
  Check "uninstall entry points at 卸载秘书.ps1 ($($p.DisplayName))" ($p.DisplayName -eq '个人秘书' -and $p.UninstallString -like '*卸载秘书.ps1*' -and $p.InstallLocation -eq $app)
  $j = @(Get-Content "$app\v0.2\data\changes.jsonl" -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
  Check "both changes are in the change journal ($($j.Count) records)" (@($j | Where-Object kind -eq 'startup_link').Count -eq 1 -and @($j | Where-Object kind -eq 'hkcu_value').Count -ge 8)
  Check 'no autostart by default' (-not (Test-Path "$S\startup\个人秘书.lnk"))
  $u = & powershell -NoProfile -ExecutionPolicy Bypass -STA -File "$app\卸载秘书.ps1" -Mode DeleteAll -Quiet -NoServer -SendWaitSec 1 -AppRoot $app -DesktopDir "$S\desk" -StartupDir "$S\startup" -RunKey $run -StartMenuDir "$S\sm" -UninstallKey $key -TempDir "$S\tmp" 2>&1
  Check "uninstall: exit $LASTEXITCODE" ($LASTEXITCODE -eq 0)
  Check 'uninstall: Start Menu shortcut gone' (-not (Test-Path "$S\sm\个人秘书.lnk"))
  Check 'uninstall: 应用和功能 entry gone' (-not (Test-Path $key))
  Check 'uninstall: program folder gone' (-not (Test-Path $app))
} finally {
  Remove-Item $key, $run -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item $S -Recurse -Force -ErrorAction SilentlyContinue
}
"install_register_test: $pass pass, $fail fail"
if ($fail) { exit 1 }
