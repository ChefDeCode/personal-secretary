# 个人秘书（Personal Secretary）

[中文](#中文) · [English](#english)

许可证：**AGPL-3.0-or-later**（见 `LICENSE`）。账号 / 商城服务端是单独的项目，**不在这个仓库里**。

---

## 中文

一个跑在你自己 Windows 电脑上的秘书：帮你看着微信等聊天软件、邮件和文件夹，整理出「需要你回的」「你答应别人的」「有截止时间的」，到点提醒你；你确认以后，它还能替你把消息发出去。

### 它怎么读消息

- **只看屏幕**：用 Windows 自带的文字识别（`Windows.Media.Ocr`）和界面自动化（UI Automation）读聊天窗口上显示的字。窗口最小化时，它会把窗口「透明地」显示一下截图再收回去，不抢前台、不动你的鼠标键盘。
- **不解密微信数据库，不注入、不挂钩任何程序**，不读其他软件的内部文件。
- 发消息只在你点了确认卡片以后，由秘书把字放进聊天软件的输入框（剪贴板粘贴 / 模拟键盘）再发送；发之前会核对聊天名字，对不上就不发。

### 你的数据

- 所有数据都存在本机程序文件夹下的 `data\`，用 Windows DPAPI（当前用户）加密，换一个 Windows 账号或换电脑都解不开。
- **自带密钥**：AI 用你自己的密钥（Anthropic Claude、DeepSeek 或 OpenAI 兼容接口），密钥同样用 DPAPI 加密保存。整理消息时，需要整理的文字（以及你允许时的截图）会发给你选的 AI 服务商。
- 可选的账号 / 商城服务端（默认 `https://secretary.demandatlas.online`，可在 `v0.2\默认设置.json` 或设置里改）用来登录、更新、下载签名过的插件，以及（你选择用账号额度而不是自己的密钥时）转发 AI 请求；不登录也能用。
- 详见 [PRIVACY.md](PRIVACY.md)。

### 安装

1. 到 [Releases](https://github.com/ChefDeCode/personal-secretary/releases) 下载 `PersonalSecretary-Setup-<版本>.exe`，用 `SHA256SUMS` 核对。
2. 双击安装：只装给当前用户（`%LOCALAPPDATA%\Programs\PersonalSecretary`），**不需要管理员权限**，不会设开机自动启动（想要的话在设置里开）。
3. 安装包**没有代码签名**，Windows SmartScreen 会提示「未知发布者」：点「更多信息」→「仍要运行」。
4. 需要 Windows 10/11 和 Microsoft Edge WebView2 运行时（Windows 11 自带）。

### 卸载

在「设置 → 应用 → 已安装的应用」里找「个人秘书」卸载，或在秘书里点「设置 → 关于 → 卸载秘书」，也可以直接运行程序文件夹里的 `卸载秘书.ps1`。

秘书在自己文件夹以外做过的每一处改动（开机启动快捷方式、「开始」菜单快捷方式、卸载登记、临时文件夹等）都记在 `data\changes.jsonl` 里，卸载时按倒序原样还原，最后核对有没有剩下的东西并在桌面留一份报告。可以选「保留我的数据」（先把数据打包到桌面，不含任何密钥）或「全部删除」。卸载后记得到 AI 服务商网站上删掉你给秘书用的密钥。

### 从源码运行 / 编译

```powershell
# 编译 秘书.exe、Ed25519.dll，并从 nuget.org 下载 WebView2 SDK（核对 SHA256）
powershell -ExecutionPolicy Bypass -File .\build.ps1 -FetchWebView2
# 运行
.\v0.2\秘书.exe
# 跑后台测试（不碰真的微信、不发真消息）
powershell -ExecutionPolicy Bypass -File .\v0.2\tools\跑测试.ps1
```

只用 Windows 自带的 .NET Framework 编译器，不需要 Visual Studio。安装包由 GitHub Actions 在打 `v*` 标签时用 Inno Setup 生成（`.github/workflows/release.yml`、`installer/secretary.iss`）。

### 声明

本项目是个人开源项目，与腾讯（微信）、微软（Windows、Outlook、Edge）、Anthropic、DeepSeek 等公司**没有任何关联**，也未获得它们的认可。相关名称和商标归各自所有者。请只在你自己的账号和电脑上使用，并遵守相关软件的用户协议和当地法律。

---

## English

A secretary that runs on your own Windows PC. It watches chat apps such as WeChat, plus mail and folders, and sorts out what needs your reply, what you promised, and what has a deadline, then reminds you on time. After you confirm, it can also send a message for you.

### How it reads

- **Screen only**: it reads the text shown in chat windows with the built-in Windows OCR (`Windows.Media.Ocr`) and UI Automation. When a window is minimized it briefly shows it fully transparent, captures it and hides it again, without taking focus or touching your mouse and keyboard.
- **No WeChat database decryption, no injection or hooking** of any program, and no reading of other apps' internal files.
- Messages are sent only after you click a confirmation card, by putting the text into the chat input box (clipboard paste / simulated keys); the chat name is verified first and nothing is sent on a mismatch.

### Your data

- Everything is stored locally under `data\` in the program folder, encrypted with Windows DPAPI (current user).
- **Bring your own key**: the AI uses your own API key (Anthropic Claude, DeepSeek or an OpenAI-compatible endpoint), also stored with DPAPI. Text to be organized (and screenshots, if you allow it) is sent to the AI provider you chose.
- The optional account / store server (default `https://secretary.demandatlas.online`, configurable in `v0.2\默认设置.json` or in Settings) is used for sign-in, updates, signed plugins and, if you use the account's AI allowance instead of your own key, for relaying AI requests. The app works without signing in.
- See [PRIVACY.md](PRIVACY.md).

### Install

Download `PersonalSecretary-Setup-<version>.exe` from Releases and verify it against `SHA256SUMS`. It installs per user to `%LOCALAPPDATA%\Programs\PersonalSecretary` with **no admin rights**, and it does not enable autostart. The installer is **not code-signed**, so SmartScreen will warn you: click "More info" → "Run anyway". It requires Windows 10/11 with the Microsoft Edge WebView2 Runtime.

### Uninstall

Uninstall from Settings → Apps, from 设置 → 关于 → 卸载秘书 inside the app, or by running `卸载秘书.ps1`. Every change the app made outside its own folder is recorded in `data\changes.jsonl` and reverted in reverse order; leftovers are checked and a report is written to the desktop. Remember to revoke your AI key on the provider's website.

### Build from source

Run `build.ps1 -FetchWebView2` (it uses the .NET Framework `csc.exe` that ships with Windows; no Visual Studio needed), then start `v0.2\秘书.exe`. Run the tests with `v0.2\tools\跑测试.ps1`. Release installers are built by GitHub Actions with Inno Setup when a `v*` tag is pushed.

### Disclaimer

This is an independent open-source project. It is **not affiliated with or endorsed by** Tencent (WeChat), Microsoft (Windows, Outlook, Edge), Anthropic, DeepSeek or any other company. All names and trademarks belong to their owners. Use it only with your own accounts and computer, and follow the relevant terms of service and local laws.

### License

AGPL-3.0-or-later. Copyright (C) 2026 ChefDeCode. The account / store server is a separate project and is not part of this repository.
