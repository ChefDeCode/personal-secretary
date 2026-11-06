# 插件包格式（客户端实际接受的样子）

写给服务端：这里只写客户端**真的在检查、真的在用**的东西。依据的是 `v0.2\lib_商店.ps1` 里的 `Test-PluginPackage`、`Test-PluginScript`、`Get-StepPermission`、`Test-RegionSpec` 和 `Invoke-PluginAction`。
「保留」表示客户端能接受这个字段，但现在还不用它。

## 0. 包和签名

**包** 是一个 zip 文件：

- 正好 3 个文件，都在根目录：`manifest.json`、`config.json`、`script.json`。
- 不能有子目录，文件名里不能有 `/` 或 `\`。
- 不能有多余的文件。
- 每个文件不超过 256 KB，整个 zip 也不超过 256 KB。
- 3 个文件都是 UTF-8 编码的 JSON。

**签名** 对应 `GET .../versions/{ver}/signature` 返回的内容：

```json
{ "alg": "Ed25519", "context": "secretary-plugin-v1",
  "statement": { "plugin_id": "...", "version": "...", "sha256": "<zip 的 hex>", "size": 1234,
                 "key_id": "...", "review_status": "approved", "app_process": "Foo.exe",
                 "permissions": ["..."] , "approved_at": "..." },
  "signature": "<base64，64 字节>" }
```

- 签名的原文是 `"secretary-plugin-v1\n" + 规范 JSON(statement)`。
  - 规范 JSON 等同于 Python 的 `json.dumps(x, ensure_ascii=False, sort_keys=True, separators=(',',':'))`。
  - statement 里可以有别的字段，它们会一起参与签名。
- 客户端只信任内置的商店公钥：
  - 正式钥匙：`b8cfcbfd9b14e39d`。
  - 测试模式下用测试钥匙。
  - 客户端从不使用网上给的钥匙。
- 客户端还会把 `/v1/meta` 公布的 `store_signing_key` 和内置钥匙核对。对不上，整个商城就不被信任。
- 商店钥匙和更新钥匙分开：用商店钥匙签的东西不能当更新包用，反过来也一样。
- 列表接口里的字段（`category`、`featured`、`listed`、`installs`……）不参与校验。客户端遇到不认识的字段一律忽略。

## 1. manifest.json

| 字段 | 必须 | 客户端怎么用 |
|---|---|---|
| `id` | 是 | 必须等于 `statement.plugin_id`；也作为本机的目录名 |
| `version` | 是 | 必须等于 `statement.version` |
| `app.process` | 是 | 必须等于 `statement.app_process`（比较时区分大小写）。运行时按进程名找窗口：去掉 `.exe`，取这个进程面积最大的普通顶层窗口 |
| `app.display` | 建议 | 权限卡片和列表上显示的软件名 |
| `permissions` | 是 | 字符串数组。**排序后**必须和 `statement.permissions` 排序后完全一样 |
| `name`、`summary`、`can`、`cannot`、`changelog` | 建议 | 显示在权限卡片上（能做 / 不会做） |
| `app.tested_versions` | 保留 | 只用来显示 |
| `category` | 可选 | 只用来显示和筛选，不参与校验 |
| `min_client` | 保留 | 客户端现在还不检查 |

## 2. config.json

```json
{ "match":   { "window_class": "..." },
  "regions": { "<区域名>": { ... }, ... } }
