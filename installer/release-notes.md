跑在你自己 Windows 电脑上的个人秘书：看着微信、邮件和文件夹，整理出「需要你回的」「你答应别人的」「有截止时间的」，到点提醒你。

**这一版（0.2.2）**
- 修好了中文 Windows 上提醒反复弹的问题。系统代码页是 936（GBK）时，秘书读自己的数据文件会读成乱码，提醒记录丢了，同一条提醒就一遍遍再弹。现在读文件一律按 UTF-8。
- 0.2.1 安装后程序里显示的版本号还是 0.2.0，这一版改对了。

**安装**
- 下载 `PersonalSecretary-Setup-*.exe`，可以用 `SHA256SUMS` 核对。
- 只装给当前用户（`%LOCALAPPDATA%\Programs\PersonalSecretary`），不需要管理员权限，不会设开机自动启动。
- 安装包**没有代码签名**，SmartScreen 会提示「未知发布者」：点「更多信息」→「仍要运行」。
- 需要 Windows 10/11 和 Microsoft Edge WebView2 运行时（Windows 11 自带）。用 AI 整理需要你自己的密钥（Claude / DeepSeek / OpenAI 兼容接口），或者登录账号用账号额度。

**卸载**
在「设置 → 应用」里卸载，或在秘书里点「设置 → 关于 → 卸载秘书」。秘书在自己文件夹以外做过的改动会按记录原样还原；可以选保留数据（打包到桌面，不含密钥）或全部删除。

---

A personal secretary that runs on your own Windows PC. Per-user install, no admin rights, no autostart. The installer is not code-signed, so SmartScreen will warn: click "More info" → "Run anyway". Verify downloads with `SHA256SUMS`. Requires Windows 10/11 with the WebView2 Runtime and your own AI key (or a signed-in account).

0.2.2 fixes reminders repeating on Chinese-locale Windows (code page 936): data files are now always read as UTF-8. The in-app version number is correct again (0.2.1 still said 0.2.0).
