#!/bin/bash
# 在 Mac 上跑（deploy.sh 通过 ssh 调）：编译 → 在临时目录组装 Rhodeside.app → ad-hoc 签名，然后
#   build-app.sh                 替换 ~/Applications 里的并启动（直接安装）
#   build-app.sh --package OUT   打成 OUT（tar.gz），不安装：由服务器签名发布，App 自己拉取更新
# RHODESIDE_BUILD：App 构建号（毫秒时间戳，写进 Info.plist 的 RhodesideBuild；自更新只装更大的）
set -euo pipefail

PACKAGE=""
if [ "${1:-}" = "--package" ]; then
  PACKAGE=${2:?缺输出路径}
  PACKAGE="$(cd "$(dirname "$PACKAGE")" && pwd)/$(basename "$PACKAGE")" # 下面会 cd，先转成绝对路径
fi
APP_BUILD=${RHODESIDE_BUILD:-$(($(date +%s) * 1000))}

BUILD=${BUILD:-$HOME/Build/Rhodeside}
DEST=$HOME/Applications/Rhodeside.app
SUPPORT="$HOME/Library/Application Support/Rhodeside"

cd "$BUILD/macos"
# 进度行太吵，滤掉；编译的退出码单独取（`|| true` 会把 PIPESTATUS 冲掉，不能那样写）
set +e
swift build -c release 2>&1 | grep -Ev '^\[[0-9]+/[0-9]+\]'
status=${PIPESTATUS[0]}
set -e
[ "$status" -eq 0 ] || { echo "swift build 失败（exit $status）" >&2; exit 1; }
BIN="$(swift build -c release --show-bin-path)/Rhodeside"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/rhodeside.XXXXXX")
APP="$STAGE/Rhodeside.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rhodeside"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(date +%Y%m%d.%H%M%S)" "$APP/Contents/Info.plist"
plutil -replace RhodesideBuild -string "$APP_BUILD" "$APP/Contents/Info.plist"
cp -R "$BUILD/web" "$APP/Contents/Resources/web"
mkdir -p "$BUILD/models" # 现在是空的：模型登录后从服务器下载
cp -R "$BUILD/models" "$APP/Contents/Resources/models"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ -n "$PACKAGE" ]; then
  # 不带 AppleDouble / 扩展属性：App 解压时按清单里的 sha256 校验，包里只该有 .app 本身
  COPYFILE_DISABLE=1 tar --no-mac-metadata -czf "$PACKAGE" -C "$STAGE" Rhodeside.app
  rm -rf "$STAGE"
  echo "已打包 build ${APP_BUILD} → ${PACKAGE}（$(du -h "$PACKAGE" | cut -f1)）"
  exit 0
fi

# 退出旧的（SIGTERM 会让它存好位置再退）
if pgrep -x Rhodeside >/dev/null; then
  pkill -TERM -x Rhodeside || true
  for _ in $(seq 1 50); do pgrep -x Rhodeside >/dev/null || break; sleep 0.1; done
  pkill -KILL -x Rhodeside 2>/dev/null || true
fi

# 不原地覆盖已签名的程序（系统会按旧签名缓存把新的杀掉）：删掉再整个挪过去
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
mv "$APP" "$DEST"
rmdir "$STAGE"
# 全量部署以后用 App 自带的网页；热更新推上来的开发版删掉，免得挡住新的
rm -rf "$SUPPORT/web-dev"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
open "$DEST"
sleep 1.5
if pgrep -x Rhodeside >/dev/null; then
  echo "Rhodeside 已启动（pid $(pgrep -x Rhodeside)）"
else
  echo "Rhodeside 没起来，看日志：~/Library/Logs/Rhodeside/rhodeside.log" >&2
  exit 1
fi
