#!/usr/bin/env python3
"""Generate offline emoji names/keywords from the pinned Unicode CLDR release."""
from pathlib import Path
import hashlib, json, urllib.request, xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parent.parent
REVISION = 'acd6d88ae493633240e19a87a721076a8a75c310'
FILES = {'en': 'fbf0e693ebafbae2dedf90f97b7ad141769941d9', 'zh': '45d9335f78ce4fef645303fc4b4fb10416caaf64'}
folder = ROOT / 'Vendor/cldr'; folder.mkdir(exist_ok=True)
entries = {}
for locale, expected in FILES.items():
    path = folder / (locale + '.xml')
    if not path.exists():
        urllib.request.urlretrieve(f'https://raw.githubusercontent.com/unicode-org/cldr/{REVISION}/common/annotations/{locale}.xml', path)
    data = path.read_bytes()
    assert hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == expected
    for annotation in ET.fromstring(data).findall('.//annotation'):
        glyph = annotation.attrib['cp']
        # CLDR also annotates punctuation; keep this data in the emoji tab only.
        if not any(ord(c) >= 0x2300 for c in glyph): continue
        entry = entries.setdefault(glyph, {'text': glyph, 'name': '', 'keywords': ''})
        value = annotation.text or ''
        if value in ('↑↑↑', '∅∅∅'): continue
        if annotation.attrib.get('type') == 'tts' and (locale == 'zh' or not entry['name']): entry['name'] = value
        entry['keywords'] += ' ' + value.replace(' | ', ' ')
target = ROOT / 'Sources/FluentIMECore/Resources'; target.mkdir(exist_ok=True)
(target / 'emoji-search.json').write_text(json.dumps(list(entries.values()), ensure_ascii=False, separators=(',', ':')) + '\n')
(folder / 'sources.json').write_text(json.dumps({'repository': 'https://github.com/unicode-org/cldr', 'revision': REVISION, 'license': 'Unicode-3.0', 'files': FILES, 'entries': len(entries), 'changes': 'Extracted zh/en emoji annotations into JSON; XML metadata omitted.'}, indent=2) + '\n')
print(f'Generated {len(entries)} offline emoji search records.')
