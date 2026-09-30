# 任务 002：engine.ts 拆分后的回归 + 新 pet.html 冒烟测试

你在 /home/rakko/Collection/SpineStage（不是 git 仓库，别 git init、别 commit）。
先读 ~/ai/memory/MEMORY.md、~/ai/memory/spinestage-project.md、~/ai/memory/webgl-test-chrome.md，
再读 tasks/001.report.md（上次你自己写的报告，里面有起 Chrome 的坑和判据）。
**不需要、也不要访问外网。** vite dev 在 http://127.0.0.1:8066/ 跑着，别重启它、别动 8066 端口，别碰 9222 的常驻 chrome-cdp。
**这次只测不改**：不许改 web/、vendor/、scripts/、models 里的任何文件；发现问题写进报告就行。

## 背景（Claude 刚做的改动）

- `web/src/stage/engine.ts` 里的载入/贴图/测量函数原样搬到了新文件 `web/src/stage/model.ts`
  （`loadModel`、`decode`、`textureSource`、`detectRoles`、`boundsOf`、`unite`、`measure`），
  `Stage.load()` 现在只是调 `loadModel()`。目标是**行为完全不变**。
- `web/src/stage/loader.ts` 末尾新增 `fetchSkeletons()` / `fetchSetImages()`（按需下载）。
- 新页面 `web/pet.html` + `web/src/pet/main.ts`：macOS 桌宠用的透明渲染页。普通浏览器里打开是「调试模式」：
  自动按 `?model=&outfit=&group=&height=` 从 models/ 载入，画一只小人，脚底在画布水平中间、离底边 layout.footY 处；
  消息打到 console（`console.debug('[rhodeside ←]', msg)`，其中 `type:'loaded'` 那条带 layout/roles 等）；
  `window.__pet.layout` / `window.__pet.model` 可以读。

## 你要做的

1. 先把旧截图留底：`cp -r tasks/001-shots tasks/002-baseline`（001-verify.py 会覆盖 001-shots）。
2. 按 001 报告里的办法起临时无头 Chrome，端口 **9334**，单元名带时间戳（`spinestage-dsh-chrome-$(date +%H%M%S)`），
   profile 目录 `$HOME/.cache/spinestage-dsh-chrome`，必须带 `--password-store=basic`
   （上次 `systemd-run --user` 要 `env -u XDG_RUNTIME_DIR` 才连得上，照做）。
3. 跑回归：`/home/rakko/Collection/MoodleAnaly/.venv/bin/python tasks/001-verify.py`（它自己跑 normal / fallback / broken 三条路径）。
   然后把新的 `tasks/001-shots/*-alpha.png` 和 `tasks/002-baseline/` 里同名文件逐张比较
   （可以 import 001-verify.py 里的 `compare_rgba` / `analyze_alpha`，或自己用 PIL 写；说清楚阈值）。
   期望：每张 alpha 图与留底几乎一致（动画时间点不同会有差异——若差异大，看是不是同一帧时刻的问题，再用连通域判据判断完整/碎）。
4. pet.html 冒烟：写 `tasks/002-pet.py`（同一个 venv 的 Playwright，`connect_over_cdp("http://127.0.0.1:9334")`，新开 context/page，
   视口 600×600），依次打开：
   - `http://127.0.0.1:8066/pet.html?model=荒芜拉普兰德&group=基建`
   - `http://127.0.0.1:8066/pet.html?model=荒芜拉普兰德&outfit=char_1038_whitw2_sale_15&group=基建`
   - `http://127.0.0.1:8066/pet.html?model=荒芜拉普兰德&group=正面`
   每个等 ~6 秒，记录：console 里的 error/warn、`[rhodeside ←]` 各条消息的 type（至少要有 ready 和 loaded）、
   `loaded` 里的 outfit/group/layout/roles、`window.__pet.layout`；
   用 `document.getElementById('pet').toDataURL('image/png')` 取画布（带真实 alpha）存 `tasks/002-shots/<序号>-<outfit>-<group>.png`；
   判断：非透明像素是否聚成一个人形（连通域判据同 001），背景像素 alpha 是否全为 0（透明背景是桌宠的硬要求），
   人形底部（最低的非透明像素行）大约在画布底边往上 layout.footY 附近（允许有偏差，说出实际数值）。
   另外在第一个页面里调 `window.__pet.receive({type:'face', dir:-1})`，等 1 秒再取一张画布，确认小人水平翻转了且没被裁到边（左右边缘列有没有非透明像素）。
5. 收尾：`systemctl --user stop 'spinestage-dsh-chrome-*'`（同样可能要 `env -u XDG_RUNTIME_DIR`），`rm -rf ~/.cache/spinestage-dsh-chrome`，
   关掉自己开的页面。`tasks/002-baseline/` 留着别删。

## 输出

- 详细报告写 `tasks/002.report.md`：回归每张图的比较结果、pet.html 三个页面 + 翻转的结果和数值、console 错误、判据。
- 最后一条消息（stdout）≤10 行摘要：回归过没过、pet.html 过没过、有没有要 Claude 修的问题。
