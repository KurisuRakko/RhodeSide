# 任务 003：Rhodeside 设置页 + 桌宠页的浏览器冒烟测试

你在 /home/rakko/Collection/SpineStage（不是 git 仓库，别 git init、别 commit）。
先读 ~/ai/memory/MEMORY.md、~/ai/memory/spinestage-project.md、~/ai/memory/webgl-test-chrome.md，再读 tasks/002.report.md（上次的办法和坑）。
**不需要、也不要访问外网。** vite dev 在 http://127.0.0.1:8066/ 跑着，别重启它、别动 8066 端口，别碰 9222 的常驻 chrome-cdp。
**只测不改**：不许改 web/、vendor/、scripts/、macos/ 里的任何文件；发现问题写进报告。

## 背景

- `web/settings.html` + `web/src/settings/`（React + Rakko Design）是 macOS 桌宠 Rhodeside 的设置页。
  在普通浏览器里打开是「浏览器预览」模式：`bridge.ts` 里有一个假的原生层（内存状态），界面能点、状态会变，
  但导入 / 打开文件夹这类原生功能会弹 toast「浏览器预览里没有这个功能」。
- `web/pet.html` 新增了几条消息：`scale`（改大小，回 `layout`）、`hit`（像素级点击判定，回 `hit`）、`fps`、`pause`。
  调试模式下 `window.__pet.receive(msg)` 可以直接发消息，页面回的消息打到 console：`console.debug('[rhodeside ←]', msg)`。

## 你要做的

1. 起临时无头 Chrome：端口 **9335**，单元名 `spinestage-dsh-chrome-$(date +%H%M%S)`，profile `$HOME/.cache/spinestage-dsh-chrome3`，
   必须带 `--password-store=basic`（`systemd-run --user` 可能要 `env -u XDG_RUNTIME_DIR`，见 001/002 报告）。
2. 写 `tasks/003-smoke.py`（`/home/rakko/Collection/MoodleAnaly/.venv/bin/python`，Playwright `connect_over_cdp`，新开 context，视口 800×900）：
   **设置页** `http://127.0.0.1:8066/settings.html`：
   - 等 3 秒，收集 console error/warn 和 pageerror；截图 `tasks/003-shots/settings-1.png`（整页 full_page）。
   - 确认看得到：标题「Rhodeside」、「浏览器预览」徽标、「桌宠」「通用」「模型」「调试」四个分区、一张「第 1 只 · 荒芜拉普兰德」卡片、
     模型列表里有「荒芜拉普兰德」和「test-puppet」且显示「N 套」（数字，不是「…」）。
   - 点「添加一只」→ 出现「第 2 只」；在第 2 只卡片里把「大小」点成「大」、「步速」点成「快」，确认选中态变了（aria-checked / data-checked 之类，自己看 DOM）；
     点第 2 只的「收起」→ 按钮变成「再点一下收起」→ 再点 → 第 2 只消失。
   - 第 1 只的「模型」下拉（`button[aria-label=模型]`，选项 `[role=option]`）切成 test-puppet，确认卡片标题变成「第 1 只 · test-puppet」，
     「模型组」下拉出现且选项里有 test-puppet 的组；再切回荒芜拉普兰德，确认「时装」下拉出现两个时装。
   - 「通用」里三个开关各点一次，确认状态翻转；忽略名单里输入 `TestApp` 点「加上」→ 出现 chip，点它的 ✕ → 消失；点「恢复默认」若出现。
   - 点「导入模型…」→ 应该出现 toast（浏览器预览没有这个功能）。
   - 最后再截一张 `tasks/003-shots/settings-2.png`；再用 `emulate_media(color_scheme='dark')` 重开页面截 `settings-dark.png`，
     看深色模式下文字/背景对比是否正常（有没有白底黑字之外的明显问题，比如看不清的文字）。
   **桌宠页** `http://127.0.0.1:8066/pet.html?model=荒芜拉普兰德&group=基建&height=200`（视口 400×400）：
   - 等 6 秒，拿 `window.__pet.layout`；发 `window.__pet.receive({type:'scale', height: 120})`，等 1 秒，确认 console 里有 `type:'layout'` 且 layout 变小；
   - 用画布找一个不透明像素 (x, y)（注意：画布像素坐标 y 向下，消息里的 y 是 CSS px、原点在**左下角**、y 向上，要换算），
     发 `{type:'hit', id: 1, x, y}` → console 里应有 `{type:'hit', id:1, inside:true}`；再发一个四角透明处的点 → `inside:false`。说清楚你怎么换算的。
   - 发 `{type:'pause', paused:true}`，等 1 秒取两次画布（间隔 0.5 秒）应完全相同；发 `{paused:false}` 后两次画布应不同（小人在动）。
   - 发 `{type:'fps', value: 5}`，用 `requestAnimationFrame` 计数不行（它照常跑），改为隔 0.1 秒取 10 次画布，数有几种不同的画面（应明显少于 10）。再发 `{type:'fps', value:0}` 恢复。
3. 收尾：停掉自己起的 Chrome 单元（`systemctl --user stop 'spinestage-dsh-chrome-*'`，可能要 `env -u XDG_RUNTIME_DIR`），
   `rm -rf ~/.cache/spinestage-dsh-chrome3`（删不掉就在报告里说，别硬来），关掉自己开的页面。

## 输出

- 详细报告写 `tasks/003.report.md`：每一步的结果（过/不过 + 实际看到的内容）、console 错误原文、截图路径、换算方法。
- 最后一条消息（stdout）≤10 行摘要：哪些过了、哪些没过、有没有要 Claude 修的问题。
