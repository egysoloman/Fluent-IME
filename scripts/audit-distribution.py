#!/usr/bin/env python3
"""Validate the assembled artifact, not just the source dependency declaration."""
from pathlib import Path
import hashlib, json, subprocess, sys
app = Path(sys.argv[1]).resolve()
resources = app / 'Contents/Resources'
licenses = resources / 'Licenses'
components = json.loads((licenses / 'components.json').read_text())
components = [item for item in components if 'present_if' not in item or (resources / item['present_if']).exists()]
(licenses / 'components.json').write_text(json.dumps(components, indent=2, ensure_ascii=False) + '\n')
errors = []
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
for binary in [app / 'Contents/MacOS/FluentIME', *(app / 'Contents/Frameworks').rglob('*.dylib')]:
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
report = {'scope': 'Artifact inventory and notice completeness; not a legal opinion or training-data rights clearance.',
          'fonts_bundled': bool(fonts), 'libraries': libraries, 'components': components, 'errors': errors,
          'release_status': 'Local ad-hoc build; Developer ID signing and notarization still required for public distribution.'}
(licenses / 'distribution-audit.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
if errors: raise SystemExit('\n'.join(errors))
print(f'Distribution inventory passed: {len(libraries)-1} dylibs, {len(components)} components, no bundled fonts or user databases.')
