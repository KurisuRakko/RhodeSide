# 任务 001：验收 SpineStage 里的荒芜拉普兰德模型 + 贴图缩放修复

你在 /home/rakko/Collection/SpineStage（不是 git 仓库，别 git init、别 commit）。
先读 ~/ai/memory/MEMORY.md、~/ai/memory/spinestage-project.md、~/ai/memory/webgl-test-chrome.md。
**你不需要、也不要访问外网**：模型文件已经下载好，所有测试都走本机 http://127.0.0.1:8066/（vite dev 已在跑，别重启它、别动 8066 端口）。

## 已完成（Claude 做的）

- 从 PRTS 下载了荒芜拉普兰德（char_1038_whitw2）两套时装 × 正面/背面/基建 = 6 套，放在
  `web/public/models/荒芜拉普兰德/`，`node scripts/scan-models.mjs` 已跑，`web/public/models/index.json` 已包含。
- 坑：两套**基建**的 PNG 被 PRTS 缩小了（atlas 写 532/664，PNG 只有 356/444），Spine 3.8 运行时按贴图真实宽高算 UV
  （spine-webgl.js 约 6624 行 page.width、约 7794 行 mesh updateUVs），于是模型碎成一片片。
- 修复：`web/src/stage/loader.ts` 新增 `atlasPageSizes()`；`web/src/stage/engine.ts` 新增 `decode()`：
  贴图尺寸对不上 atlas 声明时，先试 `createImageBitmap` 的 resizeWidth/resizeHeight，浏览器不认（结果尺寸仍不对）就走 canvas 拉伸兜底；
  `load()` 里按 MAX_TEXTURE_SIZE 限制。`corepack pnpm -s check` 已通过。
- 第一版（只有 resize 选项）Claude 在浏览器里看过基建和正面都正常；**第二版（加了 decode/兜底）还没在浏览器里验证过**——这就是你的活。

## 你要做的

1. 起临时无头 Chrome（照 webgl-test-chrome 记忆，端口用 **9334**，单元名带时间戳，必须带 `--password-store=basic`）：
   `systemd-run --user --unit spinestage-dsh-chrome-$(date +%H%M%S) --collect -p MemoryMax=1500M /usr/bin/google-chrome --headless=new --user-data-dir=$HOME/.cache/spinestage-dsh-chrome --password-store=basic --remote-debugging-port=9334 --remote-allow-origins=* --no-first-run --use-angle=swiftshader --enable-unsafe-swiftshader --window-size=1400,900 about:blank`
   **不要**碰 9222 的常驻 chrome-cdp。
2. 写一个 Playwright 脚本（用 `/home/rakko/Collection/MoodleAnaly/.venv/bin/python`，里面有 playwright；
   `playwright.chromium.connect_over_cdp("http://127.0.0.1:9334")`），脚本放 `tasks/001-verify.py`：
   - 打开 `http://127.0.0.1:8066/?model=荒芜拉普兰德`（URL 编码），等 ~8 秒。收集 console 里的 error 和页面上的报错文字。
   - 界面操作方法（已实测）：模式切换是 `span.rk-segment`（文字「漫步」/「查看」）；
     下拉是 `button[aria-label=时装组]`、`button[aria-label=模型组]`，点开后选项是 `[role=option]`，按文字点。
     时装组有两个：`char_1038_whitw2`、`char_1038_whitw2_sale_15`；模型组：正面/背面/基建。
     注意 page 对象要拿 8066 那个标签，不是 about:blank（之前就是拿错标签导致 querySelector 返回 null）。
   - 切到「查看」模式，逐个遍历 2 时装 × 3 模型组 = 6 套，每套等 ~5 秒后截图到 `tasks/001-shots/<时装>-<组>.png`。
   - **兜底路径测试**：用 `page.add_init_script` 在页面脚本前把 `window.createImageBitmap` 包一层，
     把 options 里的 resizeWidth/resizeHeight/resizeQuality 删掉再调原函数（模拟不支持 resize 的浏览器），
     重新打开页面，再截两套基建图到 `tasks/001-shots/fallback-<时装>-基建.png`。
3. 看截图判断（截图是 PNG，用你能用的方式检查；至少要判断出「角色完整」还是「碎成一堆散落碎片」）：
   可以对比同一套在正常路径和兜底路径下的截图像素差（PIL 在 MoodleAnaly venv 里如果没有就用别的方法），
   以及检查画布区域非背景像素是否聚成一个人形而不是散开。说清楚你用了什么判据。
4. 只有发现真 bug 时才改 `web/src/stage/engine.ts` / `loader.ts`（最小改动），改完跑 `corepack pnpm -s check`，并重新验证。
   不要改 `vendor/`、`web/public/lib/`、模型文件。
5. 收尾：`systemctl --user stop 'spinestage-dsh-chrome-*'`，`rm -rf ~/.cache/spinestage-dsh-chrome`。

## 输出

- 详细报告写 `tasks/001.report.md`：每套模型的结果（正常/碎/报错）、console 错误、兜底路径结果、判据、改了什么（若有，贴 diff）。
- 最后一条消息（stdout）≤10 行摘要。
