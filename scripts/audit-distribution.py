#!/usr/bin/env python3
"""Validate the assembled artifact, not just the source dependency declaration."""
from pathlib import Path
import hashlib, json, plistlib, subprocess, sys
from products import PRODUCTS, product_of
app = Path(sys.argv[1]).resolve()
product_name = product_of(app); product = PRODUCTS[product_name]
resources = app / 'Contents/Resources'
licenses = resources / 'Licenses'
components = json.loads((licenses / 'components.json').read_text())
components = [item for item in components if 'present_if' not in item or (resources / item['present_if']).exists()]
(licenses / 'components.json').write_text(json.dumps(components, indent=2, ensure_ascii=False) + '\n')
errors = []
maintenance = app / 'Contents/Library' / (product['maintenance'] + '.app')
maintenance_executable = maintenance / 'Contents/MacOS/FluentMaintenance'
if not maintenance_executable.is_file():
    errors.append('Maintenance application is missing')
else:
    app_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    helper_info = plistlib.loads((maintenance / 'Contents/Info.plist').read_bytes())
    if helper_info.get('CFBundleIdentifier') != product['maintenance_id']:
        errors.append('Wrong maintenance application identifier')
    for key in ['CFBundleVersion', 'CFBundleShortVersionString', 'FluentIMEEdition', 'FluentIMEProduct']:
        if helper_info.get(key) != app_info.get(key): errors.append('Maintenance metadata mismatch: ' + key)
    for name in ['Models', 'Rime', 'Payload']:
        if (maintenance / 'Contents/Resources' / name).exists(): errors.append('Maintenance must not duplicate ' + name)
fonts = []
for component in components:
    for notice in component['notices']:
        if not (resources / notice).is_file(): errors.append('Missing notice: ' + notice)
font_extensions = {'.ttf','.otf','.ttc','.otc','.woff','.woff2','.dfont'}
for path in app.rglob('*'):
    if path.suffix.lower() in font_extensions:
        fonts.append(str(path.relative_to(app)))
        errors.append('Unreviewed bundled font: ' + fonts[-1])
    if path.name.endswith('.userdb') or path.name in {'ClipboardHistory.json','pinned.aesgcm','dynamic-phrases.dat'}:
        errors.append('Private user/system data in artifact: ' + str(path.relative_to(app)))
libraries = []
known = [prefix for component in components for prefix in component.get('libraries', [])]
for binary in [app / 'Contents/MacOS/FluentIME', *([maintenance_executable] if maintenance_executable.is_file() else []), *app.rglob('*.dylib')]:
    if binary.suffix == '.dylib' and not any(binary.name.startswith(prefix) for prefix in known):
        errors.append('Unreviewed library: ' + binary.name)
    linked = subprocess.check_output(['otool','-L',str(binary)], text=True)
    if '/opt/homebrew/' in linked or '/usr/local/' in linked: errors.append('Non-relocatable dependency: ' + binary.name)
    identity = {'file': str(binary.relative_to(app))}
    if binary.suffix == '.dylib':
        identity['sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    else:
        # The outer app signature changes the main executable and seals this
        # report. A full hash here would be circular; retain the link UUID and
        # put the final executable hash in the external release manifest.
        identity['build_uuid'] = subprocess.check_output(['dwarfdump', '--uuid', str(binary)], text=True).split()[1]
    libraries.append(identity)
if product_name == 'pinyin':
    plugin = app / 'Contents/Frameworks/rime-plugins/librime-octagram.dylib'
    if not plugin.is_file(): errors.append('Wanxiang grammar plugin is missing')
    for name in ['wanxiang-lts-zh-hans.gram','wanxiang_fluent.dict.yaml']:
        if not (resources / 'Rime' / name).is_file(): errors.append('Missing word/model data: ' + name)
    model = resources / 'Rime/wanxiang-lts-zh-hans.gram'
    if model.is_file() and hashlib.file_digest(model.open('rb'),'sha256').hexdigest() != 'e34500ab44626dc039a0641792ecba98ab63307646eb3d29186be56608ffe094':
        errors.append('Grammar model checksum mismatch')
    conversion = json.loads((licenses / 'wanxiang-dictionary-conversion.json').read_text())
    opencc_data = licenses / 'opencc-data.json'
    if not opencc_data.is_file():
        errors.append('OpenCC conversion-data inventory is missing')
    else:
        for name, expected in json.loads(opencc_data.read_text())['files'].items():
            data = resources / 'Rime/opencc' / name
            if not data.is_file() or hashlib.sha256(data.read_bytes()).hexdigest() != expected:
                errors.append('OpenCC conversion dictionary checksum mismatch: ' + name)
    dictionary = resources / 'Rime/wanxiang_fluent.dict.yaml'
    if dictionary.is_file() and hashlib.file_digest(dictionary.open('rb'),'sha256').hexdigest() != conversion['output_sha256']:
        errors.append('Adapted dictionary checksum mismatch')
else:
    # Fluent 注音: toned Terra Pinyin dictionary, rime-bopomofo spelling rules and
    # the Traditional-to-Simplified conversion, all precompiled.
    for name in ['terra_pinyin.dict.yaml', 'essay.txt', 'zhuyin.yaml', 'fluent_bopomofo.schema.yaml', 'build/fluent_bopomofo.prism.bin', 'build/terra_pinyin.table.bin']:
        if not (resources / 'Rime' / name).is_file(): errors.append('Missing Zhuyin data: ' + name)
    for name in ['wanxiang_fluent.dict.yaml', 'fluent_pinyin.schema.yaml', 'Models']:
        if (resources / 'Rime' / name).exists() or (resources / name).exists(): errors.append('Pinyin data in Zhuyin artifact: ' + name)
    opencc_data = licenses / 'opencc-data.json'
    for name, expected in json.loads(opencc_data.read_text())['files'].items():
        data = resources / 'Rime/opencc' / name
        if not data.is_file() or hashlib.sha256(data.read_bytes()).hexdigest() != expected:
            errors.append('OpenCC conversion dictionary checksum mismatch: ' + name)
report = {'scope': 'Artifact inventory and notice completeness; not a legal opinion or training-data rights clearance.',
          'fonts_bundled': bool(fonts), 'libraries': libraries, 'components': components, 'errors': errors,
          'release_status': 'Local ad-hoc build; Developer ID signing and notarization still required for public distribution.'}
(licenses / 'distribution-audit.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
if errors: raise SystemExit('\n'.join(errors))
print(f'Distribution inventory passed: {len(libraries)} binaries, {len(components)} components, no bundled fonts or user databases.')
