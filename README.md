# RhodeSide

**Rhodeside** 是一个桌面桌宠：把明日方舟干员的 Spine 3.8 基建小人放到桌面上，沿着屏幕底边和窗口顶边走来走去，
能拎起来扔、叠罗汉、点一下互动、跟着你的作息坐下睡觉。目前只维护 **macOS** 版；渲染和界面写在平台无关的 `web/` 里，方便以后接 Windows / Linux。

> 仓库原名 SpineStage（2026-09-30 改名）。原来的网页版（拖模型进网页看、`?embed` 嵌入）已下线删除。

- 用法、部署、文件位置、调试链接：[macos/README.md](macos/README.md)
- 设计取舍和现状：[macos/plan.md](macos/plan.md)；较大改动的方案在 `tasks/*.plan.md`

## 能做什么

**小人自己的生活**
- 在地面（程序坞上沿）和别的程序的窗口顶边上走，窗口挪动时跟着走，窗口关了就掉下来；站在窗口上时和那个窗口同层，前面的窗口能盖住它。
- 窗口不在焦点时只在露出来的那段顶边里溜达，不会走到边上掉下去；脚下被盖住了就走到露出来的地方。
- 待机、走路、坐下、睡觉按概率自己挑；可设成一直走或原地停留。
- 鼠标靠近时转过来看；键鼠闲置 1 分钟坐下、3 分钟睡着（放视频时不睡），一动就醒；深夜更容易犯困。
- 基建语音：戳一下、信赖触摸、进驻时说话（可关、可调音量）。

**和你互动**
- 点一下播互动动作；按住拖动拎起来，松手按甩出去的速度扔出去。
- 叠叠乐：扔到别的小人头上就站在它头顶，下面那只走路、被拎起都带着它；叠着的谁都不躺下。
- 窗口撞到时跳上去（默认开）：拖动或缩放窗口压到小人身上，小人弹到窗口顶上。
- 套组：把桌面上的几只存成一组一键召出；同组的结伴走、丢开了互相找、点一只其余的转过来。
- 战斗形态（正面 / 背面模型）：不走动，循环选定的动作，点一下播攻击连招。

**App 本身**
- 菜单栏图标 + 一个窗口（桌宠 / 模型库 / 设置），系统设置式的分组。
- 模型库：登录后从在线目录挑模型下载（六星干员全部时装每天自动同步），也能拖文件夹导入自己的 Spine 3.8 模型。
- 前端和行为参数热更新；App 本身签名自更新，起不来自动回滚。
- 界面三语：简体中文 / 繁體中文（香港）/ English，干员名、时装名跟着换。
- 其他应用全屏时自动隐藏，可按应用名排除「空气窗口」；崩溃和日志自动上传便于排查。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `web/pet.html` + `web/src/pet/` | 桌宠渲染页（只有一张画布，按原生层发来的位置画） |
| `web/{settings,welcome,auth-callback}.html` + `web/src/{settings,library,welcome,auth}/` | 主窗口、引导页、登录回跳页（React + Rakko Design） |
| `web/src/stage/` | Spine 载入 / 测量、模型库预览舞台、连招识别 |
| `web/src/native/transport.ts` | 页面 ↔ 原生壳的传输层（前端里唯一碰具体 WebView API 的文件） |
| `web/src/i18n/` | 界面文案（`zh-Hans.ts` 是基准表） |
| `web/public/rhodeside-tuning.json` | 行为参数（各状态时长、概率），随前端热更新 |
| `web/public/lib/spine/spine-webgl.js` | Spine 3.8 官方 WebGL 运行时原样副本（`scripts/fetch-spine.sh` 可重拉） |
| `macos/Sources/PetCore/` | 纯逻辑：坐标、平台与遮挡、行为状态机与物理、叠叠乐、套组联动、作息、配置（不依赖 AppKit，有单元测试） |
| `macos/Sources/Rhodeside/` | macOS 壳：窗口与层级、鼠标、窗口扫描、资源协议、自更新、登录、日志 |
| `macos/scripts/` | 部署（`deploy.sh`）、打包、签名发布、PRTS 模型与语音抓取 |
| `vendor/rakko-design/` | 设计系统外来件，只能由 `scripts/sync-design.sh` 生成，不要手改 |
| `models-private/` | 有授权的在线模型源文件：只放服务器，**不进前端、不进 dev server、不进仓库** |
| `tasks/` | 方案、审查和后台任务记录 |

## 开发

```bash
corepack pnpm install
corepack pnpm dev      # vite dev，0.0.0.0:8066
corepack pnpm check    # tsc + Rakko Design 合规检查 + 前端单测
```

`pnpm dev` 下用普通浏览器打开（没有原生壳）：
- `/settings.html`、`/welcome.html`：主窗口 / 引导页，走 `web/src/settings/bridge.ts` 里的假原生层（页面上显示「浏览器预览」）。
- `/pet.html?group=基建`：桌宠渲染页调试模式，发给原生的消息打到 console，自己从 `web/public/models/` 载入测试模型（需要 WebGL）。

macOS 版（在 rakkoserver 上执行，Mac 经 `ssh mac` 编译）：

