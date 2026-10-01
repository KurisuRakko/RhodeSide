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
bash macos/scripts/deploy.sh remote-logs [--crash] [关键词] [行数]   # 看各台 App 自动上传的日志（不带参数列出所有设备）
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
| 在线模型（只给登录用户） | 源文件放 `models-private/`（仓库根）（**不要放 web/public**），在 `macos/models.json` 加一条，`deploy.sh models` 发布到 `v1/models.json`（每个模型另有 `v1/previews/` 预览包：默认时装的基建模型） | 登录本身不下载任何模型：用户在模型库 / 设置里点了下载才装；已装的内容变了自动更新 |
| 六星模型（PRTS） | `macos/scripts/fetch-prts.mjs` 从 PRTS 拉全部六星（全部时装 × 基建 / 正面 / 背面）到 `models-private/<干员名>/`，并登记进 `models.json`；非六星用 `--only <名字>` 单独加（如五星谜图），之后每天和六星一起更新；基建语音（进驻 / 戳一下 / 信赖触摸，中文优先）由 `fetch-voice.mjs` 拉到 `voice/` 并用 ffmpeg 转成 MP3（服务器要装 ffmpeg），每个模型都有、也每天跟着更新；定时器 `rhodeside-prts.timer`（systemd 用户单元，每天 04:30 左右）跑 `sync-prts.sh`，有变化就重新发布，日志 `~/.local/state/rhodeside/prts-sync.log` | 新干员 / 新时装第二天出现在模型库里 |
| 本地模型 | 增删改 `~/Library/Application Support/Rhodeside/models/` | 设置页即时刷新，用到该模型的桌宠自动重新加载 |
| 配置 | 编辑 `config.json` | 保存后立即生效；格式错误时忽略 |

App 只接受构建号更大的包；`web-dev` 的构建号不比 App 自带前端新时自动失效。
签名私钥 `~/.config/rhodeside/release-ed25519.pem`，公钥内置在 `Sources/Rhodeside/RemoteUpdater.swift`。
设置 → 更新：关闭自动更新、手动检查、看 App / 前端当前与最新版本。自更新日志在 `~/Library/Application Support/Rhodeside/updates/install.log`。

### 日志自动上传

总是开，没有开关（`Sources/Rhodeside/LogUploader.swift`）：
- 每天一次，把 `rhodeside.log` 新增的部分（单次最多 4MB，超了只传最后的）传到 `POST https://rhodeside.rakko.cn/v1/logs`；
- 上次没正常退出（崩溃、被强制结束；正常退出和 SIGTERM 不算）：启动 3 秒后立刻传（两分钟后再补查一次系统崩溃报告），连同 `~/Library/Logs/DiagnosticReports/` 里没传过的系统崩溃报告（`Rhodeside*.ips`，以及 responsibleProc 是 Rhodeside 的 WebKit 网页 / GPU 进程报告）；
- 没有手动上传按钮（设置里只剩「显示日志」）。
登录了带票据，按 Priestess 账号归档；没登录也传（进 `_anon/`，body ≤ 2MB，最多 200 台）。失败不前移游标，每小时再试。
服务器：`auth` 容器（`auth/server.mjs`）存到 `/opt/stacks/rhodeside/logs/<账号|_anon>/<设备 UUID>/`
（`rhodeside.log` 超 20MB 轮转一份、`crash/*.ips` 留 20 份、`meta.json` 记电脑名 / 用户名 / 版本 / 最后上传时间）；nginx 每 IP 每分钟 6 次。
用 `deploy.sh remote-logs` 看。

### 日志里的诊断数据

