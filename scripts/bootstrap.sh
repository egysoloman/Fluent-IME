#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/prepare-rime.py"
REVISION=0c6861ef7420ee780270ca6d993d18d4101049d0
DEST="$ROOT/Vendor/rime-pinyin-simp"
if ! test -f "$DEST/pinyin_simp.dict.yaml"; then
  mkdir -p "$DEST"
  git -C "$DEST" init -q
  git -C "$DEST" fetch --depth 1 https://github.com/rime/rime-pinyin-simp.git "$REVISION"
  git -C "$DEST" checkout -q --detach FETCH_HEAD
fi
if test "$(git -C "$DEST" rev-parse HEAD)" != "$REVISION"; then
  echo "词库版本不匹配：需要 $REVISION" >&2
  exit 1
fi
echo "Rime 词库已就绪：$REVISION"
