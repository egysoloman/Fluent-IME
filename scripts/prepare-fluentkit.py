#!/usr/bin/env python3
"""Resolve public SPM dependencies and record the checked-out FluentKit revision."""
from pathlib import Path
import json, os, subprocess
root = Path(__file__).resolve().parents[1]
subprocess.run(["swift", "package", "resolve"], cwd=root, check=True)
override = os.environ.get("FLUENTKIT_PATH")
if override:
    source = Path(override).expanduser().resolve()
    revision = None
else:
    pin = next(p for p in json.loads((root / "Package.resolved").read_text())["pins"] if p["identity"].lower() == "fluentkit")
    revision = pin["state"]["revision"]
    source = root / ".build/checkouts/FluentKit"
    if not source.exists():
        source = next(p for p in (root / ".build/checkouts").iterdir() if p.name.lower() == "fluentkit")
    assert subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() == revision
manifest = {"revision": revision, "snapshot": str(source.relative_to(root)) if source.is_relative_to(root) else str(source), "scope": "Swift Package Manager checkout; version and revision pinned in Package.resolved." if revision else "Explicit FLUENTKIT_PATH developer override."}
(root / "Resources/Licenses/fluentkit-source.json").write_text(json.dumps(manifest, indent=2) + "\n")

# Patch FluentLocalization to avoid SwiftPM fatalError when Bundle.module is evaluated in an App bundle
loc_file = source / "Sources/FluentKit/FluentLocalization.swift"
if loc_file.exists():
    text = loc_file.read_text()
    if "bundle: .module" in text:
        loc_file.chmod(0o644)
        replacement = """    private static let fallbackBundle: Bundle = {
        let name = "FluentKit_FluentKit.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.appendingPathComponent(name),
            Bundle.main.bundleURL
        ]
        for url in candidates.compactMap({ $0 }) {
            if let b = Bundle(url: url) { return b }
        }
        return Bundle.main
    }()

    public static func controlString"""
        text = text.replace("public static func controlString", replacement, 1)
        text = text.replace("bundle: .module", "bundle: fallbackBundle", 1)
        loc_file.write_text(text)

print("FluentKit: " + str(source))
