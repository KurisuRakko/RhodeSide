# Rhodeside

macOS 菜单栏桌宠：明日方舟的 Spine 小人沿屏幕底部（程序坞上沿）和窗口顶边走来走去，
能拎起来扔、点一下互动。渲染和界面都在平台无关的 `web/` 里（见[根目录 README](../README.md)「分层」）。

设计和取舍见 [plan.md](plan.md)。

## 部署（在 rakkoserver 上执行）

```bash
corepack pnpm mac:deploy   # 全量：Mac 上编译签名打包 → 发布 App 与前端 → 各台 Rhodeside 自己下载、替换、重启（编译要 ssh mac）
corepack pnpm mac:web      # 前端热更新：构建并发布到 https://rhodeside.rakko.cn，App 在 5 秒内拉取（不需要 Tailscale）
bash macos/scripts/deploy.sh install   # 编好直接在 Mac 上安装重启（首次安装，或自更新本身坏了时）
corepack pnpm mac:dev      # 监听源码：前端改动 → mac:web；Swift 改动 → mac:deploy
corepack pnpm mac:test     # 在 Mac 上运行 PetCore 单元测试
bash macos/scripts/deploy.sh web-ssh   # 前端直接 ssh 推送，不经公网
bash macos/scripts/deploy.sh logs      # 查看日志最后 80 行
bash macos/scripts/deploy.sh snap      # 保存调试快照（每只桌宠的画布 PNG 与状态 JSON）
```

Mac 通过 `ssh mac` 连接（可用 `RHODESIDE_MAC` 覆盖）。Mac 上的构建目录 `~/Build/Rhodeside/` 只放源码和编译产物；
`.app` 在临时目录组装并 ad-hoc 签名后，整体移动到 `~/Applications/Rhodeside.app`。

### 热更新

| 层 | 方式 | 生效 |
|---|---|---|
| 前端（`web/pet.html`、`web/settings.html`、`web/src/pet\|settings\|stage/`） | `publish.mjs` 打包并用 Ed25519 签名，写入 `/opt/stacks/rhodeside/data`；容器 `rhodeside-updates` 经 cloudflared 对外提供 `https://rhodeside.rakko.cn/v1/manifest.json` | App 每 5 秒检查一次，验签和 sha256 通过后替换 `~/Library/Application Support/Rhodeside/web-dev/` 并原地重新加载，桌宠位置不变 |
| 行为参数（`web/public/rhodeside-tuning.json`：待机 / 坐 / 睡时长、走路概率、跳窗概率、悬停透明度） | 随前端发布 | 重新载入前端时生效 |
| Swift（壳） | `deploy.sh` 打包签名发布到 `v1/app.json` | App 下载验签后交给独立的交接任务（`launchctl submit`）：换掉 `.app`、重启；新版本 8 秒内没报告健康就自动回滚，该版本记入黑名单不再安装 |
| 在线模型（只给登录用户） | 源文件放 `SpineStage/models-private/`（**不要放 web/public**），在 `macos/models.json` 加一条，`deploy.sh models` 发布到 `v1/models.json`（每个模型另有 `v1/previews/` 预览包：默认时装的基建模型） | 登录本身不下载任何模型：用户在模型库 / 设置里点了下载才装；已装的内容变了自动更新 |
| 六星模型（PRTS） | `macos/scripts/fetch-prts.mjs` 从 PRTS 拉全部六星（全部时装 × 基建 / 正面 / 背面）到 `models-private/<干员名>/`，并登记进 `models.json`；定时器 `rhodeside-prts.timer`（systemd 用户单元，每天 04:30 左右）跑 `sync-prts.sh`，有变化就重新发布，日志 `~/.local/state/rhodeside/prts-sync.log` | 新干员 / 新时装第二天出现在模型库里 |
| 本地模型 | 增删改 `~/Library/Application Support/Rhodeside/models/` | 设置页即时刷新，用到该模型的桌宠自动重新加载 |
| 配置 | 编辑 `config.json` | 保存后立即生效；格式错误时忽略 |