（`Sources/Rhodeside/Diagnostics.swift`，纯逻辑在 `PetCore/Diagnostics.swift`）
- 启动一行带机型、芯片、核数、内存；退出一行带运行时长；收到 SIGTERM 等写信号名；系统关机 / 注销也记一行。
- **崩溃**：崩溃信号（段错误、强制解包 nil / 越界等 Swift 运行时错误、abort……）到来时写一行 `[FATAL]`（信号、出错地址、哪个线程、最近一次内存采样），然后照常崩溃；
  `exit()` 没走正常退出也记一行。下次启动：写「上次没有正常退出」+ 上次的版本、启动时间、最后心跳、死前内存（运行标记 `running` 每分钟更新）；
  上传前把系统崩溃报告摘要写进日志（异常类型、信号、终止原因、fatalError 的文字、崩溃线程前 12 帧）。
- **网页进程没了**：写原因（超出内存上限 / 超出 CPU 上限 / 崩溃，走 WebKit 私有回调）和最近一次采样的内存。
- **资源**：每分钟采样 App、GPU 进程、每只桌宠和每个窗口的网页进程的内存和 CPU；每 10 分钟一行 `资源：…` 汇总；
  超上限（App / 网页 400 MB、GPU 1500 MB、合计 3000 MB）、比启动后最低值涨了 300 MB、CPU 连续两分钟 > 80% 时写 WARN（同一件事半小时内不重复，除非又涨了一半）；
  系统内存压力变成警告 / 严重也写 WARN。
- 错误日志带错误域和错误码（如 `NSURLErrorDomain -1004`）。

### 鉴权（Priestess）

- App：必须登录（设置 → 账号，或新装时的引导页；默认浏览器，PKCE）。令牌存 `auth.json`（600）。refresh token 30 天有效、每次刷新轮转：App 开着时距上次续签超过 12 小时就主动刷新（启动 5 秒后、唤醒 1 分钟后、之后每小时各看一次），所以每天打开就永远不掉登录；超过 30 天没打开会退回未登录，重新登录即可。App 不再内置模型，跳过登录就没有桌宠。
- 服务器：`/opt/stacks/rhodeside` 的 `auth` 容器（`auth/server.mjs`）用 access token 换 10 分钟 HMAC 票据；nginx `auth_request` 校验。
  `compose.yaml` 里 `ENFORCE: "1"`（已启用）：清单和包必须带票据。临时关掉改成 `"0"` 再 `docker compose up -d auth`。
- 回跳页 `https://rhodeside.rakko.cn/auth/callback` 随前端发布。设计细节见 [plan.md](plan.md)。

## 用

- 菜单栏的爪印图标只有：打开 Rhodeside…（⌘,）、隐藏 / 显示桌宠、召回全部、退出。
- Rhodeside 窗口（一个窗口，左边侧栏三页；`rhodeside://pets|models|settings` 直接打开某页）：
  - 版式照系统设置：分组，每行左边名字、右边控件。同一个设置只出现在一处。
  - 桌宠：最上面「套组」（见下）；再下面一排选哪只 + 添加；「模型」一行（模型 · 时装 · 形态，点「更换…」）/「显示」大小、不透明度、悬停变淡、PMA /
    「活动」基建形态是方式（自由活动 / 一直行走 / 原地停留）+ 步速，战斗形态（正面 / 背面）不走动，换成循环动作下拉框 /
    「立即动作」基建是互动 / 坐下 / 睡眠 / 站立，战斗形态是连招（`web/src/stage/combos.ts` 按动画名认）；最下面召回、移除。
  - 选模型（桌宠页点「更换…」整页切过去，`web/src/settings/ModelPicker.tsx`）：左边已下载的在上、没下载的在线模型在下；
    右边预览，已下载的能切时装 / 形态看效果，没下载的只预览默认时装的基建模型，按钮是「下载并使用」。
  - 模型库：在线模型（左边搜索、勾选，右边预览只循环待机，下载所选）/ 我的模型（已下载和导入的，可删；拖文件夹进窗口即导入）。
  - 设置：账号、所有桌宠（在窗口上行走、窗口撞到时跳上去、其他应用全屏时隐藏、排除的应用）、通用（登录时打开、自动更新 + 更新状态）、故障排查（默认折叠：构建号 + 日志 / 文件夹 / 快照按钮）。
