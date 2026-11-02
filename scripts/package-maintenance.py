#!/usr/bin/env python3
"""Embed the independently launchable maintenance app, without models or dictionaries."""
from pathlib import Path
import json, plistlib, shutil, subprocess, sys
from products import PRODUCTS, product_of

app = Path(sys.argv[1]).resolve()
product = PRODUCTS[product_of(app)]
helper = app / 'Contents/Library' / (product['maintenance'] + '.app')
if helper.exists():
    shutil.rmtree(helper)
contents = helper / 'Contents'
resources = contents / 'Resources'
(contents / 'MacOS').mkdir(parents=True)
resources.mkdir()
executable = contents / 'MacOS/FluentMaintenance'
shutil.copy2(app / 'Contents/MacOS/FluentIME', executable)
shutil.copytree(app / 'Contents/Frameworks', contents / 'Frameworks')
for bundle in (app / 'Contents/Resources').glob('*.bundle'):
    shutil.copytree(bundle, resources / bundle.name)
shutil.copy2(app / 'Contents/Resources/AppIcon.icns', resources / 'AppIcon.icns')
shutil.copytree(app / 'Contents/Resources/Licenses', resources / 'Licenses')
original = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
info = {key: original[key] for key in ['CFBundleVersion', 'CFBundleShortVersionString', 'LSMinimumSystemVersion', 'FluentIMEEdition', 'FluentIMEProduct'] if key in original}
info.update(CFBundleIdentifier=product['maintenance_id'], CFBundleExecutable='FluentMaintenance',
            CFBundleName=product['maintenance'], CFBundleDisplayName=product['maintenance'],
            CFBundlePackageType='APPL', CFBundleIconFile='AppIcon', NSHighResolutionCapable=True,
            NSPrincipalClass='NSApplication', CFBundleDevelopmentRegion='zh-Hans', CFBundleLocalizations=['zh-Hans', 'zh-Hant', 'en'])
(contents / 'Info.plist').write_bytes(plistlib.dumps(info))
for locale, title in product['maintenance_titles'].items():
    folder = resources / (locale + '.lproj'); folder.mkdir()
    (folder / 'InfoPlist.strings').write_text('"CFBundleDisplayName" = ' + json.dumps(title, ensure_ascii=False) + ';\n')
def sign(path):
    subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)
for library in (contents / 'Frameworks').rglob('*.dylib'):
    sign(library)
sign(executable)
sign(helper)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(helper)], check=True)
print('Maintenance app:', helper)
