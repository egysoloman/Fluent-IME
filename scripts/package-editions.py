#!/usr/bin/env python3
"""Package Fluent 拼音 (Lite and Full, from one verified app) and Fluent 注音.
Lite omits only the Transformer; Zhuyin is its own input method with one edition."""
from pathlib import Path
import hashlib, json, os, plistlib, shutil, subprocess, sys

root = Path(__file__).resolve().parents[1]
dist = root / 'dist'
source = dist / 'Fluent IME.app'
lite = dist / 'lite'
lite_app = lite / source.name
def run(*args, env=None):
    subprocess.run([str(arg) for arg in args], check=True, env=env)

run('codesign', '--verify', '--deep', '--strict', source)
lite.mkdir(exist_ok=True)
if lite_app.exists(): shutil.rmtree(lite_app)
run('ditto', source, lite_app)
shutil.rmtree(lite_app / 'Contents/Resources/Models', ignore_errors=True)
info_path = lite_app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info['FluentIMEEdition'] = 'lite'
info_path.write_bytes(plistlib.dumps(info))
run(sys.executable, root / 'scripts/package-maintenance.py', lite_app)
# Word data, Octagram plugin and the Wanxiang grammar model remain identical.
grammar = 'Contents/Resources/Rime/wanxiang-lts-zh-hans.gram'
assert hashlib.file_digest((source / grammar).open('rb'), 'sha256').digest() == hashlib.file_digest((lite_app / grammar).open('rb'), 'sha256').digest()
run(sys.executable, root / 'scripts/audit-distribution.py', lite_app)
run('codesign', '--force', '--sign', '-', lite_app)
run('codesign', '--verify', '--deep', '--strict', lite_app)
report = json.loads((dist / 'release.json').read_text())
report['executable_sha256'] = hashlib.file_digest((lite_app / 'Contents/MacOS/FluentIME').open('rb'), 'sha256').hexdigest()
(lite / 'release.json').write_text(json.dumps(report, indent=2) + '\n')
dmg_python = root / '.build/dmg-venv/bin/python'
for folder in [lite, dist]:
    env = {**os.environ, 'FLUENTIME_PACKAGE_DIR': str(folder), 'FLUENTIME_SKIP_ZIP': '1'}
    run(sys.executable, root / 'scripts/package-installer.py', env=env)
    run(dmg_python if dmg_python.exists() else sys.executable, root / 'scripts/package-dmg.py', env=env)
# Update: no language models at all. Installing it over an existing copy keeps the
# models already on the Mac (InstallationFiles.carryOverModels).
update = dist / 'update'
update_app = update / source.name
update.mkdir(exist_ok=True)
if update_app.exists(): shutil.rmtree(update_app)
run('ditto', lite_app, update_app)
(update_app / 'Contents/Resources/Rime/wanxiang-lts-zh-hans.gram').unlink()
for notice in ['Licenses/wanxiang-model.json', 'Rime/wanxiang-model.json']:
    (update_app / 'Contents/Resources' / notice).unlink(missing_ok=True)
info_path = update_app / 'Contents/Info.plist'
update_info = plistlib.loads(info_path.read_bytes()); update_info['FluentIMEEdition'] = 'update'
info_path.write_bytes(plistlib.dumps(update_info))
run(sys.executable, root / 'scripts/package-maintenance.py', update_app)
run(sys.executable, root / 'scripts/audit-distribution.py', update_app)
run('codesign', '--force', '--sign', '-', update_app)
run('codesign', '--verify', '--deep', '--strict', update_app)
(update / 'release.json').write_text(json.dumps({**report, 'executable_sha256': hashlib.file_digest((update_app / 'Contents/MacOS/FluentIME').open('rb'), 'sha256').hexdigest()}, indent=2) + '\n')
env = {**os.environ, 'FLUENTIME_PACKAGE_DIR': str(update), 'FLUENTIME_SKIP_ZIP': '1'}
run(sys.executable, root / 'scripts/package-installer.py', env=env)
run(dmg_python if dmg_python.exists() else sys.executable, root / 'scripts/package-dmg.py', env=env)
# Default download is Lite. Full carries a distinct asset and manifest name.
version = info['CFBundleShortVersionString']
shutil.copy2(lite / f'Fluent-IME-{version}-Setup.dmg', dist)
shutil.copy2(lite / 'release.json', dist)
shutil.copy2(update / f'Fluent-IME-{version}-Update-Setup.dmg', dist)
shutil.copy2(update / 'release-update.json', dist)
zhuyin = dist / 'zhuyin'
run(sys.executable, root / 'scripts/bundle-zhuyin.py')
env = {**os.environ, 'FLUENTIME_PACKAGE_DIR': str(zhuyin), 'FLUENTIME_SKIP_ZIP': '1', 'FLUENTIME_PRODUCT': 'zhuyin'}
run(sys.executable, root / 'scripts/package-installer.py', env=env)
run(dmg_python if dmg_python.exists() else sys.executable, root / 'scripts/package-dmg.py', env=env)
shutil.copy2(zhuyin / f'Fluent-Zhuyin-{version}-Setup.dmg', dist)
shutil.copy2(zhuyin / 'release-zhuyin.json', dist)
files = [dist / f'Fluent-IME-{version}{suffix}-Setup.dmg' for suffix in ['', '-Full', '-Update']] + [dist / f'Fluent-Zhuyin-{version}-Setup.dmg']
files += [dist / 'release.json', dist / 'release-full.json', dist / 'release-update.json', dist / 'release-zhuyin.json']
(dist / 'SHA256SUMS').write_text(''.join(hashlib.file_digest(file.open('rb'), 'sha256').hexdigest() + '  ' + file.name + '\n' for file in files))
for file in files[:4]: print(file.name, round(file.stat().st_size / 1024**2, 1), 'MiB')
