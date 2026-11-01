#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 scripts/prepare-fluentkit.py
python3 scripts/localize.py --check
bash scripts/bootstrap.sh
python3 scripts/fetch-wanxiang.py
python3 scripts/fetch-wanxiang-dictionary.py
python3 scripts/fetch-symbol-search.py
python3 scripts/generate-emoji-opencc.py
python3 scripts/generate-schemas.py
export RIME_PREFIX="${RIME_PREFIX:-$ROOT/.build/rime-runtime}"
CONFIG="${CONFIGURATION:-release}"
swift build -c "$CONFIG" --jobs 8
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
python3 scripts/bundle.py "$BIN"
echo "已生成：$ROOT/dist/Fluent IME.app"
