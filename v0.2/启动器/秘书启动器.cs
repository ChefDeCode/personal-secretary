// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
// 秘书.exe — 个人秘书的启动器：带软件图标，隐藏地启动 PowerShell 主程序（v0.2\秘书.ps1），并一直陪着它运行
// 这样任务管理器里显示的是「个人秘书」和我们的图标（PowerShell 进程挂在它下面）；主程序退出时启动器也退出。
// 已经在运行时再启动：主程序自己会通知已有实例打开/收起，然后马上退出，启动器也跟着退出。
// 编译（Windows 自带的 .NET Framework 编译器，不用下载）：见同目录 编译.ps1
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

static class SecretaryLauncher {
  [DllImport("shell32.dll")] static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);

  [STAThread]
  static int Main(string[] args) {
    SetCurrentProcessExplicitAppUserModelID("PersonalSecretary.App");
    string dir = AppDomain.CurrentDomain.BaseDirectory;                       // 秘书.exe 放在 v0.2 文件夹里
    string script = Path.Combine(dir, "秘书.ps1");
    if (!File.Exists(script)) { MessageBox.Show("找不到 " + script, "个人秘书"); return 1; }
    string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
    var psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"" + (args.Length > 0 ? " " + string.Join(" ", args) : ""));   // 参数原样传给主程序（例如开机用 -Tray）
    psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = dir;
    try { using (var p = Process.Start(psi)) { p.WaitForExit(); return p.ExitCode; } }
    catch (Exception e) { MessageBox.Show("启动失败：" + e.Message, "个人秘书"); return 1; }
  }
}
