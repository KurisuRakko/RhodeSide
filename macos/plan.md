# Rhodeside：macOS 桌宠计划

目标：一个 macOS 菜单栏程序，桌面上有明日方舟 Spine 小人，能沿屏幕底部（程序坞上沿）和各个窗口的顶边走，
可以拖起来、丢下去、点一下互动。参考 [Ark-Pets](https://github.com/isHarryh/Ark-Pets) 的行为，技术栈不照搬。

## 现状（2026-09-30）

P0–P5 已全部实现并部署到 Rakko 的 Mac，用法见 [README.md](README.md)。与原计划的差异：

- **SpineStage 网页版已下线（2026-09-30）**：下文提到的 `pnpm build`、`index.html`、`web/dist/`、「SpineStage 页面」都是当时的计划，已不存在；构建流程以 `scripts/deploy.sh` 为准。

- **窗口形态**：桌宠窗口改为横跨所在屏幕的带状窗口（屏宽 × 小人高），站立和行走时窗口静止，由前端按 `pos` 绘制位置。原因见「性能」。
- **窗口扫描**：用 `.optionOnScreenOnly`，在后台线程执行；脚下窗口由独立线程 8ms 轮询。最小化与切换桌面空间不再区分，均视为平台消失；切换空间时冻结物理 0.5 秒。
- **全屏判断**：任一其他应用的窗口恰好铺满某块屏幕即判定为全屏，原生全屏与非原生全屏一并覆盖。
- **点击判定**：直接做成像素级。
- **位置存档**：单独存到 `positions.json`，避免频繁改写 `config.json`，也不会触发配置热更新。
- **登录时启动**：改用 LaunchAgent。实测 `SMAppService.mainApp` 的登记绑定代码签名，ad-hoc 签名每次编译都会变，重新部署后登记即失效。
- **热更新**：新增。前端走公网签名通道即时生效；Swift 壳也走同一通道自更新（下载、验签、替换、重启，失败自动回滚），见下文。
- **右键**：小人身上不再响应右键；动作、模式都在窗口的桌宠页里（2026-09-30 Rakko 要求）。
- **主窗口**（原控制面板 + 设置，2026-09-30 合并）：一个窗口 + 侧栏（桌宠 / 模型库 / 设置），系统设置式分组；换模型 / 时装 / 形态走桌宠页里的整页选模型界面（带预览）。页面是前端，随热更新。
- **套组**（2026-09-30）：存一组桌宠一键召出（替换全部），同组联动（结伴走、丢开了互相找、点一只其余的反应）；联动逻辑在 `PetCore/Companions.swift`，Brain 只加了 `go / face / react / leash / events` 几个接口。用法见 README。
- **叠叠乐**（2026-09-30）：拖到别人头上就叠上去，上面的不走、被下面的带着走；头顶是 `PlatformKind.pet`（`PetCore/Stacking.swift`），复用站窗口的跟随逻辑。
- **行为参数**：状态时长、各动作概率、跳窗概率、悬停透明度放在前端的 `rhodeside-tuning.json`，随前端热更新；状态机本身仍在 Swift。

资源占用（1 只桌宠，footprint）：App 25 MB；每只桌宠的 WebContent 进程 35–65 MB；整个 App 共用的 WebKit GPU 进程约 340 MB（其中 300 MB 为显存映射，稳定不增长）。上限 8 只。

## 性能

### 已完成（2026-09-30）

| 问题 | 原因 | 处理 | 效果 |
|---|---|---|---|
| 行走时周期性卡顿 300–500ms | 每帧 `setFrameOrigin` 都要向 WindowServer 申请同步 fence，多屏环境下偶发阻塞主线程；主线程阻塞时 WebKit 的 rAF 也随之停摆 | 带状窗口，行走时窗口不动；原生层只发位置 + 速度，前端外推 | 原生帧：40 秒 0 次超时 |
| 主线程周期性阻塞 | `CGWindowListCopyWindowInfo` 在主线程上执行（p90 20ms，最坏 46ms），单窗口查询最坏 34ms | 全量扫描移到后台线程；脚下窗口改由后台线程轮询；扫描频率自适应（平时 ~3Hz，下落或拖拽时 10Hz） | 主线程不再调用 CGWindowList |
| 透明窗口被系统判定为遮挡，页面停止渲染 | WebKit 按窗口遮挡状态节流 rAF，而全透明窗口始终被判为遮挡 | 关闭 WebKit 的窗口遮挡检测（`_setWindowOcclusionDetectionEnabled:`，私有接口，不存在则跳过） | — |
| 每帧额外开销 | `preserveDrawingBuffer` 整帧拷贝、MSAA、每帧读 layout | 关闭 `preserveDrawingBuffer` 与 MSAA；像素判定和快照在渲染完成的同一帧读取；尺寸变化才重设画布；`bounds` 仅在变化时发送 | — |
| 系统节流 | App Nap | `beginActivity(.userInitiatedAllowingIdleSystemSleep)` | — |
| 睡眠状态限帧过低 | 20fps 肉眼可见 | 提到 30fps | — |

| 站立 / 坐下 / 睡眠时仍按 60fps 提交 | 待机动画不需要 60fps | 方案 B：只有行走、下落、拖拽、互动时 60fps，其余 30fps（2026-09-30 Rakko 选定） | 提交次数约减半 |

### 遗留问题：每 30 秒一次的系统级停顿

每分钟约 :03/:05、:33/:35 各一次 280–400ms 的主线程停顿，**按墙上时钟对齐**，App 重启后相位不变，与桌宠在做什么无关。

- 采样：主线程卡在 WebKit 提交图层时的 `IOSurfaceClientLookupFromMachPort`（内核调用）；同一时刻后台扫描线程的 `CGWindowListCopyWindowInfo` 也耗时 215ms。说明是 WindowServer 本身在这时卡住，和它共享的 IOSurface 查询一起被阻塞。
- 对照：一个只查本进程私有 IOSurface 的探针程序同期完全不卡；`sharingType = .none` 无效。
- 排除：暂停 BetterDisplay（它在同一时刻做 DDC 读写）65 秒、退出 Bartender（每 30 秒截屏一次菜单栏）后，停顿照旧。
- 结论：来自系统或别的常驻程序，不是 Rhodeside 的代码；不影响功能，只是小人每 30 秒顿一下。
- 以后可试：逐个暂停其余菜单栏程序定位来源；或方案 A（原生 Metal 渲染，渲染不经主线程，不会被这类停顿拖住，但渲染层失去热更新）。

## 公网热更新（已部署，2026-09-30）

不依赖 Tailscale。服务器发布，App 拉取。

```
服务器 deploy.sh web
  └ vite build → .rhodeside-build（毫秒构建号）
  └ publish.mjs：打包 web-<build>.tar.gz → Ed25519 签名清单 → 写 /opt/stacks/rhodeside/data/v1/
容器 rhodeside-updates（nginx:1.29-alpine，只读挂载，127.0.0.1:8067）
  └ cloudflared 隧道 → https://rhodeside.rakko.cn
App RemoteUpdater（每 5 秒）
  └ GET /v1/manifest.json（If-None-Match，未变化返回 304）
  └ 验签 → 协议版本一致 → 构建号更大 → 下载包 → 校验大小与 sha256
  └ 解压到 web-dev.incoming → 原子替换 web-dev → 重新加载所有页面
```

- **清单格式**：`{key, payload, sig}`。`payload` 为 JSON 的 base64，内容为 `schema / build / bridge / bundle{path, sha256, size}`；`sig` 为私钥对 `payload` 原始字节的签名。公钥内置在 `RemoteUpdater.swift`。
- **防降级**：只接受构建号更大的包。`web-dev` 的构建号不比 App 自带前端新时自动失效，全量部署后旧包不会覆盖新前端。
- **协议兼容**：`bridge` 为原生 ↔ 网页消息协议版本。不一致时拒绝安装并提示先全量更新 App。
- **密钥**：私钥在服务器 `~/.config/rhodeside/release-ed25519.pem`（600，不进仓库）。轮换时生成新密钥、更新公钥并全量部署一次，`key` 字段用于区分。
- **缓存**：清单 `Cache-Control: no-store`（CF 状态为 DYNAMIC）；包按构建号命名，`immutable`；服务器保留最近 10 个包。
- **Swift 代码**仍需在 Mac 上编译，全量部署依赖 `ssh mac`。不在 Tailscale 时只能热更新前端。

## App 自更新（已部署，2026-09-30）

```
服务器 deploy.sh（全量）
  └ 同步源码 → Mac 上 build-app.sh --package：编译、组装、ad-hoc 签名、打 tar.gz（Info.plist 写 RhodesideBuild = 毫秒构建号）
  └ 取回 → publish.mjs --app：v1/apps/Rhodeside-<build>.tar.gz + 签名清单 v1/app.json（payload.kind = "app"）
  └ 再发布前端（v1/manifest.json，kind = "web"）
App（每 5 秒，先 App 后前端）
  └ 验签 → build 更大且不在黑名单 → 没有桌宠正被拖着 → 下载 → sha256 → 解压前列目录（拒绝绝对路径、..、链接）
  └ 核对 bundle id、构建号、codesign --verify --strict → 写交接脚本 → launchctl submit（独立任务，不随 App 退出）→ App 正常退出
交接脚本
  └ 等旧进程退出 → 旧 .app 改名 .previous → 新的放进来 → 启动
  └ 新版本启动 8 秒后写 updates/healthy-<build> → 删除 .previous，result.json = ok
  └ 进程退出或 40 秒没报告 → 杀掉、换回旧版、启动，result.json = rolledBack → 旧版把该 build 记入 failed-builds.json，不再安装
```

- 实测（2026-09-30）：正常更新停顿约 1 秒；故意发一个启动即退出的包，回滚后旧版恢复运行并拉黑该版本。
- `deploy.sh install` 保留直接安装（首次安装或自更新本身坏掉时）。
- 编译仍需要 Mac（`ssh mac`）；装上新版本不需要。

## Priestess 签票（已启用，2026-09-30）

目标：公网通道只对已登录且被授权的用户开放。完整性仍由 Ed25519 签名保证，鉴权只负责控制谁能拉取。

- **App**（`Auth.swift`）：默认浏览器打开 `/auth/priestess/oidc/login`（`state` + `code_challenge` S256）→ 回跳页 `https://rhodeside.rakko.cn/auth/callback`
  把 `#login_code`、`state`、`auth_error` 转给 `rhodeside://auth/callback` → 校验 `state` → `/exchange {login_code, code_verifier}`。
  刷新单飞（所有调用等同一个 Task）；提前 60 秒刷新；`invalid_refresh_token` 退回未登录；`app_access_denied` 显示「无权限」且不循环跳登录；`app_disabled` / `app_not_found` 提示应用未注册。
  令牌存 `auth.json`（600）而不是钥匙串：ad-hoc 签名每次更新都会变，钥匙串会反复弹授权框。
- **服务器**：`rhodeside-auth` 容器（Node，`/opt/stacks/rhodeside/auth/server.mjs`）。`POST /v1/ticket`（Bearer）→ Priestess `/me` 核对（按令牌哈希缓存 60 秒，`app_id` 必须是 `rhodeside`）→ 10 分钟 HMAC 票据。
  nginx 对清单和包 `auth_request /_check`（本地验票，不打 Priestess）；`/v1/ticket` 限流 30 次 / 分钟。包的缓存头改为 `private`，鉴权开启后 CDN 不会替没票据的人缓存。
- **开关**：`compose.yaml` 的 `ENFORCE`，2026-09-30 起为 `"1"`。验收：无票据 / 假票据 → 401；登录的 App 能拉前端更新；回跳页与 `/healthz` 公开。

### 启用步骤（已完成：Phainon 已注册 rhodeside，Require PKCE 开）

1. Phainon 管理台新建应用：`app_id = rhodeside`，`name = Rhodeside`，`allowed_origins = https://rhodeside.rakko.cn`，`allowed_return_urls = https://rhodeside.rakko.cn/auth/callback`，打开 Require PKCE。
2. Access 标签把 rhodeside 切到「默认关闭」，放行自己（管理员本来就恒通）。
3. Mac 上：设置 → 账号 → 打开「使用 Priestess 登录更新通道」→ 登录。
4. 告诉 Claude，把 `ENFORCE` 改成 `"1"` 并验收：未登录 401、登录后能更新、解除授权后换票失败。

## 已定的事（2026-09-29 与 Rakko 确认）

| 项 | 决定 |
|---|---|
| 技术栈 | Swift + AppKit 外壳，每只桌宠一个透明小窗口，里面用 WKWebView 跑 SpineStage 的 Spine 3.8 渲染代码 |
| 测试 | Claude 通过 `ssh mac` 同步代码、编译、装到 `~/Applications` 并启动；画面效果由 Rakko 看，Claude 靠日志和桌宠画布快照检查 |
| 模型 | App 内置荒芜拉普兰德，打开就能用；设置窗口可以导入别的模型，存到 `~/Library/Application Support/Rhodeside/models/` |
| 第一版范围 | 核心功能（底部 + 窗口顶行走、拖拽、点击互动）+ 菜单栏（打开设置、退出）+ 设置窗口 + 多只桌宠 + 多显示器 + 开机自启 |
| 站着的窗口被拖动 | 小人跟着窗口一起移动；窗口关闭、最小化或脚下被别的窗口挡住时才掉下来 |

### Claude 自己定的默认值（Rakko 想改就说）

- App 名 **Rhodeside**，bundle id `com.rakko.rhodeside`，最低支持 macOS 14（Rakko 的 Mac 是 15.7 / Apple Silicon，装了完整 Xcode 和 Swift 6.2）。
- 不在程序坞显示图标（`LSUIElement`），只有菜单栏图标。
- 默认基于「基建」模型组（它有 Move / Sit / Sleep / Interact 动画）；没有基建组的模型就用正面组，只原地待机。
- 别的程序全屏时默认隐藏桌宠（设置里可以关掉）。
- 代码由 Claude 写（DSH 目前暂停，只接回归脚本这类杂活）；每个阶段交付前起一个独立 subagent 做反方审查。
- 用 ad-hoc 签名，不做公证，只在 Rakko 自己的 Mac 上用；程序里内置的素材不外传。

## 架构

```
菜单栏 NSStatusItem ── 设置窗口（WKWebView：settings.html，React + @rakko/react）
        │
   PetManager（原生）── config.json（~/Library/Application Support/Rhodeside/）
        │
        ├── WindowScanner：每秒全量扫描 10 次 CGWindowListCopyWindowInfo；每只小人脚下那个窗口按刷新率单独查
        ├── Platforms：算出每块屏幕的「地面」和每个窗口顶边没被挡住的线段
        └── Pet × N：行为状态机 + 物理（原生 Swift，displayLink 驱动）
              └── PetWindow：透明无边框 NSPanel，大小刚好装下小人
                    └── WKWebView：pet.html 只负责画 Spine、按命令播放动画
```

**分工原则：原生层管「位置和行为」，网页只管「画」。**
- 小人在屏幕上的位置 = 它那个小窗口的位置。原生层每帧移动窗口（`setFrameOrigin`），网页里的小人始终画在画布里的固定位置。
  这样 WebGL 只画一小块区域，比铺满全屏的透明窗口省电。
- 行为状态机（待机 / 走 / 坐 / 睡 / 互动 / 被拎起 / 下落）从 `web/src/stage/engine.ts` 的漫步逻辑移植到 Swift，
  因为它要直接用到窗口和平台数据，放在原生层就不用来回传消息。
- 帧时钟用 macOS 14 的 `NSView.displayLink(target:selector:)`：它跟随窗口所在屏幕的刷新率（ProMotion 屏上是 120Hz）。不用 `Timer`。

### 桌宠窗口的设置（P0 必须一次做对）

- `NSPanel`，`styleMask = [.borderless, .nonactivatingPanel]`（在 init 里就给），**`hidesOnDeactivate = false`**。
  NSPanel 默认是 true，不改的话 App 一失去焦点，所有小人都会消失。
- `isOpaque = false`、`backgroundColor = .clear`、**`hasShadow = false`**（系统阴影会按内容给小人描一圈边，动画变了还会残留）。
- WKWebView：`setValue(false, forKey: "drawsBackground")`，页面的 html / body 背景也设成透明。
- 窗口层级 `.floating`；`collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`。
  不加 `.fullScreenAuxiliary`，这样别的程序原生全屏时小人不会跟进它的全屏 Space（这就是「全屏时隐藏」的主要实现；设置里关掉隐藏时再动态加上）。
- 窗口尺寸：宽度取 **2 × max(|minX|, |maxX|)**（所有动画包围盒的并集，以脚底锚点为中心）。`engine.ts` 测包围盒时只算了朝右，
  翻转以根骨骼为轴做镜像，武器在一侧的模型翻过来会超出窗口，所以宽度要按两侧里更宽的那边取。

### 鼠标：只有小人身上能点

透明 NSView 的 `hitTest` 返回 nil 并不能让点击穿到别的程序，只有窗口级的 `ignoresMouseEvents` 能做到。
但窗口穿透以后自己就收不到任何事件，所以要主动轮询鼠标位置：

- 每帧读 `NSEvent.mouseLocation`（不需要权限）。鼠标在「当前帧包围盒外扩几 pt」的范围内时，才把 `ignoresMouseEvents` 设成 false，否则设成 true。
- 按下到松手这段时间强制不穿透。
- WKWebView 上面盖一层透明 NSView 接收所有鼠标事件，`acceptsFirstMouse` 返回 true（不需要先激活窗口，第一次点就生效）。
- 拖动时，新位置 = 屏幕上的鼠标坐标 − 按下时的抓取偏移。不要用 `locationInWindow`，因为窗口本身在动，用它会越拖越抖。
- 松手时的速度用最近几帧的鼠标位移估算，作为「扔出去」的初速度。

### 网页 ↔ 原生消息

| 方向 | 消息 | 内容 |
|---|---|---|
| 原生 → 网页 | `load` | 模型文件列表（`rhodeside-res://` 地址）、时装、模型组、是否已预乘 alpha |
| 原生 → 网页 | `play` / `face` / `scale` / `speed` | 动画名 + 是否循环 / 朝向 / 缩放 / 播放速度 |
| 网页 → 原生 | `loaded` | 识别出的动画角色（idle/move/sit/…）、各动画时长、静止包围盒、所有动画的包围盒并集、脚底锚点，**全部换算成 pt** |
| 网页 → 原生 | `faced` | 翻转已经画出来了（原生层收到后再开始反向移动窗口，避免倒着滑一两帧） |
| 网页 → 原生 | `bounds` | 当前帧小人的包围盒（窗口坐标，pt，约 10 次/秒） |
| 网页 → 原生 | `animDone` / `log` / `error` | 一次性动画播完 / 日志 / 报错 |
| 网页 → 原生 | `snapshot` | 画布 `toBlob` 的 PNG（调试用） |

- 步速：沿用 `engine.ts` 的经验公式（静止高度 × 缩放 × 0.42 × 步速倍率，单位 pt/s），由原生层按 `loaded` 里给的 pt 值计算。
  这个公式本来就不是从动画里量出来的，网页卡顿时也会有轻微滑步。所以不承诺「绝对不打滑」，只保证和 SpineStage 网页版看起来一样，设置里保留步速调节。
- 资源走自定义协议 `rhodeside-res://`（`WKURLSchemeHandler`）。**`pet.html` 和它的 JS 也从这个协议加载**，这样整页同源，
  不会碰到 WebKit 在自定义协议上的跨源问题。返回 `HTTPURLResponse`（200 + 正确的 Content-Type，因为 `loader.ts` 会检查 `res.ok`）；
  实现 `webView(_:stop:)`，停止后不能再回调，否则会崩溃。Vite 的 `base` 保持 `'./'`。

### 平台（能站的地方）

- 坐标统一用 AppKit 全局坐标（主屏左下角是原点）。「主屏」指 `NSScreen.screens[0]`（不是 `NSScreen.main`，那是焦点窗口所在的屏幕），
  其高度记为 H。CoreGraphics 窗口矩形换算：`y = H − cgY − h`，顶边就是 `H − cgY`。
- **地面**：每块屏幕一条，高度是 `visibleFrame.minY`，横跨 `visibleFrame` 的宽度。**每次扫描都重读**
  （程序坞自动隐藏或显示时没有可靠的通知）。
- **窗口顶**：只取第 0 层的普通窗口，排除自己的窗口和太小的窗口（< 100×40）。
  按从前到后的顺序，对每个窗口的顶边，只减去**竖直方向真正盖住这条顶边**的前方窗口的横向区间，剩下的就是能站的线段。
  顶边在菜单栏里或屏幕外的部分不要。
- 透明的「空气窗口」（截图工具、悬浮条这类）：`kCGWindowAlpha` 是整个窗口的透明度，这类窗口通常是 1，按透明度过滤不掉。
  所以主要靠**按程序名忽略的名单**（内置常见的，设置里可以加），透明度 < 0.1 的过滤只作为补充。
- 扫描用 `.optionAll` 配合 `kCGWindowIsOnscreen`，这样能分清「窗口关了」「最小化了」和「在别的桌面空间里」三种情况。
  收到 `activeSpaceDidChangeNotification` 后先暂停物理约 0.5 秒，避免切桌面空间时小人误判掉落。
- 小人站在窗口上时记住「窗口 ID + 相对横坐标」。脚下那个窗口按刷新率单独查（`CGWindowListCreateDescriptionFromArray`），
  这样跟随窗口移动不会只有每秒 10 次那么卡：
  - 窗口还在但位置变了 → 跟着平移；
  - 窗口关闭、最小化，或脚下那一点被别的窗口挡住 → 进入下落；
  - 窗口只是去了别的桌面空间 → 不算消失，按小人当前所在屏幕的地面处理。
- 下落时找脚下最近的平台落地；拖着松手也一样。
- 走到线段尽头：大概率转身，小概率跳下去；相邻屏幕的地面高度差不多时可以直接走过去，高度差太大就掉下去或转身。
- 非原生全屏（IINA / VLC 的非原生模式、游戏、Keynote 放映）没有通知，靠 WindowScanner 判断：
  别的进程有窗口的范围等于某块屏幕的整块范围，就只隐藏那块屏幕上的小人。
- 读窗口的位置、层级、透明度、所属进程和程序名**不需要**屏幕录制或辅助功能权限（只有窗口标题需要，我们不读）。

## 目录

```
RhodeSide/
  macos/
    plan.md                  ← 本文件
    Package.swift            ← SwiftPM，命令行 `swift build` 就能编，不需要 .xcodeproj；不用 `resources:` / Bundle.module
    Sources/PetCore/         ← 纯逻辑，不依赖 AppKit：几何、平台遮挡计算、行为状态机、配置
    Sources/Rhodeside/       ← App：main.swift（手动设 delegate，不用 @main）、菜单栏、PetManager、PetWindow、
                               WindowScanner、WebBridge、SchemeHandler、设置桥接、日志
    Tests/PetCoreTests/      ← 平台遮挡、落地、跟随窗口、状态机的单元测试（在 Mac 上跑 `swift test`，已装完整 Xcode）
    Resources/Info.plist
    scripts/deploy.sh        ← 在 rakkoserver 上跑：编网页 → rsync 到 Mac → 编译 → 打包 .app → 签名 → 安装 → 启动
  web/pet.html + web/src/pet/          ← 桌宠渲染页（不用 React，只有画布）
  web/settings.html + web/src/settings/ ← 设置页（React + @rakko/react，按 Rakko Design 规范）
  web/src/stage/                        ← 把加载、贴图处理、动画角色识别、包围盒测量拆成共用函数，SpineStage 页面和桌宠共用
```

### 构建与部署（deploy.sh）

1. rakkoserver：`corepack pnpm build`（Vite 多页面：`index.html` / `pet.html` / `settings.html`）。
2. `rsync` 把 `macos/`、`web/dist/` 和内置模型同步到 Mac 的 `~/Build/Rhodeside/`（只放源码和编译产物，**不在这里组装 .app**，
   否则两份同 bundle id 的 App 都会声明 `rhodeside://`，链接可能打到构建目录那份）。不直接在 FUSE 挂载目录里编译，那样太慢而且不稳定。
3. `ssh mac`：`swift build -c release` → 在临时目录组装 `Rhodeside.app`：
   - `Info.plist` 至少包含 `CFBundleExecutable`、`CFBundleIdentifier`、`CFBundlePackageType=APPL`、`LSMinimumSystemVersion`、`LSUIElement`、`CFBundleURLTypes`；
   - `web/dist` 和内置模型直接放进 `Contents/Resources`，代码里用 `Bundle.main` 读；
   - `codesign -s - --force`。
4. 退出旧进程 → `rm -rf ~/Applications/Rhodeside.app` → 把新的 `mv` 过去（不原地覆盖已签名的二进制，
   否则可能被系统按旧签名缓存直接杀掉）→ `open` 启动；不行的话退路是 `launchctl asuser $(id -u) open …`。App 自己做单实例检查。
5. 日志写到 `~/Library/Logs/Rhodeside/`（网页的 console 也转发过来），我通过 ssh 读。
6. 调试命令：`open 'rhodeside://debug/snapshot'`，每只桌宠把画布 `toBlob` 的 PNG、平台列表、状态写进日志目录。
   我能借此检查渲染内容和位置，但**桌面合成的效果（黑边、阴影、透明）测不出来，只能你看**。

## 分阶段

每个阶段结束我都会在你的 Mac 上装好，告诉你看什么；你看完说 OK 再进下一阶段。

### P0 骨架：桌面上出现一只小人
- SwiftPM 工程、deploy.sh、菜单栏图标（设置…（先占位）/ 退出）、日志、调试快照、单实例检查。
- 拆分 `engine.ts` 的共用函数，新写 `pet.html`；SpineStage 原来的页面不能坏（重跑 `tasks/001-verify.py` 回归）。
- 一个透明窗口，按上面「桌宠窗口的设置」一次配好，荒芜拉普兰德基建组，在程序坞上方居中待机。窗口**整体穿透**（这一阶段还不能点）。
- 探路（为后面的阶段排雷）：
  - 量一只桌宠占多少内存（App 进程 + 它的网页进程）；
  - 试一下 `SMAppService.mainApp` 对 ad-hoc 签名的 App 能不能注册（查 `status`，再用 `sfltool dumpbtm` 看登录项）。
- **验收**：
  - 小人背景完全透明，没有黑边和阴影；
  - 小人所在区域能点到下面的窗口；
  - 点别的程序、切桌面空间后小人都还在；
  - 快照 PNG 正常；
  - 内存和开机自启的探路结果写进本文件。

### P1 地面行走 + 交互
- `PetCore` 行为状态机（从 engine.ts 移植，步速公式保持一致）；朝向翻转等 `faced` 回执。
- 鼠标穿透按上面的「鼠标」一节做；按住拖动 → 被拎起；松手 → 按初速度加重力落下；单击 → 互动动画。
- 位置和状态每隔几秒、以及退出时写进 `config.json`，下次启动恢复。
- **验收**：
  - 沿程序坞上沿来回走、坐、睡，走路看起来和 SpineStage 网页版一样；
  - 只有小人身上能点，旁边空白处穿透；
  - 拖起来扔到半空会掉回去；点一下有互动动画；
  - 程序坞自动隐藏或显示后，地面位置跟着变；
  - 退出再打开，小人还在原来的位置。

### P2 窗口顶
- WindowScanner、平台计算、脚下窗口的高频跟随，以及单元测试（窗口层层叠放、部分遮挡、前方窗口在下面但不挡顶边、窗口跨两块屏幕、切桌面空间等情况）。
- 实现这些行为：
  - 站在窗口上，窗口动就跟着走；
  - 窗口关闭、最小化或脚下被挡住就掉下去；
  - 走到边缘跳下去；
  - 拖着小人放到窗口上方松手，会落在那个窗口上；
  - 忽略名单（内置几个常见的悬浮工具）。
- **验收**：
  - 在几个窗口之间把小人丢来丢去，行为符合上面的规则；
  - 拖动脚下的窗口时小人跟得上、不一顿一顿；
  - 切桌面空间不会让小人莫名掉下来。

### P3 多只 + 多显示器 + 全屏
- PetManager 管多只桌宠；屏幕变化（插拔显示器、改分辨率）时重新计算平台，走丢或出屏的小人放回屏幕内。
- 多块屏幕之间的地面衔接；全屏隐藏：原生全屏靠不加 `.fullScreenAuxiliary`，非原生全屏靠 WindowScanner 判断。
- 用 P0 量到的内存数据决定桌宠数量上限。如果每个网页进程太贵，退路是改成每块屏幕一个铺满的透明窗口画所有小人（没有公开接口能让多个 WKWebView 共用一个网页进程）。
- **验收**：
  - 放 3 只在两块屏幕上各自走；
  - 拔掉外接屏后，外接屏上的小人回到主屏；
  - 用 Safari 原生全屏看视频时桌宠不出现，IINA 非原生全屏时那块屏幕上的桌宠也不出现。

### P4 设置窗口 + 模型导入 + 开机自启
- `settings.html`（Rakko Design）通过桥接读写 `config.json`，改动立即生效。打开设置窗口时调用 `NSApp.activate()`，否则输入框收不到键盘输入。
- 可设置的内容：
  - 每只桌宠：模型、时装、大小、步速，以及删除；
  - 全局：添加桌宠、开机自启、全屏时隐藏、要不要在窗口顶上走、程序忽略名单。
- 开机自启：用 `SMAppService.mainApp`。如果 P0 探路发现 ad-hoc 签名注册不了，就改用 `~/Library/LaunchAgents` 里的 plist。
- 导入：由原生层弹系统选文件夹窗口，或者接收拖到设置窗口上的文件夹。不经网页的 `<input type=file>`，因为网页拿不到路径，大文件传过去也贵。
  1. 原生层把文件夹复制到临时目录；
  2. 网页用 `loader.ts` 经 `rhodeside-res://` 检查：必须是 Spine 3.8，`.skel`/`.json` 要能配上 `.atlas`；
  3. 检查通过再移进 `models/`，失败时给出明确原因。
- **验收**：导入一个新角色，放出来能走；重启电脑后桌宠自动出现，位置和配置都还在。

### P5 打磨
- 省电：桌宠被隐藏或看不见时暂停渲染（`occlusionState`）；睡觉时降低帧率。
- 网页进程崩溃时自动重载（`webViewWebContentProcessDidTerminate`）。
- 点击判定改成像素级（按画布透明度判断，不再用包围盒）。
- 写 README（怎么部署、怎么导入模型、调试命令）。

### P6 在线模型库（2026-09-30，细节见 tasks/007-model-library.plan.md）
- 模型只放服务器：`models-private/` → `publish.mjs --models` → 签名目录 `v1/models.json`（每项 `{id, name, version, path, sha256, size,
  default, skins, preview}`）+ 模型包 `v1/models/` + 预览包 `v1/previews/`（默认时装的基建模型），全部要票据。
- App：`ModelStore.wanted` 只装「用户点过下载的」和「已装的新版本」；登录、桌宠配置都不触发下载，`default` 只是模型库里默认勾上。
  预览下到 `~/Library/Caches/Rhodeside/previews/<id>/`，经 `rhodeside-res://app/previews/` 给网页。
- 引导：① 登录（可跳过）→ ② 模型库勾选（右边预览只循环待机）→ 完成时开始下载，并把还没有模型的桌宠换成勾选的第一个。
- 六星来源：`fetch-prts.mjs`（PRTS 干员一览 → wikitext 的 `干员id` → torappu `meta.json` → 全部时装 × 三种形态），`rhodeside-prts.timer` 每天同步。
- 战斗形态（正面 / 背面）：不走动；待机循环 `PetConfig.pose`；连招由网页 `combos.ts` 按动画名认（跨平台共用），
  随 `loaded` 发给原生层，`Brain.play(steps)` 按顺序播（一次性的等 animDone / 时长兜底，循环段按秒数），点一下播攻击连招。
- 协议版本 bridge = 2（新消息：downloadModels、previewModel/preview、playCombo、finishOnboarding.ids、openPage library）。

## 风险 / 待验证

| 风险 | 怎么处理 |
|---|---|
| WKWebView 透明背景用的是半私有的 `drawsBackground` KVC | Tauri/wry 在 macOS 上也这么用；P0 第一件事就验证 |
| 每只桌宠一个网页进程，内存偏大 | P0 就量；P3 决定上限，或改成每块屏幕一个铺满的窗口 |
| 透明的「空气窗口」按透明度过滤不掉 | 主要靠程序名忽略名单 |
| 桌宠窗口始终浮在普通窗口上方，站在后面窗口顶上时身体可能压在前面的窗口上 | Ark-Pets 也是这样；脚下被挡住时掉下来，已经能避开大部分情况 |
| 别的程序的窗口移动没有免权限的通知 | 脚下窗口按刷新率单独查；辅助功能权限（AXObserver）不用 |
| 步速是经验公式，动画和位移不在同一个时钟上 | 验收标准是「和网页版一样」，保留步速调节 |
| ad-hoc 签名下 `SMAppService` 可能注册失败，或停在「需要批准」 | P0 探路；不行就用 LaunchAgents plist |
| 从 SSH 用 `open` 启动图形界面程序 | 你登录着图形界面时一般可以；退路是 `launchctl asuser` |
| 拆 `engine.ts` 可能把 SpineStage 页面弄坏 | 只抽函数、不改行为；每次改完跑 001 回归 |
| 版权：Spine 运行时许可证、鹰角素材 | 模型只经需要登录的更新通道分发，不公开；不放 web/public |
