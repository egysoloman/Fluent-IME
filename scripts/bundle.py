#!/usr/bin/env python3
"""Build a relocatable, locally ad-hoc signed InputMethodKit app bundle."""
import os
import hashlib
import json
import plistlib
import re
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
BIN = Path(sys.argv[1])
APP = ROOT / "dist/Fluent IME.app"
CONTENTS = APP / "Contents"
RESOURCES = CONTENTS / "Resources"
FRAMEWORKS = CONTENTS / "Frameworks"

def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)

def copy_fluentkit_notices(source, destination):
    """Carry upstream attribution with the selected framework, including overrides."""
    files = [(source / "LICENSE", "FluentKit-MIT.txt")]
    if (source / "NOTICE.md").is_file():
        files.append((source / "NOTICE.md", "FluentKit-NOTICE.md"))
    for notice in sorted((source / "LICENSES").glob("*.txt")):
        files.append((notice, "FluentKit-" + notice.name))
    for notice, name in files:
        shutil.copy2(notice, destination / name)
    return ["Licenses/" + name for _, name in files]

run("python3", ROOT / "scripts/localize.py", "--check")
run("python3", ROOT / "scripts/generate-emoji-opencc.py", "--check")

if APP.exists():
    shutil.rmtree(APP)
for folder in (CONTENTS / "MacOS", RESOURCES, FRAMEWORKS):
    folder.mkdir(parents=True, exist_ok=True)
executable = CONTENTS / "MacOS/FluentIME"
shutil.copy2(BIN / "FluentIME", executable)
shutil.copy2(ROOT / "Resources/Info.plist", CONTENTS / "Info.plist")
for folder in (ROOT / "Resources").glob("*.lproj"):
    shutil.copytree(folder, RESOURCES / folder.name)
shutil.copytree(ROOT / "Resources/Rime", RESOURCES / "Rime")
shutil.copytree(ROOT / "Resources/FluentEmoji", RESOURCES / "FluentEmoji")
shutil.copy2(ROOT / "Vendor/rime-pinyin-simp/pinyin_simp.dict.yaml", RESOURCES / "Rime")
for bundle in BIN.glob("*.bundle"):
    shutil.copytree(bundle, RESOURCES / bundle.name)

# Core ML runs inside the native process; Python is only a conversion-time tool.
models = ROOT / "Resources/Models"
if (models / "ChineseContextScorer.mlpackage").exists():
    target = RESOURCES / "Models"
    target.mkdir()
    run("xcrun", "coremlcompiler", "compile", models / "ChineseContextScorer.mlpackage", target)
    for name in ("chinese-context-vocab.txt", "chinese-context-model.json", "CHINESE-CONTEXT-MODEL-CARD.md", "CHINESE-CONTEXT-LICENSE.txt"):
        shutil.copy2(models / name, target / name)

shutil.copy2(ROOT / "Vendor/wanxiang/wanxiang-lts-zh-hans.gram", RESOURCES / "Rime/wanxiang-lts-zh-hans.gram")
shutil.copy2(ROOT / "Vendor/wanxiang/model.json", RESOURCES / "Rime/wanxiang-model.json")

copied = {}
def bundle_dependencies(binary, is_executable=False):
    lines = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
    for line in lines:
        dependency = line.strip().split(" (compatibility")[0]
        if dependency == "@rpath/librime.1.dylib":
            source = Path(os.environ.get("RIME_PREFIX", str(ROOT / ".build/rime-runtime"))) / "lib/librime.1.dylib"
        elif dependency.startswith(("/opt/homebrew/", "/usr/local/", str(ROOT / ".build/"))):
            source = Path(dependency)
        else:
            continue
        target = FRAMEWORKS / source.name
        if source.resolve() not in copied:
            copied[source.resolve()] = target
            shutil.copy2(source, target)
            target.chmod(0o755)
            run("install_name_tool", "-id", "@rpath/" + target.name, target)
            bundle_dependencies(target)
        else:
            target = copied[source.resolve()]
        replacement = "@executable_path/../Frameworks/" + target.name if is_executable else "@loader_path/" + os.path.relpath(target, binary.parent)
        run("install_name_tool", "-change", dependency, replacement, binary)

bundle_dependencies(executable, True)
# Source-build search paths must not remain in the installed executable.
commands = subprocess.check_output(["otool", "-l", str(executable)], text=True)
for path in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", commands):
    if path.startswith("/"):
        run("install_name_tool", "-delete_rpath", path, executable)

# The runtime archive contains the separately compiled, pinned BSD Octagram revision.
plugin = FRAMEWORKS / "rime-plugins/librime-octagram.dylib"
plugin.parent.mkdir()
shutil.copy2(Path(os.environ.get("RIME_PREFIX", str(ROOT / ".build/rime-runtime"))) / "lib/rime-plugins/librime-octagram.dylib", plugin)
run("install_name_tool", "-id", "@rpath/librime-octagram.dylib", plugin)
bundle_dependencies(plugin)
run("install_name_tool", "-change", "@rpath/librime.1.dylib", "@loader_path/../librime.1.dylib", plugin)
# Homebrew bottles may require a newer macOS than the Swift source baseline.
# Declare the actual runtime requirement instead of advertising incompatible systems.
minimums = [(13, 0)]
for binary in [executable, *FRAMEWORKS.rglob("*.dylib")]:
    commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    minimums.extend(tuple(map(int, value.split("."))) for value in re.findall(r"\bminos\s+(\d+(?:\.\d+)*)", commands))
