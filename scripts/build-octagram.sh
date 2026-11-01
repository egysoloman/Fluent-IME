#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REVISION=57d18b9f58e5284bd891d559f6bdd16cf60341e9
SOURCE=Vendor/librime-octagram
if ! test -d "$SOURCE/.git"; then
  git init -q "$SOURCE"
  git -C "$SOURCE" fetch --depth 1 https://github.com/lotem/librime-octagram.git "$REVISION"
  git -C "$SOURCE" checkout -q --detach FETCH_HEAD
fi
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$REVISION"
mkdir -p .build/plugins
RIME_SOURCE=Vendor/librime-source
RIME_REVISION=33e78140250125871856cdc5b42ddc6a5fcd3cd4
if ! test -d "$RIME_SOURCE/.git"; then
  git init -q "$RIME_SOURCE"
  git -C "$RIME_SOURCE" fetch --depth 1 https://github.com/rime/librime.git "$RIME_REVISION"
  git -C "$RIME_SOURCE" checkout -q --detach FETCH_HEAD
fi
test "$(git -C "$RIME_SOURCE" rev-parse HEAD)" = "$RIME_REVISION"
mkdir -p .build/plugins/include/rime
cat > .build/plugins/include/rime/build_config.h <<'EOF'
#define RIME_ENABLE_LOGGING
#define RIME_VERSION "1.17.0"
EOF
if ! test -f "$(brew --prefix)/include/boost/signals2/connection.hpp"; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install boost
fi
PREFIX="$(brew --prefix)"
clang++ -std=c++17 -O2 -DGLOG_USE_GLOG_EXPORT -dynamiclib "$SOURCE"/src/*.cc \
  -I .build/plugins/include -I "$RIME_SOURCE/src" -I "$RIME_SOURCE/include" \
  -I "$PREFIX/include" -I "$PREFIX/opt/librime/include" -L "$PREFIX/lib" \
  -lrime -lglog -lgflags -lyaml-cpp -lmarisa \
  -Wl,-install_name,@rpath/librime-octagram.dylib \
  -o .build/plugins/librime-octagram.dylib