```bash
corepack pnpm mac:test     # Mac 上跑 PetCore 单元测试
corepack pnpm mac:web      # 只发前端：几秒内热更新到各台 App
corepack pnpm mac:deploy   # 全量：编译签名 → 发布 → App 自己下载替换重启
```

改了原生 ↔ 网页的消息协议要把 `RemoteUpdater.bridge` 和 `macos/scripts/publish.mjs` 的 `BRIDGE` 一起 +1，并全量部署（现在是 4）。
其余命令（日志、快照、远程日志、模型发布）见 [macos/README.md](macos/README.md)。

## 分层（保持跨平台）

| 层 | 位置 | 平台 |
|---|---|---|
| 前端：渲染页、界面页、Spine 载入 | `web/` | 平台无关 |
| 传输层 | `web/src/native/transport.ts` | 认得 WKWebView / WebKitGTK（`webkit.messageHandlers`）和 WebView2（`chrome.webview`） |
| 纯逻辑 | `macos/Sources/PetCore/` | 平台无关的 Swift，有单元测试 |
| 壳 | `macos/Sources/Rhodeside/` | macOS |

约定：
- `web/src` 里不许直接用 `webkit.messageHandlers`、`chrome.webview` 这类 WebView 接口（要用就加进 `transport.ts`，`pnpm check` 会查），也不许假设 macOS。
- 页面用相对路径（vite `base: './'`），壳从自定义协议 `rhodeside-res://` 或热更新目录加载。
- 能放网页 / TS 的新逻辑就放网页，Swift 只留平台胶水和状态机。

以后接 Windows / Linux：写一个新壳，实现
1. `transport.ts` 的协议：页面 `post(msg)` 发来的 JSON，以及调 `window.rhodeside.receive(msg)` 发回去；
2. `rhodeside-res://` 资源服务：前端静态文件，加上 `models/<名字>/…`、`previews/<id>/…`、`import/<批次>/…` 三个前缀（文件列表由 `load`、`preview` 等消息带过去）；
3. 行为状态机：照 `PetCore` 移植（`Brain`、`Platforms`、`Stacking`、`Companions`、`Attention`、`WindowHop` 一起）；
4. 窗口层级：站在窗口上的小人排在那个窗口正上方，其余时候浮在最上面；
5. 看鼠标 / 作息的读数，每 0.1 秒喂给 `Attention`（拿不到就给 nil，只关掉对应功能）：

   | 平台 | 键鼠闲置秒数 | 鼠标全局坐标 | 有程序不让屏幕熄灭（放视频） |
   |---|---|---|---|
   | macOS | `CGEventSource.secondsSinceLastEventType` | `NSEvent.mouseLocation` | `IOPMCopyAssertionsStatus` 的 PreventUserIdleDisplaySleep |
   | Windows | `GetLastInputInfo` | `GetCursorPos` | `CallNtPowerInformation(SystemExecutionState)` 的 `ES_DISPLAY_REQUIRED` |
   | Linux X11 | XScreenSaver `XScreenSaverQueryInfo` | `XQueryPointer` | D-Bus `org.gnome.SessionManager.IsInhibited(8)` / `org.freedesktop.PowerManagement.Inhibit.HasInhibit` |
   | Linux Wayland | `ext-idle-notify-v1`，或 D-Bus `org.freedesktop.ScreenSaver` / GNOME `IdleMonitor` | 读不到全局指针：只在指针落在自己的全屏透明层上时给 | 同 X11 |

平台路线（2026-09-30 定）：
- **macOS**：现在唯一在维护的版本。
- **Windows**：Rust + wry / tao 壳（不用整套 Tauri），渲染仍是 WebView2；还在开发，没合进 main。
- **Linux**：WebKitGTK。先做 **X11**，再兼容 **Wayland**（Wayland 摆不了窗口、读不到别的窗口：XWayland / layer-shell 分档，读不到就只沿屏幕底边走）。

## 界面语言

简体中文 / 繁體中文（香港用词）/ English，设置 → 通用 → 语言（默认跟随系统，存在 `config.json` 的 `language`）。
- 网页：`web/src/i18n/`，`zh-Hans.ts` 是基准表，另两张表的类型就是它（缺 key 时 tsc 报错）；界面代码里用 `t()`。
- 壳：`macos/Sources/Rhodeside/Strings.swift` 的 `tr("简", "繁", "English")`，调用处就地写三语；纯日志不翻。
- 干员名、时装名只在显示时换：中文名是文件夹名和配置 key，分组 `基建 / 正面 / 背面` 也是 key，都不能翻。
  译名随在线目录下发：英文由 `fetch-prts.mjs` 写进 `models-private/names.json`，繁体由 `publish.mjs` 发布时简转繁（`opencc-js`）。

## 声明

- 只支持 Spine 3.8 导出的文件（明日方舟用的就是 3.8）。Spine 运行时受 Spine Runtimes License 约束，这里仅作个人使用。
- 明日方舟的角色、模型、语音版权归鹰角网络（Hypergryph）所有；本仓库不包含这些资源，在线模型只发给登录用户。
