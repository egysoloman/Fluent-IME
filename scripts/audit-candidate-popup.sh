#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:?Usage: audit-candidate-popup.sh output-directory}"
mkdir -p "$OUTPUT"
PRODUCTS="$PWD/.build/out/Products/Release"
sources=()
for source in Sources/FluentIME/*.swift; do
    [[ "$source" == */main.swift ]] || sources+=("$source")
done
for bundle in "$PRODUCTS"/*.bundle; do
    ditto "$bundle" "$OUTPUT/$(basename "$bundle")"
done
swiftc -parse-as-library -O -swift-version 5 -I "$PRODUCTS" \
    -Xcc "-fmodule-map-file=$PWD/.build/out/Intermediates.noindex/GeneratedModuleMaps/CRimeBridge.modulemap" \
    "${sources[@]}" Tests/Native/CandidatePopupAudit.swift \
    "$PRODUCTS/FluentKit.o" "$PRODUCTS/FluentIMECore.o" "$PRODUCTS/CRimeBridge.o" \
    -L "$PWD/.build/rime-runtime/lib" -Xlinker -rpath -Xlinker "$PWD/.build/rime-runtime/lib" -lrime -framework InputMethodKit -framework Carbon \
    -o "$OUTPUT/CandidatePopupAudit"
FLUENTIME_RENDER_THEME=system FLUENTIME_RENDER_PAGE=preview "$OUTPUT/CandidatePopupAudit" "$OUTPUT"
