#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:?Usage: audit-theme.sh output-directory}"
mkdir -p "$OUTPUT"
PRODUCTS="$PWD/.build/out/Products/Release"
sources=()
for source in Sources/FluentIME/*.swift; do
    [[ "$source" == */main.swift ]] || sources+=("$source")
done
ditto "$PRODUCTS/FluentKit_FluentKit.bundle" "$OUTPUT/FluentKit_FluentKit.bundle"
swiftc -parse-as-library -O -swift-version 5 -I "$PRODUCTS" \
    -Xcc "-fmodule-map-file=$PWD/.build/out/Intermediates.noindex/GeneratedModuleMaps/CRimeBridge.modulemap" \
    "${sources[@]}" Tests/Native/SettingsThemeAudit.swift \
    "$PRODUCTS/FluentKit.o" "$PRODUCTS/FluentIMECore.o" "$PRODUCTS/CRimeBridge.o" \
    -L "$PWD/.build/rime-runtime/lib" -Xlinker -rpath -Xlinker "$PWD/.build/rime-runtime/lib" -lrime -framework InputMethodKit -framework Carbon \
    -o "$OUTPUT/SettingsThemeAudit"
for scenario in general search preview; do
    page=general
    edit=1
    [[ "$scenario" != general ]] || edit=0
    [[ "$scenario" != preview ]] || page=preview
    for preference in system light dark; do
        target="$OUTPUT/final-$scenario/$preference"
        mkdir -p "$target"
        FLUENTIME_RENDER_THEME="$preference" FLUENTIME_RENDER_PAGE="$page" THEME_AUDIT_EDIT_SEARCH="$edit" \
            "$OUTPUT/SettingsThemeAudit" "$target/images" "$PWD/dist/Fluent IME.app/Contents/Resources/Rime" > "$target/run.log" 2>&1
    done
done
python3 scripts/check-theme-audit.py "$OUTPUT"
