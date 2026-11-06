# 安全 / Security

## 报告漏洞 / Reporting a vulnerability

请**不要**在公开 issue 里贴漏洞细节。用 GitHub 的私密漏洞报告：仓库页面 → Security → Report a vulnerability。
Please do **not** post vulnerability details in public issues. Use GitHub private vulnerability reporting: Security → Report a vulnerability.

## 设计上的安全约束 / Security design

- 发消息必须由用户在确认卡片上点「发送」；插件不能发消息。发之前核对聊天名字，对不上不发。
  Sending always requires a user click on a confirmation card; plugins can never send. The chat name is verified before sending.
- 密钥和数据用 Windows DPAPI（当前用户）加密。
  Keys and data are encrypted with Windows DPAPI (current user).
- 商城插件和更新包用 Ed25519 签名，客户端里钉死了公钥（商城 `b8cfcbfd9b14e39d`，更新 `adbeb7b56b0e8c53`）。仓库里**没有任何私钥**。
  Store plugins and updates are Ed25519-signed and verified against pinned public keys (store `b8cfcbfd9b14e39d`, release `adbeb7b56b0e8c53`). No private key is in this repository.
- 服务端地址只允许 https（本机 127.0.0.1 除外）。
  Server URLs must be https (except 127.0.0.1 for local development).
- 秘书在自己文件夹以外的每一处改动都记在改动记录里，卸载时原样还原；有自检测试保证没有绕过记录的改动。
  Every change outside the program folder goes through the change journal and is reverted on uninstall; a static check enforces this.
- 不解密其他软件的数据库，不注入、不挂钩其他进程。
  No decryption of other apps' databases, no injection or hooking.

## 安装包 / Installer

Release 里的安装包由 GitHub Actions 从源码编译，附 `SHA256SUMS`。安装包没有代码签名。
Release installers are built from source by GitHub Actions and ship with `SHA256SUMS`. They are not code-signed.
