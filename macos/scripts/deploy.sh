#!/usr/bin/env bash
# Rhodeside 部署（在 rakkoserver 上跑，Mac 通过 `ssh mac` 连）。
#
#   macos/scripts/deploy.sh          全量：编前端 → 同步源码 → Mac 上编译、签名、打包 → 取回并签名发布 App 和前端 → App 自己拉取、替换、重启
#                                    （编译要 ssh 到 Mac；装上新版本不需要，任何能上网的 Rhodeside 都会自动更新）
#   macos/scripts/deploy.sh install  同上，但编好直接在 Mac 上安装重启（首次安装，或自更新坏了时用）
#   macos/scripts/deploy.sh web      热更新：编前端并发布到公网通道 rhodeside.rakko.cn，App 几秒内自动拉取并原地重载（不需要 Tailscale）
#   macos/scripts/deploy.sh models   发布在线模型（macos/models.json；加模型就往里加一条）
#   macos/scripts/deploy.sh web-ssh  同上，但直接 ssh 推到 Mac（不经公网）
#   macos/scripts/deploy.sh test     在 Mac 上跑 PetCore 单元测试
#   macos/scripts/deploy.sh logs     看 App 日志最后 80 行
#   macos/scripts/deploy.sh snap     让 App 存一份调试快照（画布 PNG + 状态），列出文件
#
# 自动热更新（盯着源码自动选上面哪种）：node macos/scripts/dev.mjs
set -euo pipefail

MODE=${1:-full}
HERE=$(cd "$(dirname "$0")" && pwd)
MACOS=$(dirname "$HERE")
ROOT=$(dirname "$MACOS")
MAC=${RHODESIDE_MAC:-mac}
REMOTE=Build/Rhodeside              # 相对 Mac 上的 ~
WEB_OUT=$MACOS/.build-web
# 模型不再打进 App：有授权的模型只放服务器（macos/models.json 列出），登录后由 App 下载

say() { printf '\033[36m[rhodeside]\033[0m %s\n' "$*"; }

build_web() {
  say "编前端（vite build → macos/.build-web）"
  (cd "$ROOT" && corepack pnpm -s exec vite build --outDir "$WEB_OUT" --emptyOutDir --logLevel error)
  # 构建号（毫秒时间戳）：App 只接受比当前更新的前端，避免旧包覆盖新包
  date +%s%3N > "$WEB_OUT/.rhodeside-build"
}

publish_models() {
  # 和每天的 PRTS 同步（sync-prts.sh）共用一把锁：两边会用同一个暂存目录打包
  local state="$HOME/.local/state/rhodeside"
  mkdir -p "$state"
  (flock -w 1800 9 && node "$HERE/publish.mjs" --models "$MACOS/models.json") 9>"$state/publish-models.lock"
}

publish_web() {
  node "$HERE/publish.mjs" --dir "$WEB_OUT"
}

sync_macos() {
  ssh "$MAC" "mkdir -p $REMOTE/models $REMOTE/web $REMOTE/macos"
  rsync -a --delete --exclude .build --exclude .build-web "$MACOS/" "$MAC:$REMOTE/macos/"
}

sync_all() {
  say "同步到 $MAC:~/$REMOTE"
  sync_macos
  sync_web
  ssh "$MAC" "rm -rf $REMOTE/models && mkdir -p $REMOTE/models"
}

sync_web() {
  # models/ 不进 App（在线模型走 publish.mjs --models）
  rsync -a --delete --exclude /models "$WEB_OUT/" "$MAC:$REMOTE/web/"
}

case "$MODE" in
  full)
    build_web
    sync_all
    APP_BUILD=$(date +%s%3N)
    say "Mac 上编译、签名、打包（build ${APP_BUILD}）"
    ssh "$MAC" "RHODESIDE_BUILD=$APP_BUILD bash $REMOTE/macos/scripts/build-app.sh --package $REMOTE/Rhodeside.tar.gz"
    PKG=$(mktemp -d)/Rhodeside.tar.gz
    scp -q "$MAC:$REMOTE/Rhodeside.tar.gz" "$PKG"
    # 原生编译成功之后才发布：先 App 后前端（App 先检查 app.json，新 App 自带同版本前端）
    node "$HERE/publish.mjs" --app "$PKG" --build "$APP_BUILD"
    rm -rf "$(dirname "$PKG")"
    publish_web
    publish_models
    say "已发布；运行中的 Rhodeside 会在几秒内自动更新并重启"
    ;;
  install)
    build_web
    sync_all
    say "Mac 上编译打包并直接安装"
    ssh "$MAC" "RHODESIDE_BUILD=$(date +%s%3N) bash $REMOTE/macos/scripts/build-app.sh"
    publish_web
    ;;
  models)
    publish_models
    say "模型目录已发布；登录的 App 会在几秒内下载需要的模型"
    ;;
  web|publish)
    build_web
    publish_web
    say "已发布到 https://rhodeside.rakko.cn，App 会在几秒内拉取"
    ;;
  web-ssh)
    build_web
    sync_web
    # 先放到临时目录再整个换掉，App 监听到的是一次完整的替换
    ssh "$MAC" 'set -e
      D="$HOME/Library/Application Support/Rhodeside"
      mkdir -p "$D"
      rm -rf "$D/web-dev.new" "$D/web-dev.old"
      cp -R "$HOME/'"$REMOTE"'/web" "$D/web-dev.new"
      [ -d "$D/web-dev" ] && mv "$D/web-dev" "$D/web-dev.old"
      mv "$D/web-dev.new" "$D/web-dev"
      rm -rf "$D/web-dev.old"'
    say "网页已推到 Mac（~/Library/Application Support/Rhodeside/web-dev），App 会自动重载"
    ;;
  test)
    sync_macos
    ssh "$MAC" "cd $REMOTE/macos && set -o pipefail; swift test 2>&1 | tail -n 60"
    ;;
  logs)
    ssh "$MAC" 'tail -n 80 "$HOME/Library/Logs/Rhodeside/rhodeside.log"'
    ;;
  snap)
    ssh "$MAC" 'open "rhodeside://debug/snapshot"; sleep 2; ls -t "$HOME/Library/Logs/Rhodeside/snapshots" | head -n 8'
    ;;
  *)
    echo "用法：$0 [full|install|web|models|web-ssh|test|logs|snap]" >&2
    exit 2
    ;;
esac
