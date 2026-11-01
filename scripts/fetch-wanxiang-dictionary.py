#!/usr/bin/env python3
"""Pin, verify and adapt Wanxiang word data; never download during typing."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib, json, re, unicodedata, urllib.request

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Vendor/wanxiang-dictionary'
META = json.loads((SOURCE / 'sources.json').read_text())

def fetch(item):
    target = SOURCE / item['path']
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        url = f"https://raw.githubusercontent.com/amzxyz/rime-wanxiang/{META['revision']}/{item['path']}"
        temporary = target.with_suffix('.download')
        urllib.request.urlretrieve(url, temporary)
        temporary.replace(target)
    data = target.read_bytes()
    blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    if len(data) != item['size'] or blob != item['git_blob_sha1']:
        raise RuntimeError(f'Pinned dictionary checksum mismatch: {target}')
    return data.decode('utf-8-sig')

def spelling(text):
    # Decompose tones while preserving ü as Rime's v (including ǖ/ǘ/ǚ/ǜ).
    text = unicodedata.normalize('NFD', text).replace('u\u0308', 'v')
    return ''.join(c for c in text if unicodedata.category(c) != 'Mn')

def main():
    entries = {}
    invalid_weights = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        for text in pool.map(fetch, META['files']):
            body = False
            for line in text.splitlines():
                if line.strip() == '...': body = True; continue
                if not body or not line or line.startswith('#'): continue
                fields = line.split('\t')
                if len(fields) < 2: raise ValueError(f'Malformed dictionary row: {line!r}')
                word, code = fields[0], spelling(fields[1])
                if not re.fullmatch(r'[a-z]+(?: [a-z]+)*', code):
                    raise ValueError(f'Unsupported spelling: {fields[1]!r} → {code!r}')
                raw_weight = fields[2] if len(fields) >= 3 else ''
                if raw_weight and not raw_weight.isdecimal():
                    invalid_weights.append({'word': word, 'original_weight': raw_weight, 'replacement': 0})
                weight = int(raw_weight) if raw_weight.isdecimal() else 0
                pair = (word, code)
                entries[pair] = max(weight, entries.get(pair, 0))
    target = ROOT / 'Resources/Rime/wanxiang_fluent.dict.yaml'
    with target.open('w') as out:
        out.write('# Adapted from amzxyz/rime-wanxiang, CC-BY-4.0.\n')
        out.write(f"# Source revision: {META['revision']}\n")
        out.write('# Changes: tone marks removed; duplicate spellings merged by max weight.\n')
        out.write('# Attribution and original license: Contents/Resources/Licenses.\n')
        out.write('---\nname: wanxiang_fluent\nversion: "2026.10.31"\nsort: by_weight\nuse_preset_vocabulary: false\n...\n')
        for (word, code), weight in entries.items(): out.write(f'{word}\t{code}\t{weight}\n')
    report = {**META, 'entries': len(entries), 'invalid_weights': invalid_weights, 'output': target.name,
              'output_sha256': hashlib.sha256(target.read_bytes()).hexdigest()}
    (SOURCE / 'conversion.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(f"Verified and adapted {len(entries):,} Wanxiang entries.")

if __name__ == '__main__': main()
