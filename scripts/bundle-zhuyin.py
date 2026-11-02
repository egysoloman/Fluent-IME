#!/usr/bin/env python3
"""Assemble Fluent 注音 (Fluent Zhuyin.app) from the verified Fluent 拼音 app.

Same executable and frameworks; its own bundle identity, single input source, Rime
data (Resources/Zhuyin/Rime), maintenance app, licenses and release manifest.
"""
from pathlib import Path
import hashlib, json, plistlib, shutil, subprocess, sys
from products import PRODUCTS

root = Path(__file__).resolve().parents[1]
source = root / 'dist/Fluent IME.app'
output = root / 'dist/zhuyin'
product = PRODUCTS['zhuyin']
app = output / (product['app'] + '.app')
resources = app / 'Contents/Resources'
def run(*args): subprocess.run([str(arg) for arg in args], check=True)

run('codesign', '--verify', '--deep', '--strict', source)
output.mkdir(parents=True, exist_ok=True)
if app.exists(): shutil.rmtree(app)
run('ditto', source, app)
for path in [resources / 'Rime', resources / 'Models', app / 'Contents/Library' / (PRODUCTS['pinyin']['maintenance'] + '.app')]:
    shutil.rmtree(path, ignore_errors=True)

info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info.pop('FluentIMEEdition', None)  # one edition; the Transformer is Pinyin-only
# Every identity key must be Zhuyin's own, or the system merges the two input methods.
info.update(CFBundleIdentifier=product['bundle_id'], CFBundleName=product['names']['zh-Hans'], CFBundleDisplayName=product['names']['zh-Hans'],
            InputMethodConnectionName=product['connection'], FluentIMEProduct='zhuyin',
            TISInputSourceID=product['bundle_id'], tsInputMethodIconFileKey='InputMenuIconBopomofo.pdf')
modes = info['ComponentInputModeDict']['tsInputModeListKey']
mode = dict(modes['org.fluentime.inputmethod.FluentIME.Hans'])
mode.update(TISInputSourceID=product['source_id'], TISIntendedLanguage='zh-Hant', tsInputModeCharacterRepertoireKey=['Hant'],
            tsInputModeMenuIconFileKey='InputMenuIconBopomofo.pdf', tsInputModeAlternateMenuIconFileKey='InputMenuIconBopomofo.pdf',
            tsInputModePaletteIconFileKey='InputMenuIconBopomofo.pdf')
info['ComponentInputModeDict'] = {'tsInputModeListKey': {product['source_id']: mode}, 'tsVisibleInputModeOrderedArrayKey': [product['source_id']]}
info_path.write_bytes(plistlib.dumps(info))
for locale, name in product['names'].items():
    (resources / f'{locale}.lproj/InfoPlist.strings').write_text(
        f'"CFBundleName" = "{name}";\n"CFBundleDisplayName" = "{name}";\n"{product["source_id"]}" = "{name}";\n')

shutil.copytree(root / 'Resources/Zhuyin/Rime', resources / 'Rime')
licenses = resources / 'Licenses'
for notice in (root / 'Resources/Zhuyin/Licenses').glob('*-LICENSE'):
    shutil.copy2(notice, licenses / notice.name)
pinyin_only = {'Wanxiang grammar', 'Wanxiang dictionary', 'rime-pinyin-simp (legacy data)', 'HFL Chinese RoBERTa-wwm-ext'}
components = [item for item in json.loads((licenses / 'components.json').read_text()) if item['name'] not in pinyin_only]
components += json.loads((root / 'Resources/Zhuyin/Licenses/zhuyin-components.json').read_text())
(licenses / 'components.json').write_text(json.dumps(components, indent=2, ensure_ascii=False) + '\n')
shutil.copy2(root / 'Resources/Zhuyin/Licenses/opencc-data-zhuyin.json', licenses / 'opencc-data.json')
for name in ['wanxiang-dictionary-conversion.json', 'Wanxiang-CC-BY-4.0.txt', 'Wanxiang-Dictionary-LICENSE.txt', 'rime-pinyin-simp-LICENSE', 'rime-pinyin-simp-AUTHORS']:
    (licenses / name).unlink(missing_ok=True)

executable = app / 'Contents/MacOS/FluentIME'
run('codesign', '--force', '--sign', '-', executable)
# Precompile the Terra Pinyin table and Zhuyin prism the same way as Pinyin's data.
deployment = root / '.build/rime-deployment-zhuyin'
if deployment.exists(): shutil.rmtree(deployment)
deployment.mkdir(parents=True)
run(executable, '--deploy', resources / 'Rime', deployment)
shutil.copytree(deployment / 'build', resources / 'Rime/build')
(resources / 'Rime/build/default.yaml').unlink()
run(sys.executable, root / 'scripts/package-maintenance.py', app)
run(sys.executable, root / 'scripts/audit-distribution.py', app)
run('codesign', '--force', '--sign', '-', executable)
run('codesign', '--force', '--sign', '-', app)
run('codesign', '--verify', '--deep', '--strict', app)
(output / 'release-zhuyin.json').write_text(json.dumps({
    'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
    'executable_sha256': hashlib.file_digest(executable.open('rb'), 'sha256').hexdigest(),
    'signing': 'ad-hoc', 'notarized': False, 'product': 'zhuyin'
}, indent=2) + '\n')
print('Zhuyin app:', app)
