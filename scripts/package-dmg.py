#!/usr/bin/env python3
from pathlib import Path
import plistlib, json, hashlib, os
import dmgbuild
from products import PRODUCTS, installer_asset, manifest_asset
root = Path(__file__).resolve().parents[1]
output = Path(os.environ.get('FLUENTIME_PACKAGE_DIR', root/'dist'))
name = os.environ.get('FLUENTIME_PRODUCT', 'pinyin'); product = PRODUCTS[name]
setup = output/(product['installer']+'.app')
info = plistlib.loads((setup/'Contents/Info.plist').read_bytes())
edition = info.get('FluentIMEEdition', 'lite')
target = output/installer_asset(name, info["CFBundleShortVersionString"], edition)
dmgbuild.build_dmg(str(target), product['installer'], settings={
    'files':[str(setup)], 'symlinks':{}, 'format':'UDZO',
    'window_rect':((180,160),(600,400)), 'icon_locations':{setup.name:(300,184)},
    'icon_size':128, 'text_size':14, 'background':str(root/'.build/installer-background.png'),
    'show_status_bar':False, 'show_tab_view':False, 'show_toolbar':False, 'show_pathbar':False,
    'default_view':'icon-view', 'include_icon_view_settings':True, 'arrange_by':None,
    'badge_icon':str(setup/'Contents/Resources/AppIcon.icns'),
})
report = json.loads((output/manifest_asset(name, 'lite')).read_text())
report['edition'] = edition
report['minimum_macos'] = info['LSMinimumSystemVersion']
report['architecture'] = 'arm64'
report['installer'] = {'bundle_identifier':product['installer_id'],'format':'double-click setup; no Applications copy','dmg':target.name,'dmg_sha256':hashlib.file_digest(target.open('rb'),'sha256').hexdigest()}
(output/manifest_asset(name, edition)).write_text(json.dumps(report,indent=2)+'\n')
print(target)
