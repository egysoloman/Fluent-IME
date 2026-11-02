#!/usr/bin/env python3
"""Package both editions from one verified app; Lite omits only the Transformer."""
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
# Default download is Lite. Full carries a distinct asset and manifest name.
version = info['CFBundleShortVersionString']
shutil.copy2(lite / f'Fluent-IME-{version}-Setup.dmg', dist)
shutil.copy2(lite / 'release.json', dist)
files = [dist / f'Fluent-IME-{version}{suffix}-Setup.dmg' for suffix in ['', '-Full']]
files += [dist / 'release.json', dist / 'release-full.json']
(dist / 'SHA256SUMS').write_text(''.join(hashlib.file_digest(file.open('rb'), 'sha256').hexdigest() + '  ' + file.name + '\n' for file in files))
for file in files[:2]: print(file.name, round(file.stat().st_size / 1024**2, 1), 'MiB')
