; SPDX-License-Identifier: AGPL-3.0-or-later
; Copyright (C) 2026 ChefDeCode
; 个人秘书安装包（Inno Setup 6）。CI 里用：ISCC.exe /DAppVersion=0.2.0 installer\secretary.iss
; - 只装给当前用户：%LOCALAPPDATA%\Programs\PersonalSecretary，不要管理员权限
; - 「开始」菜单快捷方式和「应用和功能」里的卸载登记由 安装后登记.ps1 经改动记录写入，卸载用 卸载秘书.ps1（不用 Inno 自带的卸载程序）
; - 不设开机自动启动；安装包没有代码签名，SmartScreen 会提示「未知发布者」
#ifndef AppVersion
  #define AppVersion "0.2.0"
#endif
[Setup]
AppId={{6C1C2B1E-5E0B-4C55-9B3A-2A51D3B7C0A1}
AppName=个人秘书
AppVersion={#AppVersion}
AppPublisher=ChefDeCode
AppPublisherURL=https://github.com/ChefDeCode/personal-secretary
DefaultDirName={userpf}\PersonalSecretary
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=
Uninstallable=no
CreateUninstallRegKey=no
OutputDir=..\dist
OutputBaseFilename=PersonalSecretary-Setup-{#AppVersion}
SetupIconFile=..\v0.2\ui\secretary.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\LICENSE

[Files]
Source: "..\*.ps1"; DestDir: "{app}"; Excludes: "build.ps1"; Flags: ignoreversion
Source: "..\v0.2\*"; DestDir: "{app}\v0.2"; Excludes: "tests\*,data\*,*.md,启动器\*,签名\*.cs,签名\编译.ps1"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\lib\webview2\*"; DestDir: "{app}\lib\webview2"; Flags: ignoreversion
Source: "安装后登记.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\installer\安装后登记.ps1"" -AppRoot ""{app}"" -Version ""{#AppVersion}"""; Flags: runhidden waituntilterminated
Filename: "{app}\v0.2\秘书.exe"; Description: "现在打开个人秘书"; Flags: nowait postinstall skipifsilent