App 只接受构建号更大的包；`web-dev` 的构建号不比 App 自带前端新时自动失效。
签名私钥 `~/.config/rhodeside/release-ed25519.pem`，公钥内置在 `Sources/Rhodeside/RemoteUpdater.swift`。
设置 → 更新：关闭自动更新、手动检查、看 App / 前端当前与最新版本。自更新日志在 `~/Library/Application Support/Rhodeside/updates/install.log`。

### 鉴权（Priestess）

- App：必须登录（设置 → 账号，或新装时的引导页；默认浏览器，PKCE）。令牌存 `auth.json`（600）。App 不再内置模型，跳过登录就没有桌宠。
- 服务器：`/opt/stacks/rhodeside` 的 `auth` 容器（`auth/server.mjs`）用 access token 换 10 分钟 HMAC 票据；nginx `auth_request` 校验。
  `compose.yaml` 里 `ENFORCE: "1"`（已启用）：清单和包必须带票据。临时关掉改成 `"0"` 再 `docker compose up -d auth`。
- 回跳页 `https://rhodeside.rakko.cn/auth/callback` 随前端发布。设计细节见 [plan.md](plan.md)。

## 用

- 菜单栏的爪印图标只有：打开 Rhodeside…（⌘,）、隐藏 / 显示桌宠、召回全部、退出。
- Rhodeside 窗口（一个窗口，左边侧栏三页；`rhodeside://pets|models|settings` 直接打开某页）：
  - 版式照系统设置：分组，每行左边名字、右边控件。同一个设置只出现在一处。
  - 桌宠：上面一排选哪只 + 添加；「模型」一行（模型 · 时装 · 形态，点「更换…」）/「显示」大小、不透明度、悬停变淡、PMA /
    「活动」基建形态是方式（自由活动 / 一直行走 / 原地停留）+ 步速，战斗形态（正面 / 背面）不走动，换成循环动作下拉框 /
    「立即动作」基建是互动 / 坐下 / 睡眠 / 站立，战斗形态是套组动作（`web/src/stage/combos.ts` 按动画名认）；最下面召回、移除。
  - 选模型（桌宠页点「更换…」整页切过去，`web/src/settings/ModelPicker.tsx`）：左边已下载的在上、没下载的在线模型在下；
    右边预览，已下载的能切时装 / 形态看效果，没下载的只预览默认时装的基建模型，按钮是「下载并使用」。
  - 模型库：在线模型（左边搜索、勾选，右边预览只循环待机，下载所选）/ 我的模型（已下载和导入的，可删；拖文件夹进窗口即导入）。
  - 设置：账号、所有桌宠（在窗口上行走、其他应用全屏时隐藏、排除的应用）、通用（登录时打开、自动更新 + 更新状态）、故障排查（默认折叠：构建号 + 日志 / 文件夹 / 快照按钮）。
- 桌宠身上：左键点一下是互动（战斗形态播攻击）；按住拖动是拎起来，松手会带着甩出去的速度掉下去；右键不响应。
- 小人旁边的透明区域不挡鼠标（按画布像素判断）。

### 导入模型

模型库 → 我的模型 → 导入…（或者直接把文件夹拖进 Rhodeside 窗口）。要求是 Spine 3.8 导出的 `.skel` 或 `.json` 配同名 `.atlas` 和贴图，
一个文件夹算一个模型，里面可以有多套时装、正面 / 背面 / 基建（`build_` 开头的是基建组，规则见 `web/src/stage/loader.ts`）。
导入时先复制到临时目录，设置页用 `web/src/stage/` 的载入代码把每一套真载一遍，全部通过才放进 `models/`，否则说清楚哪一套为什么不行。
只有基建形态有走路 / 坐 / 睡动画；正面、背面（战斗形态）不走动，只循环桌宠页「活动」里选的动作。

