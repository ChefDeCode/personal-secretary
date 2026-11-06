# 隐私说明 / Privacy

## 中文

**存在哪里**
- 秘书读到的消息、整理出的事项、和你的对话、记忆、截图，都存在程序文件夹下的 `data\` 和 `v0.2\data\`，用 Windows DPAPI（当前用户）加密。
- AI 密钥、登录凭据同样用 DPAPI 加密，只在本机进程里解开，不写进日志。
- 运行日志（质量、耗时、资源记录）设计上只记次数、耗时和状态，不记消息内容；错误日志可能带出错时的技术信息，同样只在本机。

**发到哪里**
- **你选的 AI 服务商**（Anthropic / DeepSeek / OpenAI 兼容接口，用你自己的密钥）：需要整理的消息文字；你在设置里允许「云端看图」时还有截图。由服务商按它的隐私政策处理。
- **账号 / 商城服务端**（可选，默认 `https://secretary.demandatlas.online`，可改）：在你登录、检查更新、下载插件时联系，发的是登录信息和设备名（默认是「Windows 用户名 的 电脑名」，用来在账号页面区分你的设备）。只有当你不用自己的密钥、而选择用账号里的 AI 额度时，需要整理的文字才会经过这个服务端转给 AI。不登录也能用。
- 除此以外不联网，没有统计、没有遥测。

**怎么读**
- 只看屏幕上显示的字（Windows 文字识别 + 界面自动化）。不解密微信数据库，不注入、不挂钩任何程序。

**怎么删**
- 卸载时选「全部删除」会删掉程序文件夹（含所有数据）并还原它在外面做过的改动；选「保留我的数据」会先把数据打包到桌面（不含密钥）。
- 卸载后请到 AI 服务商网站删掉给秘书用的密钥。

## English

**Where data lives**
- Everything the app reads or produces (messages, tasks, chat with the secretary, memory, screenshots) is stored under `data\` and `v0.2\data\` in the program folder, encrypted with Windows DPAPI (current user).
- AI keys and sign-in credentials are also DPAPI-encrypted, decrypted only in-process, and never logged.
- Run logs (quality, timing, resource records) are designed to hold counts, timings and states, not message content; the error log may contain technical details of failures. All logs stay local.

**What leaves your PC**
- **Your chosen AI provider** (Anthropic, DeepSeek or an OpenAI-compatible endpoint, with your own key) receives the message text to be organized, plus screenshots if you enable cloud image reading. The provider's own privacy policy applies.
- **The optional account / store server** (default `https://secretary.demandatlas.online`, configurable) is contacted for sign-in, update checks and plugin downloads, and receives sign-in data and a device name (by default "<Windows user name> 的 <computer name>", so you can tell your devices apart on the account page). Only if you choose the account's AI allowance instead of your own key does the text to be organized pass through that server to the AI. The app works without signing in.
- Nothing else: no analytics and no telemetry.

**How it reads**
- Screen text only (Windows OCR + UI Automation). No WeChat database decryption, no injection or hooking.

**Deleting**
- Uninstall with "全部删除" (delete all) to remove the program folder with all data and revert every external change; "保留我的数据" (keep my data) first zips your data, without keys, to the desktop.
- After uninstalling, revoke the AI key on your provider's website.
