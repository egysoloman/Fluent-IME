#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:?Usage: audit-maintenance.sh output-directory}"
mkdir -p "$OUTPUT"
PRODUCTS="$PWD/.build/out/Products/Release"
sources=()
for source in Sources/FluentIME/*.swift; do
    [[ "$source" == */main.swift ]] || sources+=("$source")
done
for bundle in "$PRODUCTS"/*.bundle; do ditto "$bundle" "$OUTPUT/$(basename "$bundle")"; done
swiftc -parse-as-library -O -swift-version 5 -I "$PRODUCTS" \
    -Xcc "-fmodule-map-file=$PWD/.build/out/Intermediates.noindex/GeneratedModuleMaps/CRimeBridge.modulemap" \
    "${sources[@]}" Tests/Native/MaintenanceAudit.swift \
    "$PRODUCTS/FluentKit.o" "$PRODUCTS/FluentIMECore.o" "$PRODUCTS/CRimeBridge.o" \
    -L "$PWD/.build/rime-runtime/lib" -Xlinker -rpath -Xlinker "$PWD/.build/rime-runtime/lib" -lrime \
    -framework InputMethodKit -framework Carbon -o "$OUTPUT/MaintenanceAudit"
for language in zh-Hans zh-Hant en; do
    FLUENTIME_RENDER_LANGUAGE="$language" FLUENTIME_RENDER_THEME=system "$OUTPUT/MaintenanceAudit" "$OUTPUT/$language" --render-audit
done
