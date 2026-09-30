# models/

浏览器调试用的测试模型（`pnpm dev` 下的 `settings.html` 假原生层和 `pet.html` 调试模式从这里读）。
Rhodeside 本身不读这里：App 里的模型在 `~/Library/Application Support/Rhodeside/models/`，在线模型见 `macos/README.md`。

1. 每个模型一个文件夹，里面放 Spine 3.8 的 `.skel`（或 `.json`）、`.atlas`、`.png`。
   文件名以 `build_` 开头的算「基建」，路径里带 `back` 的算「背面」，其余算「正面」。
2. 在项目根目录跑 `node scripts/scan-models.mjs` 生成 `index.json` 清单；`pnpm dev` 前会自动跑一次。
3. 不要把有授权的模型放这里（dev server 对局域网开放）；那些放 `models-private/`。

这个目录里的文件不会进 git（见 .gitignore），也不会打进 App（`deploy.sh` 同步前端时排除了 `models/`）。
