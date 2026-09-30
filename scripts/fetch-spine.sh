#!/usr/bin/env bash
# scripts/fetch-spine.sh —— 拉 Spine 3.8 官方 WebGL 运行时到 web/public/lib/spine/（原样，不改）。
# 明日方舟等游戏的模型大多是 3.8 导出的；换 4.x 运行时读不了 3.8 的 .skel。
# Spine 运行时受 Spine Runtimes License 约束，仅供个人本地使用。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="${1:-3.8}"
DEST="$ROOT/web/public/lib/spine"
mkdir -p "$DEST"
curl -fsSL "https://cdn.jsdelivr.net/gh/EsotericSoftware/spine-runtimes@${REF}/spine-ts/build/spine-webgl.js" -o "$DEST/spine-webgl.js.tmp"
mv "$DEST/spine-webgl.js.tmp" "$DEST/spine-webgl.js"
echo "spine-runtimes@${REF} → web/public/lib/spine/spine-webgl.js ($(wc -c < "$DEST/spine-webgl.js") bytes)"