- 套组（桌宠页最上面）：把桌面上现在这几只（模型、时装、大小、活动方式都算）存成一组，比如一对 CP；召出时**替换**桌面上的全部桌宠。
  桌面正是某个套组召出来的时，那一行按钮变成「保存修改」（改了大小、加减了成员后写回去）。配置存在 `config.json` 的 `teams`，
  召出来的桌宠带 `link` = 套组 id，同一 `link` 的会联动（`macos/Sources/PetCore/Companions.swift`）：
  集合点是组里第一只、或最近被拎起来丢下的那只；集合点开始走，其余的错开一点跟上去排在它后面；平时其余的只在集合点附近（约 2.5 倍身高）溜达，走远了自己回来；
  丢下一只，其余的走过去找它（坐着的站起来，睡着的不叫醒，在窗口上的从窗口边跳下去）；点一只，其余的转过去看它并做互动动作（只有被点的那只说话）。
  「原地停留」的成员不跟着走。手动「添加」的桌宠不联动。删除套组后，桌面上从它召出来的桌宠留着、不再联动。
- 桌宠身上：左键点一下是互动（战斗形态播攻击）；按住拖动是拎起来，松手会带着甩出去的速度掉下去；右键不响应。
- 叠叠乐（头顶高度跟着姿势：下面那只坐下、睡下，上面那只跟着矮下去，网页按坐 / 睡动画量出比例随 `loaded` 的 `heights` 发来）：把一只拖到另一只头上松手，它就站在那只头顶（`macos/Sources/PetCore/Stacking.swift`，头顶是一种平台 `.pet(id:)`）。
  叠上去的不自己走（只待机 / 坐，套组也拉不走它）；叠着的一摞里谁都不躺下（作息让睡改成坐，下面睡着的被叠上来就坐起来），下面那只走路、被拎起、掉下去都带着它；能叠好几层。拖下来就拆开。
  站稳了的那只头顶得在屏幕里（离菜单栏至少 `Platforms.headroom`，和窗口顶边同一条线）：伸到屏幕上沿外面的头顶落不上去，叠好后被抬出去了上面那只就掉下来（被拎着、在空中时不管，整摞带着走）——不然站在高处窗口上的那只头上再叠一只，上面那只整个在屏幕外，看不见也拖不回来。
  只有用手扔的才会落到头上（从窗口边走下去、叫回来的不会）；叠着的关系存在 `positions.json` 的 `on`，重启后放回去。
- 站在窗口上的小人和这个窗口**同层**（排在它正上方，不再浮在所有窗口上面）：前面的窗口能盖住它；脚下那段顶边被盖住了就走到同一个窗口上最近的露出来的地方，
  整个顶边都被盖住就在下面待着。窗口**不在焦点**（不是最前面那个应用最靠前的窗口）时只在脚下露出来的那段里溜达：不跳窗边、走到头就停、套组也拉不走。
  在地上、在空中、被拎着时照旧浮在最上面。层级被打乱（点了脚下的窗口）由每次窗口扫描检查重排，切应用时马上扫一次。
- 在空中（弹跳、被扔、走出窗口边）时窗口一次拉高成盖住整段弹道的带子，飞行中不再每帧挪窗口（每次挪都要等 WindowServer，忙的时候会卡几百毫秒），
  网页按 `pos` 里的 `y / vy / h` 画上下位置；挪窗口超过 50ms 会在日志里记「挪窗口卡了」。
  小人窗口不让 AppKit 往屏幕里推（`PetPanel.constrainFrameRect` 原样返回）：头上特效高的模型（如 Mon3tr）站在靠上的窗口上时带子会伸进菜单栏，以前整条被往下推、小人陷下去。
- 位置消息（前端协议 5）：原生层只在网页外推得不准时才发 `pos`（起步、停下、转向、换带子、误差超过 1.5pt），另外每 250ms 校正一次；
  网页按 `web/src/pet/motion.ts`（和 `PetCore/Geometry.swift` 的 `Motion` 同一公式：地上匀速，空中重力 + 水平阻尼）外推，最多推 0.3 秒（空中 0.1 秒：原生层卡住时网页推太远会冲过头再弹回）。
  包围盒按相对脚底报，只在动画让它变了时才发。网页画面停顿超过 150ms 会报回来，日志记「网页画面停了」，和「主线程卡了」对照：两边同时停 = 系统 / WindowServer 停了。
