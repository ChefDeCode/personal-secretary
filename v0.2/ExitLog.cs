// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
// 秘书的退出原因记录：这些事件在别的线程上触发，PowerShell 脚本块在那里跑不了，所以用 C# 记。只记类型和位置，不记内容。
using System; using System.IO; using System.Text;
public static class ExitLog {
  public static string LogPath, StatePath; static readonly object L = new object();
  static string Esc(string s) { return (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", " ").Replace("\n", " "); }
  public static void Write(string kind, string detail) {
    try { lock (L) { File.AppendAllText(LogPath, "{\"ts\":\"" + DateTime.Now.ToString("s") + "\",\"pid\":" + System.Diagnostics.Process.GetCurrentProcess().Id + ",\"kind\":\"" + Esc(kind) + "\",\"detail\":\"" + Esc(detail) + "\"}\r\n", new UTF8Encoding(false)); } } catch { } }
  // 干净退出标记：值守看到它就不会把秘书再打开
  public static void MarkClean(string how) { try { lock (L) { File.WriteAllText(StatePath, "{\"pid\":" + System.Diagnostics.Process.GetCurrentProcess().Id + ",\"clean\":true,\"how\":\"" + Esc(how) + "\",\"ts\":\"" + DateTime.Now.ToString("s") + "\"}", new UTF8Encoding(false)); } } catch { } }
  // 异常类型 + 出在哪个模块的哪个方法
  public static string Describe(object o) {
    var e = o as Exception; if (e == null) return o == null ? "" : o.GetType().FullName;
    var b = e.GetBaseException(); var m = b.TargetSite;
    return b.GetType().FullName + (m != null ? " @ " + (m.Module != null ? m.Module.Name : "") + "!" + (m.DeclaringType != null ? m.DeclaringType.Name : "") + "." + m.Name : ""); }
  public static void Install() {
    AppDomain.CurrentDomain.UnhandledException += (s, e) => Write("unhandled-exception", Describe(e.ExceptionObject) + (e.IsTerminating ? " (terminating)" : ""));
    System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (s, e) => { Write("unobserved-task", Describe(e.Exception)); e.SetObserved(); };
    Microsoft.Win32.SystemEvents.SessionEnding += (s, e) => { Write("session-ending", e.Reason.ToString()); MarkClean("session-ending"); };
  }
}
