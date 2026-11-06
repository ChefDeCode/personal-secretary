# 参与贡献 / Contributing

## 中文

- 提交前跑一遍后台测试：`powershell -ExecutionPolicy Bypass -File .\v0.2\tools\跑测试.ps1`。要全部通过（服务端连不上时相关几组会显示「跳过」）。
- 前台测试（会动鼠标键盘、开测试窗口）只在你自己确认可以时加 `-Foreground` 跑；测试永远不点真的微信，只用 `v0.2\tests` 里的假窗口（先 `build.ps1 -Tests` 编出来）。
- 测试和测试数据里只用虚构的名字和内容（「测试联系人A」「张三」之类），不要放真实的聊天记录、名字、路径或密钥。
- 在程序文件夹以外改任何东西（注册表、快捷方式、环境变量、计划任务、临时文件夹）都必须经过 `v0.2\lib_改动记录.ps1`，否则 `code_check_test` 会失败。
- PowerShell 5.1：含中文的 .ps1 存成带 BOM 的 UTF-8；注意变量名不分大小写；不要用和内置别名同名的函数名。
- 新文件加上许可证头：`SPDX-License-Identifier: AGPL-3.0-or-later`。提交即表示你同意以 AGPL-3.0-or-later 授权你的贡献。

## English

- Run the background tests before submitting (`v0.2\tools\跑测试.ps1`); everything must pass (server-dependent groups show as skipped when the server is unreachable).
- Foreground tests move the mouse and keyboard; run them with `-Foreground` only when you are ready. Tests never touch the real WeChat; they use the fake windows in `v0.2\tests` (build them with `build.ps1 -Tests`).
- Use only fictional names and content in tests and fixtures: no real chats, names, paths or keys.
- Any change outside the program folder must go through `v0.2\lib_改动记录.ps1`, which `code_check_test` enforces.
- PowerShell 5.1: save .ps1 files containing Chinese as UTF-8 with BOM.
- Add the license header (`SPDX-License-Identifier: AGPL-3.0-or-later`) to new files. By contributing you agree to license your contribution under AGPL-3.0-or-later.