- 窗口撞到时跳上去（默认开，设置 → 所有桌宠，`config.json` 的 `hopOnWindows`；要开着「在窗口上行走」）：拖动或缩放别的程序的窗口、从没压着变成压到小人身上时，
  小人弹一个抛物线跳到这个窗口顶边上（叠着的一摞一起跳，撞到上面那只也算）。新开的窗口、切桌面空间、小人自己走到窗口前面都不算；窗口顶边站不了（最大化、贴着菜单栏、被挡住）就不跳。
  有窗口在动时接下来 1 秒每 0.1 秒扫一次窗口（平时约 0.3 秒），免得快速拖过去时整个穿过小人。判定在 `PetCore/WindowHop.swift`，起跳是 `Brain.hop`。
- 看鼠标：鼠标靠近（身体中心 2.5 倍身高以内）时，站着、坐着的小人转过来看；走路、睡觉、做动作时不转，转一次后 1.2 秒内不再转。
- 跟着电脑作息：键鼠 1 分钟没动全部坐下，3 分钟没动、并且没在放视频就睡着（套组也拉不走）；放视频时最多坐着陪你看。
  「在放视频」= 有程序不让显示器自动熄灭（`pmset -g assertions` 里 PreventUserIdleDisplaySleep 为 1；浏览器、播放器放视频和视频会议时都会这样；
  `caffeinate -d`、Amphetamine 这类防休眠工具开着时也算，那就只坐不睡）。
  一动就醒，从睡着醒来时离鼠标最近的那只做个动作、说一句话；
  深夜 0–6 点自由活动时更容易睡着。「原地停留」里手动让它坐 / 睡的不受影响；战斗形态不坐不睡。
  两个都在 设置 → 所有桌宠 里开关（`config.json` 的 `watchMouse` / `restWhenIdle`）；时长、范围、深夜时段在 `rhodeside-tuning.json`
  （`restSit` / `restSleep` / `lookRadius` / `nightHours` / `nightSleepBoost`），随前端热更新。逻辑在 `macos/Sources/PetCore/Attention.swift`，
  平台读数只在 `macos/Sources/Rhodeside/UserActivity.swift`（闲置时长用 `CGEventSource`，不需要辅助功能权限）。
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
| `~/Library/Application Support/Rhodeside/log-upload.json` | 日志上传：设备 id、读到哪了、上次上传时间 |
| `~/Library/Application Support/Rhodeside/running` | 运行标记（JSON：版本、启动时间、每分钟的心跳和内存；正常退出时删掉；启动时还在 = 上次崩溃了） |

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
                        PetWindow 透明面板、SchemeHandler rhodeside-res://、WindowScanner、Tracking（后台扫描与窗口追踪）、RemoteUpdater（公网热更新）、LogUploader（日志自动上传）、SettingsController、
                        Importer、ModelLibrary、LoginItem、FileWatcher、Debug、Log
  Tests/PetCoreTests/
  Resources/Info.plist
  scripts/              deploy.sh（服务器）、build-app.sh（Mac）、publish.mjs（签名发布）、dev.mjs（源码监听）
/opt/stacks/rhodeside/  公网更新通道容器（nginx 只读静态服务，127.0.0.1:8067 → rhodeside.rakko.cn）
web/pet.html + web/src/pet/           桌宠渲染页（只有画布）
web/settings.html + web/src/settings/ 设置页（React + Rakko Design）
web/src/stage/                        Spine 载入 / 测量（loader、model）、模型库预览舞台（engine）、连招识别（combos）
web/src/native/transport.ts           页面 ↔ 原生的传输层（前端里唯一碰 WebView API 的地方，见根目录 README「分层」）
```
