// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
// 模拟聊天.exe（WPF）：测试「去回复」和「发文件」用的假聊天软件，全部虚构内容；控件都有 UI 自动化名字
// 参数：dialog（默认，粘贴文件后弹「发送文件」对话框，像微信 3.x）或 inline（文件进输入框，回车发送，像微信 4.x）
using System; using System.Linq; using System.Windows; using System.Windows.Controls; using System.Windows.Input; using System.Windows.Automation;
static class Demo {
  static T N<T>(T e, string name) where T : DependencyObject { AutomationProperties.SetName(e, name); return e; }
  [STAThread] static void Main(string[] args) {
    bool inline = args.Length > 0 && args[0] == "inline";
    var chats = Enumerable.Range(1, 40).Select(i => "测试会话" + i).ToArray();
    var list = N(new ListBox { Width = 220, Height = 520 }, "会话列表"); foreach (var c in chats) list.Items.Add(N(new ListBoxItem { Content = c }, c));
    var search = N(new TextBox { Width = 150 }, "搜索框"); var go = N(new Button { Content = "搜索", Width = 60 }, "搜索");
    var title = N(new TextBlock { FontSize = 16, Text = "" }, "聊天标题");
    var msgs = N(new ListBox { Height = 430 }, "消息"); var input = N(new TextBox { Height = 70, AcceptsReturn = true }, "输入框");
    Action<string> add = t => { var it = N(new ListBoxItem { Content = t }, t); msgs.Items.Add(it); msgs.ScrollIntoView(it); };
    Action<string> open = name => { title.Text = name; AutomationProperties.SetHelpText(title, name); msgs.Items.Clear();
      for (int k = 0; k < 60; k++) { var t = k == 5 ? name + "：周五下午的方案你看过了吗" : name + "：第" + k + "条普通消息"; msgs.Items.Add(N(new ListBoxItem { Content = t }, t)); }
      msgs.ScrollIntoView(msgs.Items[msgs.Items.Count - 1]); };
    list.SelectionChanged += (s, e) => { var it = list.SelectedItem as ListBoxItem; if (it != null) open((string)it.Content); };
    go.Click += (s, e) => { var q = search.Text.Trim(); var hit = list.Items.Cast<ListBoxItem>().FirstOrDefault(x => (string)x.Content == q); if (hit != null) { list.SelectedItem = hit; list.ScrollIntoView(hit); } };
    string pending = null;   // inline 模式：粘进输入框、还没发的文件
    input.PreviewKeyDown += (s, e) => {
      if (e.Key == Key.V && (Keyboard.Modifiers & ModifierKeys.Control) != 0 && Clipboard.ContainsFileDropList()) {
        e.Handled = true; var f = System.IO.Path.GetFileName(Clipboard.GetFileDropList()[0]);
        if (inline) { pending = f; input.Text = "[文件] " + f; return; }
        // 像微信：弹出「发送给 xx」对话框，里面显示文件名，有「发送」「取消」
        var dlgWin = new Window { Title = "发送文件", Width = 360, Height = 200, WindowStartupLocation = WindowStartupLocation.CenterOwner, Owner = Application.Current.MainWindow };
        var to = N(new TextBlock { Text = "发送给：" + title.Text, Margin = new Thickness(12) }, "发送给"); var fn = N(new TextBlock { Text = f, Margin = new Thickness(12, 0, 12, 12) }, "文件名"); AutomationProperties.SetHelpText(fn, f);   // 文件名放在 HelpText 里，测试才读得到（Name 是「文件名」这个标签）
        var ok = N(new Button { Content = "发送", Width = 80, IsDefault = true }, "发送"); var no = N(new Button { Content = "取消", Width = 80, IsCancel = true, Margin = new Thickness(8, 0, 0, 0) }, "取消");
        ok.Click += (a, b) => { add("我：[文件] " + f); dlgWin.Close(); }; no.Click += (a, b) => dlgWin.Close();
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(12) }; row.Children.Add(ok); row.Children.Add(no);
        var sp = new StackPanel(); sp.Children.Add(to); sp.Children.Add(fn); sp.Children.Add(row); dlgWin.Content = sp; dlgWin.Show(); dlgWin.Activate();
      } else if (e.Key == Key.Return && pending != null) { e.Handled = true; add("我：[文件] " + pending); pending = null; input.Text = ""; }
      else if (e.Key == Key.Back && pending != null) { e.Handled = true; pending = null; input.Text = ""; }
    };
    var top = new StackPanel { Orientation = Orientation.Horizontal }; top.Children.Add(search); top.Children.Add(go);
    var left = new StackPanel { Margin = new Thickness(8) }; left.Children.Add(top); left.Children.Add(list);
    var right = new StackPanel { Margin = new Thickness(8), Width = 620 }; right.Children.Add(title); right.Children.Add(msgs); right.Children.Add(input);
    var root = new StackPanel { Orientation = Orientation.Horizontal }; root.Children.Add(left); root.Children.Add(right);
    var w = new Window { Title = "模拟聊天", Width = 900, Height = 640, Content = root, Left = 120, Top = 120, WindowStartupLocation = WindowStartupLocation.Manual };
    new Application().Run(w);
  }
}
