// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
// 仿微信.exe：测试「电脑操作」找聊天用的假聊天软件（全部虚构内容）。和微信 4 一样只有一个窗口句柄、自己画所有东西，
// 只认发给窗口的消息（点击、滚轮、WM_CHAR、按键），不抢前台（显示时不激活）。
// 参数：<日志文件> [目标名]。日志里记：OPEN 名字 / SENT 名字<TAB>文字 / SEARCH_ENTER / MSG_CLICK（点了消息区：不该发生）/ ACTIVATED（被激活：不该发生）
using System; using System.Drawing; using System.Linq; using System.Windows.Forms; using System.Collections.Generic; using System.Runtime.InteropServices;
class Fake : Form {
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware(); [DllImport("user32.dll")] static extern short GetKeyState(int vk); bool selAll = false; List<string> sent = new List<string>();
  public static int X0 = 200, Y0 = 200, TI = 22; public static bool NoChar = false, StayInSearch = false, SlowCopy = false, NoCopy = false, NoTab = false; public static string Prefill = ""; string log; List<string> names = new List<string>(); string title = "", search = "", input = "", focus = ""; int scroll = 0; float s;
  protected override bool ShowWithoutActivation { get { return true; } }
  Fake(string logFile, string target) {
    log = logFile; for (int i = 1; i <= 30; i++) names.Add("测试联系人" + i.ToString("00")); names[TI] = target;
    Text = "仿微信测试"; FormBorderStyle = FormBorderStyle.None; StartPosition = FormStartPosition.Manual; DoubleBuffered = true; ShowInTaskbar = false;
    using (var gg = Graphics.FromHwnd(IntPtr.Zero)) s = gg.DpiX / 96f; Bounds = new Rectangle(X0, Y0, (int)(900 * s), (int)(640 * s)); BackColor = Color.FromArgb(237, 237, 237);
  }
  void L(string t) { System.IO.File.AppendAllText(log, t + "\n"); }
  int LW { get { return (int)(270 * s); } } int Top0 { get { return (int)(60 * s); } } int RH { get { return (int)(64 * s); } }
  int CT { get { return (int)(60 * s); } } int CB { get { return ClientSize.Height - (int)(150 * s); } }
  List<string> Rows { get { return search.Length > 0 ? names.Where(n => n.Contains(search)).ToList() : names; } }
  protected override void OnPaint(PaintEventArgs e) {
    var g = e.Graphics; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
    using (var f = new Font("Microsoft YaHei UI", 11f * s, GraphicsUnit.Pixel)) using (var fb = new Font("Microsoft YaHei UI", 15f * s, GraphicsUnit.Pixel)) using (var fs = new Font("Microsoft YaHei UI", 10f * s, GraphicsUnit.Pixel)) {
      g.FillRectangle(new SolidBrush(Color.FromArgb(247, 247, 247)), 0, 0, LW, ClientSize.Height);
      g.DrawLine(new Pen(Color.FromArgb(214, 214, 214)), LW, 0, LW, ClientSize.Height);
      var sb = new Rectangle((int)(12 * s), (int)(14 * s), LW - (int)(24 * s), (int)(30 * s)); g.FillRectangle(new SolidBrush(Color.FromArgb(226, 226, 226)), sb);
      g.DrawString(search.Length > 0 ? search : "搜索", f, new SolidBrush(search.Length > 0 ? Color.Black : Color.Gray), sb.X + 8 * s, sb.Y + 5 * s);
      var rows = Rows; var clip = g.Clip; g.SetClip(new Rectangle(0, Top0, LW, ClientSize.Height - Top0));
      for (int i = 0; i < rows.Count; i++) { int y = Top0 + i * RH - (search.Length > 0 ? 0 : scroll); if (y + RH < Top0 || y > ClientSize.Height) continue;
        if (rows[i] == title) g.FillRectangle(new SolidBrush(Color.FromArgb(222, 222, 222)), 0, y, LW, RH);
        g.FillRectangle(new SolidBrush(Color.FromArgb(120, 160, 200)), 12 * s, y + 12 * s, 40 * s, 40 * s);
        g.DrawString(rows[i], f, Brushes.Black, 62 * s, y + 12 * s); g.DrawString("虚构预览文字", fs, Brushes.Gray, 62 * s, y + 36 * s); }
      g.Clip = clip;
      g.DrawLine(new Pen(Color.FromArgb(214, 214, 214)), LW, CT, ClientSize.Width, CT);
      if (title.Length > 0) g.DrawString(title, fb, Brushes.Black, LW + 20 * s, 18 * s);
      if (title.Length > 0) { var bub = new Rectangle(LW + (int)(70 * s), CT + (int)(30 * s), (int)(220 * s), (int)(40 * s)); g.FillRectangle(Brushes.White, bub); g.DrawString("（虚构消息）", f, Brushes.Black, bub.X + 10 * s, bub.Y + 10 * s); }
      for (int k = 0; k < sent.Count; k++) { var sz = g.MeasureString(sent[k], f); var bb = new RectangleF(ClientSize.Width - sz.Width - 90 * s, CT + 90 * s + k * 50 * s, sz.Width + 20 * s, 40 * s); g.FillRectangle(new SolidBrush(Color.FromArgb(149, 236, 105)), bb); g.DrawString(sent[k], f, Brushes.Black, bb.X + 10 * s, bb.Y + 10 * s); }
      g.DrawLine(new Pen(Color.FromArgb(214, 214, 214)), LW, CB, ClientSize.Width, CB);
      g.DrawString(input, f, Brushes.Black, LW + 20 * s, CB + 16 * s);
    }
  }
  const int WM_LBUTTONDOWN = 0x201, WM_CHAR = 0x102, WM_KEYDOWN = 0x100, WM_MOUSEWHEEL = 0x20A, WM_ACTIVATE = 6;
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x0401) { L("INPUT " + input); return; }
    if (m.Msg == WM_ACTIVATE && ((int)m.WParam & 0xFFFF) != 0) L("ACTIVATED");
    if (m.Msg == WM_LBUTTONDOWN && StayInSearch && focus == "search") { return; }
    if (m.Msg == WM_LBUTTONDOWN) { int x = (short)((long)m.LParam & 0xFFFF), y = (short)(((long)m.LParam >> 16) & 0xFFFF); Click(x, y); return; }
    if (m.Msg == WM_MOUSEWHEEL) { var p = PointToClient(new Point((short)((long)m.LParam & 0xFFFF), (short)(((long)m.LParam >> 16) & 0xFFFF))); int d = (short)(((long)m.WParam >> 16) & 0xFFFF);
      if (p.X < LW && search.Length == 0) { scroll = Math.Max(0, Math.Min(names.Count * RH - (ClientSize.Height - Top0), scroll - d / 120 * RH * 3)); Invalidate(); } return; }
    if ((m.Msg == WM_CHAR && !NoChar) || m.Msg == 0x0286) { char c = (char)(int)m.WParam; if (c < 32) return; selAll = false;
      if (focus == "search") { search += c; Invalidate(); } else if (focus == "input") { input += c; Invalidate(); } return; }
    if (m.Msg == WM_KEYDOWN) { int vk = (int)m.WParam; bool ctrl = GetKeyState(0x11) < 0;
      if (ctrl && vk == 0x46) { focus = "search"; search = ""; selAll = false; Invalidate(); return; }
      if (ctrl && vk == 0x41) { selAll = true; return; }
      if (ctrl && vk == 0x43) { if (NoCopy) return; string sv = focus == "input" ? input : focus == "search" ? search : ""; if (selAll && sv.Length > 0) { if (SlowCopy) { var tm = new Timer { Interval = 250 }; tm.Tick += (s2, e2) => { tm.Stop(); Clipboard.SetText(sv); }; tm.Start(); } else Clipboard.SetText(sv); } return; }
      if (ctrl && vk == 0x23) { selAll = false; return; }
      if (vk == 0x2E && selAll) { if (focus == "input") input = ""; else if (focus == "search") search = ""; selAll = false; Invalidate(); return; }
      if (vk == 9) { if (!NoTab) focus = "input"; return; }
      if (ctrl && vk == 0x56) { string cb = Clipboard.ContainsText() ? Clipboard.GetText() : ""; if (focus == "search") search = (selAll ? "" : search) + cb; else if (focus == "input") input = (selAll ? "" : input) + cb; selAll = false; Invalidate(); return; }
      if (vk == 8 && selAll) { if (focus == "input") input = ""; else if (focus == "search") search = ""; selAll = false; Invalidate(); return; }
      if (vk == 27) { search = ""; focus = ""; Invalidate(); }
      if (vk == 8) { if (focus == "input" && input.Length > 0) { input = input.Substring(0, input.Length - (input.Length >= 2 && char.IsLowSurrogate(input[input.Length - 1]) ? 2 : 1)); Invalidate(); } else if (focus == "search" && search.Length > 0) { search = search.Substring(0, search.Length - 1); Invalidate(); } }
      if (vk == 13) { if (focus == "search") { var rr = Rows; L("SEARCH_ENTER"); if (rr.Count > 0) { title = rr[0]; L("OPEN " + title); input = Prefill; Prefill = ""; } search = ""; focus = StayInSearch ? "search" : "input"; Invalidate(); } else if (focus == "input" && input.Length > 0 && title.Length > 0) { L("SENT " + title + "\t" + input); sent.Add(input); input = ""; Invalidate(); } }
      return; }
    base.WndProc(ref m);
  }
  new void Click(int x, int y) {
    if (x < LW) {
      if (y < Top0) { focus = "search"; Invalidate(); return; }
      var rows = Rows; int i = (y - Top0 + (search.Length > 0 ? 0 : scroll)) / RH; if (i >= 0 && i < rows.Count) { title = rows[i]; L("OPEN " + title); search = ""; focus = ""; input = Prefill; Prefill = ""; Invalidate(); }
      return; }
    if (y > CB) { focus = "input"; return; }
    if (y > CT) L("MSG_CLICK");
  }
  [STAThread] static void Main(string[] a) { SetProcessDPIAware(); if (a.Length > 3) { X0 = int.Parse(a[2]); Y0 = int.Parse(a[3]); } if (a.Length > 4) TI = int.Parse(a[4]); if (a.Length > 5 && a[5] == "nochar") NoChar = true; if (a.Length > 5 && a[5] == "stayinsearch") StayInSearch = true; if (a.Length > 5 && a[5] == "slowcopy") SlowCopy = true; if (a.Length > 5 && a[5] == "nocopy") NoCopy = true; if (a.Length > 5 && a[5] == "notab") { StayInSearch = true; NoTab = true; } if (a.Length > 6) Prefill = a[6].Replace("\\n", "\n"); Application.EnableVisualStyles(); Application.Run(new Fake(a[0], a.Length > 1 ? a[1] : "秘书测试目标")); }
}