## 文件在哪

| 路径 | 内容 |
|---|---|
| `~/Applications/Rhodeside.app` | 程序（内置网页和荒芜拉普兰德在 `Contents/Resources`） |
| `~/Library/Application Support/Rhodeside/config.json` | 配置（桌宠列表、全局开关、忽略名单） |
| `~/Library/Application Support/Rhodeside/positions.json` | 每只桌宠上次的位置 |
| `~/Library/Application Support/Rhodeside/models/` | 导入的模型（同名时优先于内置的） |
| `~/Library/Application Support/Rhodeside/web-dev/` | 热更新下载的前端 |
| `~/Library/Logs/Rhodeside/rhodeside.log` | 日志（网页的 console 也在这里） |
| `~/Library/Logs/Rhodeside/snapshots/` | 调试快照 |

## 调试链接

在 Mac 上 `open '<链接>'`（ssh 上也行）：

| 链接 | 作用 |
|---|---|
| `rhodeside://settings` | 打开设置 |
| `rhodeside://control`、`rhodeside://pets` | 打开窗口的桌宠页（control 是旧名字） |
| `rhodeside://debug/eval-page?page=control\|settings&js=…` | 在控制面板 / 设置页里跑 JS，结果写日志 |
| `rhodeside://debug/snapshot` | 每只桌宠的画布 PNG + 原生状态 → `snapshots/` |
| `rhodeside://debug/state` | 屏幕、窗口、平台、每只桌宠、内存 → `~/Library/Logs/Rhodeside/state.json` |
| `rhodeside://debug/reload` | 重载所有网页 |
| `rhodeside://debug/summon` | 把桌宠都叫回主屏 |
| `rhodeside://debug/hide?on=1` / `?on=0` | 隐藏 / 显示桌宠 |
| `rhodeside://debug/eval?js=…` | 在每只桌宠的页面里跑一段 JS，结果写日志 |
| `rhodeside://debug/login-item?do=status\|register\|unregister\|probe` | 开机自启探路 |

`defaults write com.rakko.rhodeside verboseResources -bool YES` 以后重启 App，每个资源请求和每次点击判定都会记日志（很吵，查完删掉）。
桌宠和设置页都开了 `isInspectable`：Mac 上 Safari → 开发 → 这台 Mac 下面能直接调试页面。

## 代码结构

```
macos/
  Package.swift
  Sources/PetCore/      纯逻辑（有单元测试）：Geometry 坐标换算和布局、Platforms 窗口顶边遮挡计算和全屏判断、
                        Brain 行为状态机和物理、Config 配置读写
  Sources/Rhodeside/    App：AppDelegate 菜单栏和单实例、PetManager 扫描 / 配置 / 热更新、Pet 一只桌宠（消息、鼠标、每帧）、
                        PetWindow 透明面板、SchemeHandler rhodeside-res://、WindowScanner、Tracking（后台扫描与窗口追踪）、RemoteUpdater（公网热更新）、SettingsController、
                        Importer、ModelLibrary、LoginItem、FileWatcher、Debug、Log
  Tests/PetCoreTests/
  Resources/Info.plist
  scripts/              deploy.sh（服务器）、build-app.sh（Mac）、publish.mjs（签名发布）、dev.mjs（源码监听）
/opt/stacks/rhodeside/  公网更新通道容器（nginx 只读静态服务，127.0.0.1:8067 → rhodeside.rakko.cn）
web/pet.html + web/src/pet/           桌宠渲染页（只有画布）
web/settings.html + web/src/settings/ 设置页（React + Rakko Design）
web/src/stage/                        Spine 载入 / 测量（loader、model）、模型库预览舞台（engine）、套组识别（combos）
web/src/native/transport.ts           页面 ↔ 原生的传输层（前端里唯一碰 WebView API 的地方，见根目录 README「分层」）
```
