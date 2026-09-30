# SpineStage → Rhodeside 桌宠

这个仓库现在只维护 **Rhodeside**：桌面上的明日方舟 Spine 3.8 小人（目前只有 macOS 版）。
原来的 SpineStage 网页版（拖模型进网页看、`?embed` 嵌入）已下线删除。

macOS 版的部署、用法、文件位置见 [macos/README.md](macos/README.md)，设计取舍见 [macos/plan.md](macos/plan.md)。

## 分层（保持跨平台）

| 层 | 位置 | 平台 |
|---|---|---|
| 前端：桌宠渲染页、设置 / 模型库 / 引导 / 登录回跳页、Spine 载入代码 | `web/` | 平台无关 |
| 原生传输层（页面 ↔ 壳） | `web/src/native/transport.ts` | 前端里**唯一**允许碰具体 WebView API 的文件 |
| 纯逻辑：坐标、平台遮挡、行为状态机与物理、配置 | `macos/Sources/PetCore/` | 不依赖 AppKit，有单元测试 |
| 壳：窗口、鼠标、窗口扫描、资源协议、更新、登录 | `macos/Sources/Rhodeside/` | macOS |

约定：
- `web/src` 里不许出现 `webkit.messageHandlers`、`chrome.webview` 这类具体 WebView 接口（要用就加进 `transport.ts`；`pnpm check` 会查），也不许假设 macOS。
- 页面用相对路径（vite `base: './'`），壳从自定义协议 `rhodeside-res://` 或热更新目录加载，不假设站点根。
- 以后接 Windows / Linux：写一个新壳，实现
  1. `transport.ts` 的协议：页面 `post(msg)` 发过来的 JSON 消息，和调 `window.rhodeside.receive(msg)` 发回去；
     transport 已认得 WebKitGTK（与 macOS 同接口）和 WebView2（`chrome.webview`）；
  2. `rhodeside-res://` 资源服务：前端静态文件，加上 `models/<名字>/…`（已装模型）、`previews/<id>/…`（模型库预览）、
     `import/<批次>/…`（导入检查）三个前缀；文件列表由原生消息（`load`、`preview` 等）带过去，壳不用提供 `index.json`；
  3. 行为状态机（照 `PetCore/Brain.swift` 移植）。

平台路线（2026-09-30 定）：
- **macOS**：现在唯一在维护的版本。
- **Windows**：WebView2（Chromium 内核），transport 走 `chrome.webview`。
- **Linux**：WebKitGTK，transport 和 macOS 同一个分支。先做 **X11**（窗口定位、读别的窗口位置、透明 + 点击穿透都能做），
  再兼容 **Wayland**：Wayland 下程序不能自己摆窗口位置，也读不到别的窗口，按合成器分档——
  用 XWayland 跑 X11 那套（只看得到 X11 程序的窗口）、wlroots / KDE 用 layer-shell 做全屏透明层；
  GNOME 读窗口位置要靠 Shell 扩展。读不到窗口时退化成只沿屏幕底边走。

## 开发

```bash
corepack pnpm install
corepack pnpm dev      # vite dev，0.0.0.0:8066
corepack pnpm check    # tsc + Rakko Design 合规检查 + combos 单测
```

`pnpm dev` 下用普通浏览器打开页面（没有原生壳）：
- `http://127.0.0.1:8066/settings.html`、`/welcome.html`：设置页 / 引导页，走 `settings/bridge.ts` 里的假原生层（页面上显示「浏览器预览」）
- `http://127.0.0.1:8066/pet.html?group=基建`：桌宠渲染页调试模式，发给原生的消息打到 console，自己从 `models/` 载入（需要 WebGL）

调试用的测试模型放在 `web/public/models/`（见那里的 README），`pnpm dev` 前会跑 `scripts/scan-models.mjs` 生成清单。

## 结构

- `web/pet.html` + `web/src/pet/`：桌宠渲染页（只有画布）
- `web/settings.html`、`web/welcome.html`、`web/auth-callback.html` + `web/src/{settings,library,welcome,auth}/`：界面页（Rakko Design，`@rakko/react` primitive）
- `web/src/stage/`：Spine 载入 / 测量（`loader.ts`、`model.ts`）、舞台（`engine.ts`，现在只给模型库预览用，roam 漫步逻辑留作移植参考）、套组动作识别（`combos.ts`）
- `web/src/ui/icons.tsx`：线性图标（currentColor）
- `web/public/lib/spine/spine-webgl.js`：Spine 3.8 官方 WebGL 运行时原样副本（`scripts/fetch-spine.sh` 可重拉）。
  Spine 运行时受 Spine Runtimes License 约束，这里仅作个人使用。
- `vendor/rakko-design/`：设计系统外来件，只能由 `scripts/sync-design.sh` 生成，不要手改。
- `macos/`：Rhodeside macOS 壳，见 [macos/README.md](macos/README.md)。
- `models-private/`：有授权的在线模型源文件，只放服务器，不进前端、不进 dev server。

只支持 Spine 3.8 导出的文件（明日方舟用的就是 3.8）。
