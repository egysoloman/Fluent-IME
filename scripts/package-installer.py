#!/usr/bin/env python3
"""Package a separate, double-click setup app. No Applications shortcut."""
from pathlib import Path
import subprocess, shutil, plistlib, json, hashlib, os
from products import PRODUCTS, installer_asset
root = Path(__file__).resolve().parents[1]
output = Path(os.environ.get('FLUENTIME_PACKAGE_DIR', root/'dist'))
name = os.environ.get('FLUENTIME_PRODUCT', 'pinyin'); product = PRODUCTS[name]
app = output/(product['app']+'.app')
setup = output/(product['installer']+'.app')
def run(*args): subprocess.run([str(a) for a in args], check=True)
run('codesign','--verify','--deep','--strict',app)
if setup.exists(): shutil.rmtree(setup)
contents = setup/'Contents'; resources = contents/'Resources'
(resources/'Payload').mkdir(parents=True); (contents/'MacOS').mkdir()
run('ditto',app,resources/'Payload'/app.name)
shutil.copy2(app/'Contents/MacOS/FluentIME',contents/'MacOS/FluentSetup')
shutil.copytree(app/'Contents/Frameworks',contents/'Frameworks')
for bundle in (app/'Contents/Resources').glob('*.bundle'): shutil.copytree(bundle, resources/bundle.name)
shutil.copy2(app/'Contents/Resources/AppIcon.icns',resources/'AppIcon.icns')
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
setup_info = {k:info[k] for k in ['CFBundleVersion','CFBundleShortVersionString','LSMinimumSystemVersion','FluentIMEEdition','FluentIMEProduct'] if k in info}
setup_info.update(CFBundleIdentifier=product['installer_id'], CFBundleExecutable='FluentSetup', CFBundleName=product['installer'], CFBundleDisplayName=product['installer'], CFBundlePackageType='APPL', CFBundleIconFile='AppIcon', NSHighResolutionCapable=True, NSPrincipalClass='NSApplication', CFBundleDevelopmentRegion='zh-Hans', CFBundleLocalizations=['zh-Hans','zh-Hant','en'])
(contents/'Info.plist').write_bytes(plistlib.dumps(setup_info))
for language, title in product['installer_titles'].items():
    folder = resources/(language+'.lproj'); folder.mkdir()
    (folder/'InfoPlist.strings').write_text('"CFBundleDisplayName" = '+json.dumps(title,ensure_ascii=False)+';\n')
for lib in (contents/'Frameworks').glob('*.dylib'): run('codesign','--force','--sign','-',lib)
run('codesign','--force','--sign','-',contents/'MacOS/FluentSetup')
run('codesign','--force','--sign','-',setup)
run('codesign','--verify','--deep','--strict',setup)
# A ZIP is useful on writable volumes: the extracted installer itself can go to Trash.
archive = output/(installer_asset(name, info["CFBundleShortVersionString"], info.get('FluentIMEEdition', 'lite'))[:-4] + '.zip')
if os.environ.get('FLUENTIME_SKIP_ZIP') != '1': run('ditto','-c','-k','--sequesterRsrc','--keepParent',setup,archive)
import cairosvg
cairosvg.svg2png(url=str(root/'Resources/Icons/InstallerBackground.svg'), write_to=str(root/'.build/installer-background.png'))
print('Installer:', setup)
