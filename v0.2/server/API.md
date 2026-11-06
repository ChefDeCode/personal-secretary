# 个人秘书服务端 API（v1，服务端 0.1.0）

账号 / 商城服务端是单独的项目，**不在这个仓库里**。这里只记客户端要用到的接口约定。

## 0. 怎么连上

| 地址 | 说明 |
|---|---|
| 默认 `https://secretary.demandatlas.online` | 正式服务端（可在 `v0.2\默认设置.json` 或设置里改）。 |
| `http://127.0.0.1:<端口>` | 本机自己跑的服务端（开发 / 测试用；只有 127.0.0.1 允许 http）。 |
客户端应把基础地址做成可配置项，所有路径都相对于它。`GET /healthz` 可以用来测通。

## 1. 通用约定

- 请求和响应都是 UTF-8 JSON（下载插件包和流式回答除外）。
- 设备接口都要带 `Authorization: Bearer <access_token>`。
- 出错时统一返回：
  ```json
  {"error": {"code": "quota_exhausted", "message": "今天的额度用完了。", "retryable": false, "...": "附加字段"}}
  ```
  `message` 是能直接给用户看的中文。`retryable: true` 时可以稍后重试；带 `Retry-After` 头时按它等。
- 401 `token_revoked` / `no_token`：清掉本地 token，重新走设备登录。

## 2. 设备登录（不经手任何 Claude 密钥）

流程和 RFC 8628 设备码登录相同：

1. `POST /v1/device/code`，body `{"device_name": "测试电脑"}`，返回：
   ```json
   {"device_code": "…（保密，只存在内存）", "user_code": "BCDF-2345",
    "verification_uri": "http://127.0.0.1:8810/device",
    "verification_uri_complete": "http://127.0.0.1:8810/device?code=BCDF-2345",
    "expires_in": 600, "interval": 5}
   ```
2. 客户端显示 `user_code`，并用默认浏览器打开 `verification_uri_complete`。用户在网页上登录账号，核对码，然后点“允许”。
3. 客户端每 `interval` 秒调用一次 `POST /v1/device/token`，body `{"device_code": "…"}`：
   - 400 `authorization_pending`：继续等。
   - 400 `slow_down`：把间隔加到返回的 `interval`。
   - 400 `access_denied` / `expired_token` / `invalid_grant`：停止，提示用户重来。
   - 200 `{"access_token": "sst_…", "token_type": "Bearer", "device_id": "dev_…"}`：拿到 token。
4. token 只发这一次，服务端只存它的哈希。客户端用 DPAPI 加密保存。token 不会自动过期，用户随时可以撤销。

其他接口：
- `GET /v1/me` → `{"user": {"id","email","name"}, "device": {"id","name"}}`
- `GET /v1/devices` → `{"devices": [{"id","name","created_at","last_seen","revoked_at","current"}]}`
- `DELETE /v1/devices/self`：本机退出登录。`DELETE /v1/devices/{id}`：让别的设备退出。成功返回 204。
- 网页 `/account`：用户看套餐、用量和设备，也可以在这里让设备退出。

## 3. 套餐、权益、用量

- `GET /v1/plans`（不需要登录）→ `{"plans": [...], "payments": "not_enabled"}`
- `GET /v1/entitlements` →
  ```json
  {"plan": {"id": "free", "name": "免费版", "status": "active", "period_end": null},
   "day": "2026-11-01", "resets_at": "2026-11-01T16:00:00Z",
   "daily":   {"limit": 50000,   "used": 1200, "remaining": 48800},
   "monthly": {"limit": 1000000, "used": 1200, "remaining": 998800},
   "max_output_tokens": 4000, "requests_per_minute": 10,
   "models": ["claude-opus-5-5"], "default_model": "claude-opus-5-5"}
  ```
  “额度”按 token 计：输入、输出、缓存读、缓存写四项相加。“天”按北京时间计算，`resets_at` 是下次重置的 UTC 时间。
- `GET /v1/usage?days=30` → `{"days": [{"day", "requests", "tokens", "by_feature": {"chat": {...}, "summary": {...}}}]}`
- `POST /v1/billing/checkout` → 501 `payments_not_enabled`。付费功能现在还没开放。

具体额度和可用模型以 `GET /v1/entitlements` 返回的为准。

## 4. AI 代理

`POST /v1/ai/messages`

