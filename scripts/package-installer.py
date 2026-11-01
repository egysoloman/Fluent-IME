#!/usr/bin/env python3
"""Package a separate, double-click setup app. No Applications shortcut."""
from pathlib import Path
import subprocess, shutil, plistlib, json, hashlib
root = Path(__file__).resolve().parents[1]
app = root/'dist/Fluent IME.app'
setup = root/'dist/Fluent IME Setup.app'
def run(*args): subprocess.run([str(a) for a in args], check=True)
run('codesign','--verify','--deep','--strict',app)
if setup.exists(): shutil.rmtree(setup)
contents = setup/'Contents'; resources = contents/'Resources'
(resources/'Payload').mkdir(parents=True); (contents/'MacOS').mkdir()
run('ditto',app,resources/'Payload/Fluent IME.app')
shutil.copy2(app/'Contents/MacOS/FluentIME',contents/'MacOS/FluentSetup')
shutil.copytree(app/'Contents/Frameworks',contents/'Frameworks')
for bundle in (app/'Contents/Resources').glob('*.bundle'): shutil.copytree(bundle, resources/bundle.name)
shutil.copy2(app/'Contents/Resources/AppIcon.icns',resources/'AppIcon.icns')
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
setup_info = {k:info[k] for k in ['CFBundleVersion','CFBundleShortVersionString','LSMinimumSystemVersion']}
setup_info.update(CFBundleIdentifier='org.fluentime.installer', CFBundleExecutable='FluentSetup', CFBundleName='Fluent IME Setup', CFBundleDisplayName='Fluent IME Setup', CFBundlePackageType='APPL', CFBundleIconFile='AppIcon', NSHighResolutionCapable=True, NSPrincipalClass='NSApplication', CFBundleDevelopmentRegion='zh-Hans', CFBundleLocalizations=['zh-Hans','zh-Hant','en'])
(contents/'Info.plist').write_bytes(plistlib.dumps(setup_info))
for language, title in [('zh-Hans','安装 Fluent 输入法'),('zh-Hant','安裝 Fluent 輸入法'),('en','Fluent IME Setup')]:
    folder = resources/(language+'.lproj'); folder.mkdir()
    (folder/'InfoPlist.strings').write_text('"CFBundleDisplayName" = '+json.dumps(title,ensure_ascii=False)+';\n')
for lib in (contents/'Frameworks').glob('*.dylib'): run('codesign','--force','--sign','-',lib)
run('codesign','--force','--sign','-',contents/'MacOS/FluentSetup')
run('codesign','--force','--sign','-',setup)
run('codesign','--verify','--deep','--strict',setup)
# A ZIP is useful on writable volumes: the extracted installer itself can go to Trash.
archive = root/f'dist/Fluent-IME-{info["CFBundleShortVersionString"]}-Setup.zip'
run('ditto','-c','-k','--sequesterRsrc','--keepParent',setup,archive)
import cairosvg
cairosvg.svg2png(url=str(root/'Resources/Icons/InstallerBackground.svg'), write_to=str(root/'.build/installer-background.png'))
print('Installer:', setup)
