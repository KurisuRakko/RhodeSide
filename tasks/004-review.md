# 任务 004：Rhodeside 对抗式代码审查（只找错，不改文件）

你在 /home/rakko/Collection/SpineStage（不是 git 仓库，别 git init、别 commit）。先读 ~/ai/memory/MEMORY.md、~/ai/memory/rhodeside-project.md。
**只读**：不许修改、创建（除了下面的报告文件）、删除任何文件；不许 ssh、不许联网、不许重启任何服务。

## 审查对象

macOS 桌宠 Rhodeside：
- `macos/Sources/PetCore/`（纯逻辑：Brain.swift 行为状态机 + 物理，Platforms.swift 窗口顶边遮挡，Geometry.swift，Config.swift）
- `macos/Sources/Rhodeside/`（AppKit：PetManager、Pet、PetWindow、Tracking（后台窗口扫描 + 脚下窗口追踪）、RemoteUpdater（公网热更新：拉清单、Ed25519 验签、sha256、解压替换）、SchemeHandler、SettingsController、Importer、ModelLibrary、LoginItem、FileWatcher、WebBridge、Paths、Debug、Log）
- `macos/scripts/`（deploy.sh 在 Linux 服务器上跑；build-app.sh 经 ssh 在 Mac 上跑，Mac 的登录 shell 是 zsh；publish.mjs 签名发布；dev.mjs 监听源码）
- `/opt/stacks/rhodeside/`（nginx 只读静态服务：compose.yaml、nginx.conf）
- `web/src/pet/main.ts`（渲染页）、`web/src/settings/`（设置页 React）、`web/src/stage/{model,loader}.ts`（与 SpineStage 主页共用）
设计文档 `macos/plan.md`，用法 `macos/README.md`。代码能编译、33 个单元测试通过、在用户 Mac 上能跑（3 块屏：主屏 1920×1080 在原点、程序坞在左；笔记本屏在主屏下方 y 为负；右边一块竖屏）。

关键设计（审查时重点核对实现是否正确）：
1. 桌宠窗口是横跨所在屏幕的「带子」（屏宽 × 小人高），站着和走路时窗口不动，原生层每帧发 `pos {x, vx, w}`，网页按速度外推画小人；下落 / 被拖 / 跟随窗口时才上下挪窗口。网页在收到与当前画布宽度一致的 pos 之前不画。
2. 点击穿透：每帧按鼠标位置切 `ignoresMouseEvents`，像素级判定（网页 readPixels，帧缓冲不保留，所以在渲染完的同一帧里回答）。
3. 窗口扫描在后台线程（BackgroundScanner），脚下窗口由 WindowTracker 后台 8ms 轮询；主线程只读结果。
4. 公网热更新：清单 `{key,payload,sig}`，App 内置公钥验签；只接受构建号更大的包；`web-dev` 构建号不比 App 自带的新就不用。

## 找什么（按严重程度）

1. 崩溃 / 死锁 / 线程问题：NSLock 使用、DispatchSourceTimer suspend/resume 配对（WindowTracker）、Task.detached 里访问主线程对象、WKURLSchemeTask stop 之后回调、强制解包、设置窗口关闭时释放。
2. 行为逻辑错误：Brain 的落地 / 走路 / 跨屏 / 跟随窗口；带子窗口在屏幕切换、下落跨屏、拖到屏幕外时的位置计算（PetManager.screenFrame(near:)、Pet.applyFrame）；pos 外推会不会让小人抖动或越界；bounds/hit 坐标系。
3. 热更新安全与正确性：验签有没有可绕过的路径（比如 payload 与 sig 的对应、路径穿越、tar 解包、降级攻击、ETag 逻辑导致永远不更新或反复下载）；publish.mjs 与 RemoteUpdater 的字段 / 格式是否一致；FSEvents 自触发循环；全量部署后旧 web-dev 是否会覆盖新前端。
4. Swift ↔ TS 消息字段不一致（名字、类型、NSNumber、null）。
5. 脚本问题：deploy.sh 在 set -euo pipefail 下的错误处理、zsh 远端兼容、rsync 语义。
6. 设置页 React 问题（Select 值不在选项里、数字与字符串、状态过期）。

每条写：严重程度（严重 / 中 / 轻）、文件:行号、具体触发场景、引用代码、为什么是错的。读代码核实，证据不足的不要写；不要写代码风格意见。

## 输出

- 详细报告写 `tasks/004.report.md`：按严重程度排序的编号列表（最多 25 条）+ 一句总评。
- 最后一条消息（stdout）≤10 行摘要。
