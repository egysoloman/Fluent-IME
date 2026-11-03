"""Identities of the two input methods built from this project; mirrors FluentProduct.swift."""
import plistlib
from pathlib import Path

PRODUCTS = {
    'pinyin': {
        'bundle_id': 'org.fluentime.inputmethod.FluentIME', 'app': 'Fluent IME', 'asset': 'Fluent-IME',
        'installer_id': 'org.fluentime.installer', 'installer': 'Fluent IME Setup',
        'maintenance_id': 'org.fluentime.maintenance', 'maintenance': 'Fluent IME Maintenance',
        'installer_titles': {'zh-Hans': '安装 Fluent 输入法', 'zh-Hant': '安裝 Fluent 輸入法', 'en': 'Fluent IME Setup'},
        'maintenance_titles': {'zh-Hans': 'Fluent IME 维护', 'zh-Hant': 'Fluent IME 維護', 'en': 'Fluent IME Maintenance'},
    },
    'zhuyin': {
        'bundle_id': 'org.fluentime.inputmethod.FluentZhuyin', 'app': 'Fluent Zhuyin', 'asset': 'Fluent-Zhuyin',
        'installer_id': 'org.fluentime.zhuyin.installer', 'installer': 'Fluent Zhuyin Setup',
        'maintenance_id': 'org.fluentime.zhuyin.maintenance', 'maintenance': 'Fluent Zhuyin Maintenance',
        'source_id': 'org.fluentime.inputmethod.FluentZhuyin.Bopomofo', 'connection': 'FluentZhuyin_Connection',
        'names': {'zh-Hans': 'Fluent 注音', 'zh-Hant': 'Fluent 注音', 'en': 'Fluent Zhuyin'},
        'installer_titles': {'zh-Hans': '安装 Fluent 注音', 'zh-Hant': '安裝 Fluent 注音', 'en': 'Fluent Zhuyin Setup'},
        'maintenance_titles': {'zh-Hans': 'Fluent 注音维护', 'zh-Hant': 'Fluent 注音維護', 'en': 'Fluent Zhuyin Maintenance'},
    },
}

def product_of(app: Path) -> str:
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    return info.get('FluentIMEProduct', 'pinyin')

def installer_asset(product: str, version: str, edition: str) -> str:
    if product == 'zhuyin': return f'Fluent-Zhuyin-{version}-Setup.dmg'
    return f'Fluent-IME-{version}{"-Full" if edition == "full" else "-Update" if edition == "update" else ""}-Setup.dmg'

def manifest_asset(product: str, edition: str) -> str:
    if product == 'zhuyin': return 'release-zhuyin.json'
    return {'full': 'release-full.json', 'update': 'release-update.json'}.get(edition, 'release.json')
