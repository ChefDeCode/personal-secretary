// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
// 秘书测试窗口.exe：给「点一下窗口」测试用的一个空白窗口（秘书自己的测试程序，不读不写任何东西）
using System; using System.Drawing; using System.Windows.Forms;
static class T { [STAThread] static void Main(string[] a) { var f = new Form { Text = "秘书测试窗口", StartPosition = FormStartPosition.Manual, Bounds = new Rectangle(int.Parse(a[0]), int.Parse(a[1]), 600, 400), BackColor = Color.FromArgb(240, 236, 228), TopMost = true };
  f.Controls.Add(new Label { Text = "秘书测试窗口", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Microsoft YaHei UI", 20) }); Application.Run(f); } }