```json
{"messages": [{"role": "user", "content": "帮我看看今天有什么要回的"}],
 "system": "你是……（可选）",
 "model": "claude-opus-5-5",      // 可选，必须在套餐的 models 里
 "max_tokens": 2000,              // 可选；会被压到套餐上限和剩余额度以内
 "effort": "medium",              // low | medium | high，默认 medium
 "feature": "chat",               // 用量分类，小写字母数字下划线，例如 chat / summary / adapter_check
 "tools": [ {"name": "...", "description": "...", "input_schema": {...}} ],  // 可选，只能是客户端自己执行的工具
 "tool_choice": {"type": "auto"}, // 可选，只接受 auto / none
 "stream": true}                  // 默认 true
```

- 内容块只接受 `text`、`image`、`tool_use`、`tool_result`、`thinking`、`redacted_thinking`。多轮对话时，把上一轮 `done.content` 原样放回 assistant 消息里，thinking 块也要放回。
- 不支持服务端工具，例如联网搜索。
- 服务端会自动带上拒答时换模型重试的设置（fallbacks），客户端不用管。

**流式响应**（`text/event-stream`）：

```
event: start
data: {"model": "claude-opus-5-5", "max_tokens": 2000}

event: text
data: {"text": "你好"}            ← 可能有很多条，依次拼接

event: done
data: {"stop_reason": "end_turn", "model": "...", "content": [...完整内容块...],
       "usage": {"input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
       "allowance": { …和 /v1/entitlements 一样… }}

event: error                      ← 中途出错时代替 done
data: {"code": "upstream_busy", "message": "...", "retryable": true, "retry_after": 20}
```

- `stop_reason: "tool_use"` 时，从 `content` 里取出 `tool_use` 块，在本机执行，再把 `tool_result` 作为下一条 user 消息发回来。
- 客户端中途断开时，已经产生的用量照样计入。
- `stream: false` 时直接返回 JSON：`{stop_reason, model, content, usage, allowance}`。

请求开始前会做这些检查，出错码如下：

| 状态码 | code | 含义 |
|---|---|---|
| 429 | `quota_exhausted` | 额度用完。带 `scope`（daily/monthly）、`resets_at` 和 `allowance` |
| 429 | `rate_limited` / `too_many_inflight` | 请求太快，或同时进行的请求太多。带 `retry_after` |
| 403 | `model_not_in_plan` | 套餐不含这个模型。带 `models` |
| 400 | `bad_messages` / `bad_block` / `bad_tools` / … | 请求格式不对 |
| 503 | `model_not_configured` | 服务端还没录入 Claude 密钥 |
| 503 | `upstream_busy` / `upstream_unreachable` | AI 服务暂时不可用，可以重试 |

## 5. 插件商店（适配器）

### 5.1 插件包格式

插件包是一个 zip，里面**只能有**这三个文件，最大 256 KB：

- `manifest.json`：
  ```json
  {"id": "wechat-desktop", "name": "微信（桌面版）只读", "version": "1.0.0",
   "summary": "……", "app": {"process": "WeChat.exe", "display": "微信", "tested_versions": ["3.9"]},
   "permissions": ["app.observe", "region.read:chat_list", "..."],
   "can": ["给用户看的“能做什么”"], "cannot": ["给用户看的“不会做什么”"], "changelog": "……"}
  ```
- `config.json`：`{"match": {...窗口匹配...}, "regions": {"chat_list": {...}, ...}}`。只允许 6 个区域：`chat_list`、`message_area`、`sender`、`unread_marker`、`search_box`、`input_box`。区域里写什么坐标或锚点格式，由客户端定，服务端不检查。
- `script.json`：受限脚本，不是 PowerShell。格式是 `{"actions": {"动作名": [步骤, ...]}}`，所有动作加起来最多 200 步。

### 5.2 权限和脚本步骤（服务端和客户端都要检查）

| 步骤 `op` | 参数 | 需要的权限 | 风险 |
|---|---|---|---|
| `find_window` | | `app.observe` | 低 |
| `read_region` / `list_items` / `assert_visible` | `region`, `as` | `region.read:<region>` | 中 |
| `focus` | `region` | `ui.focus` | 低 |
| `press_key` | `key` ∈ Up/Down/PageUp/PageDown/Home/End/Escape | `ui.navigate` | 低 |
| `click_item` | `region` ∈ chat_list/search_box/input_box | `ui.click:<region>` | 中 |
| `type_text` | `region: search_box`, `text` | `input.search` | 中 |
| `type_text` | `region: input_box`, `text` | `input.draft` | 中 |
| `press_key` | `key: Enter`, `region: input_box` | `input.send` | **高** |
| `wait` | `ms` ≤ 5000 | 无 | |
| `emit` | `field` | 无（把读到的值交给秘书） | |

