#!/usr/bin/env python3
from pathlib import Path
import plistlib, json, hashlib, os
import dmgbuild
root = Path(__file__).resolve().parents[1]
output = Path(os.environ.get('FLUENTIME_PACKAGE_DIR', root/'dist'))
setup = output/'Fluent IME Setup.app'
info = plistlib.loads((setup/'Contents/Info.plist').read_bytes())
suffix = '-Full' if info['FluentIMEEdition'] == 'full' else ''
target = output/f'Fluent-IME-{info["CFBundleShortVersionString"]}{suffix}-Setup.dmg'
dmgbuild.build_dmg(str(target), 'Fluent IME Setup', settings={
    'files':[str(setup)], 'symlinks':{}, 'format':'UDZO',
    'window_rect':((180,160),(600,400)), 'icon_locations':{setup.name:(300,184)},
    'icon_size':128, 'text_size':14, 'background':str(root/'.build/installer-background.png'),
    'show_status_bar':False, 'show_tab_view':False, 'show_toolbar':False, 'show_pathbar':False,
    'default_view':'icon-view', 'include_icon_view_settings':True, 'arrange_by':None,
    'badge_icon':str(setup/'Contents/Resources/AppIcon.icns'),
})
report = json.loads((output/'release.json').read_text())
report['edition'] = info['FluentIMEEdition']
report['minimum_macos'] = info['LSMinimumSystemVersion']
report['architecture'] = 'arm64'
report['installer'] = {'bundle_identifier':'org.fluentime.installer','format':'double-click setup; no Applications copy','dmg':target.name,'dmg_sha256':hashlib.file_digest(target.open('rb'),'sha256').hexdigest()}
(output/('release-full.json' if suffix else 'release.json')).write_text(json.dumps(report,indent=2)+'\n')
print(target)