```

**区域名** 只能是这 6 个：`chat_list`、`message_area`、`sender`、`unread_marker`、`search_box`、`input_box`。出现别的名字，整个包就被拒。

**坐标**：

- 用相对于整个窗口的比例，取值 0 到 1，原点在左上角。
  - 客户端用 PrintWindow 截整个顶层窗口，所以这里的「整个窗口」是窗口矩形，不是客户区。
  - 无边框应用（微信、Electron 应用）的窗口矩形和客户区是一样的。
- 跟 DPI 无关：客户端是按每台显示器的 DPI 截图的，比例在 100%、150% 上通用。
- 不要写像素。

**区域的两种写法**（都接受）：

- 推荐：`{ "x": 0.31, "y": 0.08, "w": 0.69, "h": 0.66 }`
  - 四个值都必须给，都在 0 到 1 之间。
  - `w`、`h` 要大于 0。
  - `x + w ≤ 1`，`y + h ≤ 1`。
  - 可以加 `"anchor": "left|right"`，只是说明，客户端不用它。
- 兼容：`{ "x0": 0.31, "y0": 0.08, "x1": 1.0, "y1": 0.74 }`
  - 要求 `x1 > x0`，`y1 > y0`。

**子区域**：`{ "within": "chat_list", ... }`

- 没有自己的框时，用父区域的框。
- `within` 必须指向同一个 config 里的另一个区域，而且只能嵌套一层。
- 可以带 `shape`、`color`、`source` 这些提示，但客户端**现在不用**，只按父区域的框做 OCR。

**其它字段**：

- `match.window_class`：保留。现在只靠进程名找窗口。
- 说话人方向（`self_side`）：保留。微信的「自己在哪一边」现在由客户端自己判断：气泡位置为主，绿色为辅，两者矛盾时记「不确定」。插件里的这个字段现在不生效。

## 3. script.json

```json
{ "actions": { "<动作名>": [ { "op": "...", ... }, ... ], ... } }
```

- 动作名和字段名（`as`、`emit` 的 `field`）必须符合 `^[A-Za-z_][A-Za-z0-9_]{0,63}$`。
- 所有动作加起来不超过 200 步。
- 每一步需要的权限都必须在 `permissions` 里声明；声明了的权限也必须真的被某一步用到。
- 权限必须在下表里，不在表里的一律拒绝。

| op | 其它字段 | 需要的权限 | 规则 |
|---|---|---|---|
| `find_window` | — | `app.observe` | 截取窗口；后面的读取步骤都要先有这一步 |
| `read_region` | `region`，可选 `as` | `region.read:<region>` | 对这个区域做 OCR，文字按行从上到下拼起来 |
| `list_items` | `region`，可选 `as` | `region.read:<region>` | 把这个区域按列表行切开读，得到每行的名字 |
| `assert_visible` | `region` | `region.read:<region>` | 区域里没有文字就让这个动作失败 |
| `focus` | — | `ui.focus` | 只有用户自己发起的动作里才执行 |
| `press_key` | `key` | 方向键类：`ui.navigate` | `key` 只能是 Up / Down / PageUp / PageDown / Home / End / Escape，而且**不能带 `region`**（API 0.2.0） |
| `press_key` | `key: "Enter"`，`region: "input_box"` | `input.send` | Enter 只能配 `region: input_box`。客户端**从不直接执行**这一步：一律交给秘书自己的发送确认卡，用户点了才发 |
| `click_item` | `region` | `ui.click:<region>` | 区域只能是 chat_list / search_box / input_box；只在用户发起的动作里执行 |
| `type_text` | `region`，`text`（`$参数名` 表示从参数取） | search_box → `input.search`；input_box → `input.draft` | 只能打进这两个区域；只在用户发起时执行；从不按发送 |
| `wait` | `ms` | — | 必须是整数，1 到 5000 |
| `emit` | `field` | — | 把前面 `as` 存下的值作为结果输出 |

每次执行前，客户端都会把脚本按上表重新查一遍，不只在安装的时候查。

## 4. 读法（客户端支持哪些）

**OCR 区域**：插件就是这种读法，在 `config.regions` 里给出比例框，客户端截图后用本机 Windows OCR 识别。

- 适合 Qt / 原生界面、UI 自动化里读不到文字的应用：微信 4.x、QQ NT。
- 也适合任何能截到图的应用。

**UI 自动化（UIA）**：只有秘书自己适配出来的读法会用，插件格式里**还没有** UIA 步骤。

- 秘书添加软件时，会先在 UIA 树里数一数能读到的文字节点。够多（≥5 个）就用 UIA 读，否则用 OCR。
- 适合 UIA 读得到的 Electron 或原生应用：飞书、钉钉、Outlook 多半是这一类，企业微信要实测。
- 子区域里的 `"source": "accessibility_name"` 是保留字段，客户端现在会忽略它，改用 OCR。

**给没有那个应用、预先写好的官方插件的建议**：

- 用 OCR 区域，框尽量留宽一点。
- 只读的动作尽量简单：`find_window` → `list_items` / `read_region` → `emit`。

**自检**（现在的实际情况）：

- 已经有 `Test-PluginSelf`：跑第一个只读动作，只记数字，看能不能读出东西。
- 已经做好的：插件的安装、更新、卸载、校验，以及每次执行前重新检查脚本。
- **还没接上**的：
  - 值守在日常读取里调用插件；
  - 自检不过时自动从截图重新适配、并告诉用户（会用秘书已有的自动适配流程）。

  这两步做好之前，装了插件的应用仍然由秘书自己适配的读法来读。

## 5. 客户端拒绝一个包的情况

**签名和声明**：

- 没有内置的商店钥匙。
- 签名不对：`alg` 或 `context` 不对；用的不是内置钥匙；`key_id` 和内置钥匙不一致；声明被改过。
- `review_status` 不是 `approved`。
- `/v1/meta` 公布的钥匙和内置钥匙对不上。这种情况下整个商城都不被信任。

**zip 本身**：

- zip 的 SHA-256 或大小和声明不一致（也会和响应头 `X-Package-Sha256` 核对）。
- zip 超过 256 KB。
- 文件不是正好那 3 个；有子目录；单个文件超过 256 KB；不是合法的 zip 或 JSON。

**manifest**：

- `id`、`version`、`app.process` 和声明不一致。
- 权限（排序后）和声明不一致。

**config 区域**：

- 区域名不在那 6 个里面。
- 框缺值，或者数值不在 0 到 1 之间。
- 框出了窗口。
- `within` 指向不存在的区域、指向自己，或者嵌套了两层。

**script 脚本**：

- 出现不认识的 op 或权限。
- 动作名或字段名不合法。
- 方向键带了 region。
- Enter 不在 input_box 上。
- click / type 用在不允许的区域。
- `wait` 不在 1 到 5000 之间。
- 超过 200 步。
- 某一步用了没声明的权限，或者声明了从没用到的权限。

## 6. 最小的合法例子（一个虚构的只读应用）

manifest.json：

```json
{ "id": "example-notes", "name": "示例笔记（只读）", "version": "1.0.0", "category": "office",
  "summary": "读出示例笔记左侧的笔记列表和当前打开的笔记。",
  "app": { "process": "ExampleNotes.exe", "display": "示例笔记", "tested_versions": ["1.0"] },
  "permissions": ["app.observe", "region.read:chat_list", "region.read:message_area", "ui.navigate"],
  "can": ["看左侧的笔记列表", "读出当前打开的笔记", "用 PageDown 往下翻列表"],
  "cannot": ["不会点开、不会打字、不会发送", "不会联网、不会读写文件"] }
```

config.json：

```json
{ "regions": {
    "chat_list":    { "anchor": "left",  "x": 0.0,  "y": 0.08, "w": 0.28, "h": 0.92 },
    "message_area": { "anchor": "right", "x": 0.28, "y": 0.08, "w": 0.72, "h": 0.92 } } }
```

script.json：

```json
{ "actions": {
    "list_notes":   [ { "op": "find_window" }, { "op": "list_items", "region": "chat_list", "as": "notes" }, { "op": "emit", "field": "notes" } ],
    "read_current": [ { "op": "find_window" }, { "op": "read_region", "region": "message_area", "as": "text" }, { "op": "emit", "field": "text" } ],
    "next_page":    [ { "op": "find_window" }, { "op": "press_key", "key": "PageDown" } ] } }
```

statement：

```json
{ "plugin_id": "example-notes", "version": "1.0.0", "app_process": "ExampleNotes.exe",
  "permissions": [ ...与 manifest 相同... ], "review_status": "approved",
  "sha256": "<zip>", "size": <zip 字节数>, "key_id": "<钥匙>" }
```

验证结果见 `v0.2\tests\plugin_format_test.ps1`：在开发模式下，用临时生成的测试钥匙签名，跑客户端完整的 `Test-PluginPackage`。