with (CONTENTS / "Info.plist").open("rb") as file:
    info = plistlib.load(file)
info["LSMinimumSystemVersion"] = ".".join(map(str, max(minimums)))
info["FluentIMEEdition"] = "full" if (RESOURCES / "Models/ChineseContextScorer.mlmodelc").exists() else "lite"
with (CONTENTS / "Info.plist").open("wb") as file:
    plistlib.dump(info, file)
licenses = RESOURCES / "Licenses"
licenses.mkdir()
shutil.copytree(ROOT / "Resources/Licenses", licenses, dirs_exist_ok=True)
shutil.copy2(Path(os.environ.get("RIME_PREFIX", str(ROOT / ".build/rime-runtime"))) / "Licenses/librime-octagram-LICENSE.txt", licenses / "librime-octagram-LICENSE.txt")
for folder, prefix in [("wanxiang-dictionary", "Wanxiang-Dictionary"), ("cldr", "Unicode-CLDR")]:
    shutil.copy2(ROOT / "Vendor" / folder / "LICENSE", licenses / (prefix + "-LICENSE.txt"))
for folder, name in [("wanxiang-dictionary", "sources.json"), ("wanxiang-dictionary", "conversion.json"), ("cldr", "sources.json")]:
    shutil.copy2(ROOT / "Vendor" / folder / name, licenses / (folder + "-" + name))
shutil.copy2(ROOT / "Resources/FluentEmoji/LICENSE", licenses / "Fluent-Emoji-MIT.txt")
shutil.copy2(ROOT / "Vendor/wanxiang/LICENSE", licenses / "Wanxiang-CC-BY-4.0.txt")
shutil.copy2(ROOT / "LICENSE", licenses / "FluentIME-MIT.txt")
fluent_source = Path(os.environ.get("FLUENTKIT_PATH", str(ROOT / ".build/checkouts/FluentKit")))
fluent_notices = copy_fluentkit_notices(fluent_source, licenses)
fluent_provenance = json.loads((licenses / "fluentkit-source.json").read_text())
components = json.loads((licenses / "components.json").read_text())
for component in components:
    if component["name"] == "FluentKit":
        component["revision"] = fluent_provenance["revision"]
        component["notices"] = fluent_notices + ["Licenses/fluentkit-source.json"]
(licenses / "components.json").write_text(json.dumps(components, indent=2, ensure_ascii=False) + "\n")
for source in (ROOT / "Vendor/rime-pinyin-simp").glob("*"):
    if source.name.lower().startswith(("license", "copying", "readme", "authors", "notice")):
        shutil.copy2(source, licenses / ("rime-pinyin-simp-" + source.name))
for realpath in copied:
    package = realpath.parent.parent
    for source in package.glob("*"):
        if source.is_file() and source.name.lower().startswith(("license", "copying", "notice", "authors")):
            shutil.copy2(source, licenses / (package.parent.name + "-" + source.name))
shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", licenses)
run("python3", ROOT / "scripts/make-icons.py", RESOURCES)
for library in FRAMEWORKS.rglob("*.dylib"):
    run("codesign", "--force", "--sign", "-", library)
run("codesign", "--force", "--sign", "-", executable)

deployment = ROOT / ".build/rime-deployment"
if deployment.exists():
    shutil.rmtree(deployment)
deployment.mkdir(parents=True)
# Compile the table once with its sources, then compile spelling variants against
# that table. Rime supports source-less precompiled dictionaries; this avoids
# hashing the same 47 MB import once for every preference combination.
runtime_default = RESOURCES / "Rime/default.yaml"
all_schemas = runtime_default.read_text()
base_only = '\n'.join(line for line in all_schemas.split('\n')
                      if not re.match(r'  - schema: fluent_(pinyin|bopomofo)_', line))
runtime_default.write_text(base_only)
run(executable, "--deploy", RESOURCES / "Rime", deployment)
runtime_default.write_text(all_schemas)
dict_source = RESOURCES / "Rime/fluent_pinyin.dict.yaml"
held_source = RESOURCES / "Rime/fluent_pinyin.dict.yaml.source"
dict_source.rename(held_source)
try:
    run(executable, "--deploy", RESOURCES / "Rime", deployment)
finally:
    held_source.rename(dict_source)
shutil.copytree(deployment / "build", RESOURCES / "Rime/build")
# select_schema loads compiled variants directly; the IME manages its own options.
# Only the base schema belongs in the Rime menu/first-launch deployment check.
runtime_default.write_text(base_only)
# Its source checksum changed; let Rime regenerate this small menu config.
(RESOURCES / "Rime/build/default.yaml").unlink()
run("python3", ROOT / "scripts/package-maintenance.py", APP)
run("python3", ROOT / "scripts/audit-distribution.py", APP)
run("python3", ROOT / "scripts/localize.py", "--check", "--bundle", APP)
run("codesign", "--force", "--sign", "-", APP)
run("codesign", "--verify", "--deep", "--strict", APP)

(ROOT / "dist/release.json").write_text(json.dumps({
    "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
    "executable_sha256": hashlib.file_digest(executable.open("rb"), "sha256").hexdigest(),
    "signing": "ad-hoc", "notarized": False
}, indent=2) + "\n")
