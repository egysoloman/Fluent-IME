#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/dist/Fluent IME.app"
TARGET="$HOME/Library/Input Methods/Fluent IME.app"
SUPPORT="$HOME/Library/Application Support/FluentIME"
if ! test -d "$SOURCE"; then bash "$ROOT/scripts/build.sh"; fi
mkdir -p "$HOME/Library/Input Methods" "$SUPPORT/InstallStaging"
STAGE="$(mktemp -d "$SUPPORT/InstallStaging/install.XXXXXX")"
# Copy outside the watched Input Methods directory. macOS can otherwise launch
# and protect a partially copied bundle before ditto has finished its resources.
ditto "$SOURCE" "$STAGE/Fluent IME.app"
codesign --verify --deep --strict "$STAGE/Fluent IME.app"
if test -e "$TARGET"; then
  BACKUP="$SUPPORT/Backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP"
  mv "$TARGET" "$BACKUP/Fluent IME.app"
  echo "旧版本已备份：$BACKUP"
fi
if ! mv "$STAGE/Fluent IME.app" "$TARGET"; then
  if test -n "${BACKUP:-}"; then mv "$BACKUP/Fluent IME.app" "$TARGET"; fi
  exit 1
fi
rmdir "$STAGE"
codesign --verify --deep --strict "$TARGET"
"$TARGET/Contents/MacOS/FluentIME" --register
echo '已安装 Fluent 拼音。未改变当前输入法。若输入法列表尚未显示，请注销并重新登录。'
