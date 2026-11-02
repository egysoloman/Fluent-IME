#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# bash scripts/install.sh [zhuyin] installs Fluent 拼音, or Fluent 注音 with "zhuyin".
if [ "${1:-pinyin}" = zhuyin ]; then
  SOURCE="$ROOT/dist/zhuyin/Fluent Zhuyin.app"; NAME="Fluent 注音"
  TARGET="$HOME/Library/Input Methods/Fluent Zhuyin.app"
  SUPPORT="$HOME/Library/Application Support/FluentZhuyin"
else
  SOURCE="$ROOT/dist/Fluent IME.app"; NAME="Fluent 拼音"
  TARGET="$HOME/Library/Input Methods/Fluent IME.app"
  SUPPORT="$HOME/Library/Application Support/FluentIME"
fi
if ! test -d "$SOURCE"; then bash "$ROOT/scripts/build.sh"; fi
mkdir -p "$HOME/Library/Input Methods" "$SUPPORT/InstallStaging"
STAGE="$(mktemp -d "$SUPPORT/InstallStaging/install.XXXXXX")"
# Copy outside the watched Input Methods directory. macOS can otherwise launch
# and protect a partially copied bundle before ditto has finished its resources.
APP="$(basename "$TARGET")"
ditto "$SOURCE" "$STAGE/$APP"
codesign --verify --deep --strict "$STAGE/$APP"
if test -e "$TARGET"; then
  BACKUP="$SUPPORT/Backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP"
  mv "$TARGET" "$BACKUP/$APP"
  echo "旧版本已备份：$BACKUP"
fi
if ! mv "$STAGE/$APP" "$TARGET"; then
  if test -n "${BACKUP:-}"; then mv "$BACKUP/$APP" "$TARGET"; fi
  exit 1
fi
rmdir "$STAGE"
codesign --verify --deep --strict "$TARGET"
"$TARGET/Contents/MacOS/FluentIME" --register
echo "已安装 ${NAME}。未改变当前输入法。若输入法列表尚未显示，请注销并重新登录。"