`text` 可以是字面量，也可以写 `$参数名`，由秘书调用动作时传入。

服务端收到插件包时会检查：

- 权限只能来自上表。联网、文件、进程、别的应用这些能力根本没有对应的权限名，写了就会被拒（`unknown_permission`）。
- 每个步骤需要的权限都必须在 manifest 里声明（否则 `script_exceeds_permissions`）。声明了但没用到的权限也会被拒（`unused_permission`），这样权限卡片和插件实际能做的事完全一致。
- 同一个插件的新版本不能换成别的应用（`app_changed`），版本号必须递增。

客户端执行时**必须再按同一张表检查一遍**，遇到没在 manifest 里声明的步骤就拒绝执行。服务端不下发代码以外的任何东西。

完整权限表（带中文说明和风险等级，可以直接用来画权限卡片）：`GET /v1/store/permissions`（不需要登录）。

### 5.3 接口

- `GET /v1/store/plugins?q=微信&app_process=WeChat.exe` → `{"plugins": [{"id","name","summary","publisher","app","latest_version","highest_risk"}]}`。只列出有已批准版本的插件。
- `GET /v1/store/plugins/{id}` → `{"id","name","summary","publisher","versions": [{"version","review_status","reviewed_at","sha256","size","permissions": [{"id","text","risk"}],"can","cannot","app","changelog"}]}`。只含已批准和已下架的版本。
- `GET /v1/store/plugins/{id}/versions/{ver}/package` → zip 文件本身，带 `X-Package-Sha256` 头。只有已批准的版本能下载，其他返回 404。
- `GET /v1/store/plugins/{id}/versions/{ver}/signature` →
  ```json
  {"statement": {"plugin_id","version","sha256","size","app_process","permissions": [...],"review_status": "approved","approved_at","key_id"},
   "signature": "base64", "alg": "Ed25519", "context": "secretary-plugin-v1"}
  ```
- `POST /v1/store/updates`，body `{"installed": [{"id": "wechat-desktop", "version": "1.0.0"}]}` → 每项返回：
  - `{"status": "up_to_date"}`
  - `{"status": "withdrawn", "withdrawn": true}`：这个版本已下架，客户端应停用它，并提示用户卸载或更新。
  - `{"status": "update_available", "latest": {…同 versions[] 一项，另加 added_permissions / removed_permissions…}, "requires_reconsent": true|false}`
- `POST /v1/store/plugins/{id}/reports`，body `{"version": "1.0.0", "kind": "broken|wrong_app|asks_too_much|privacy|other", "detail": "最多 1000 字"}` → 201。**detail 里不要放任何读到的消息内容。**
- `POST /v1/store/events`，body `{"id","version","action": "install|update|uninstall|self_check_failed"}` → 204。只用于统计，不影响任何功能。

### 5.4 客户端安装和更新时必须做的检查

1. 下载 package 和 signature。
2. 算出 zip 的 SHA-256，必须等于 `statement.sha256`。
3. 用**内置在客户端里**的商店公钥验证签名：签名的原文是 `"secretary-plugin-v1\n"` 加上 statement 的规范 JSON（键名排序、无空格、UTF-8 原样输出非 ASCII 字符，等同于 Python 的 `json.dumps(x, ensure_ascii=False, sort_keys=True, separators=(',',':'))`）。
4. 解开 zip，检查 manifest 的 `id`、`version`、`app.process` 和排序后的 `permissions` 都和 statement 一致；再按 5.2 的表把脚本检查一遍。
5. 显示权限卡片（第一次安装，或 `requires_reconsent` 为 true 时），用户同意后再自检。
6. 更新时如果新版本多了权限，**不自动更新**，必须让用户重新确认。少了权限可以直接更新。
7. 客户端自己的权限模式比插件更严时，按更严的来。插件永远不能扩大权限。

商店公钥也可以从 `GET /v1/meta` 的 `store_signing_key` 拿到，但只应在开发时这样做。正式版要把公钥写死在客户端里，不能信任从网络拿到的公钥。

正式版客户端钉死的商城公钥 key_id 是 `b8cfcbfd9b14e39d`，更新包公钥 key_id 是 `adbeb7b56b0e8c53`（见 `v0.2\lib_商店.ps1`）。服务端的部署和管理不属于这个仓库。
