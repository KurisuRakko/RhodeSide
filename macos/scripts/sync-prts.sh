#!/usr/bin/env bash
# 每天由 systemd 用户定时器 rhodeside-prts.timer 跑：从 PRTS 拉新六星 / 新时装 / 基建语音，和上次成功发布时不一样就重新签名发布模型目录。
# App 只会在模型库里看到新条目，不会自动下载（已装的模型出了新版本会自动更新）。
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
STATE="${HOME}/.local/state/rhodeside"
mkdir -p "$STATE"
exec >>"$STATE/prts-sync.log" 2>&1
# 和 deploy.sh models 共用一把锁：两边会用同一个暂存目录打包
exec 9>"$STATE/publish-models.lock"
flock -w 1800 9
echo "=== $(date -Is) 开始"

# 内容指纹（不是大小）：models.json + models-private 下所有模型文件（点开头的临时 / 工作目录不算）
fingerprint() {
  { cat "$ROOT/macos/models.json"
    (cd "$ROOT/models-private" && find . -type f ! -path '*/.*' ! -name 'prts-index.json' -print0 | sort -z | xargs -0 sha256sum)
  } | sha256sum | cut -d' ' -f1
}

# 单个干员失败只记日志，不影响发布其余的
node "$HERE/fetch-prts.mjs" || echo "fetch-prts 退出码 $?，继续按现有文件发布"
# 基建语音（新干员、新补的配音）；已有的不重下
node "$HERE/fetch-voice.mjs" || echo "fetch-voice 退出码 $?，继续按现有文件发布"
now="$(fingerprint)"
last="$(cat "$STATE/prts-published.sha" 2>/dev/null || true)"
if [[ "$now" == "$last" ]]; then
  echo "=== $(date -Is) 和上次发布的一样，不发布"
  exit 0
fi
node "$HERE/publish.mjs" --models "$ROOT/macos/models.json"
echo "$now" > "$STATE/prts-published.sha"
echo "=== $(date -Is) 已发布"
