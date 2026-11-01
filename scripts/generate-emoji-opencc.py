#!/usr/bin/env python3
"""Map whole Chinese candidate words to CLDR emoji alternatives through OpenCC.

The original word is always first. Ambiguous generic keywords are excluded;
up to three alternatives are retained, so a keyword cannot flood the menu.
No transliteration or replacement of substrings inside sentences is needed.
"""
from pathlib import Path
import argparse, collections, json, re

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
entries = json.loads((ROOT / 'Sources/FluentIMECore/Resources/emoji-search.json').read_text())
names, keywords = collections.defaultdict(list), collections.defaultdict(list)

def add(table, word, glyph):
    if re.fullmatch(r'[\u3400-\u9fff]{1,10}', word) and glyph not in table[word]:
        table[word].append(glyph)

for entry in entries:
    # Keep explicit emoji characters; punctuation from CLDR is not an emoji.
    if not any(ord(c) >= 0x1F000 or 0x2300 <= ord(c) <= 0x2BFF for c in entry['text']):
        continue
    add(names, entry['name'], entry['text'])
    for word in entry['keywords'].split():
        if len(word) >= 2:
            add(keywords, word, entry['text'])

preferred = {
    '粪便': ['💩'], '大便': ['💩'], '便便': ['💩'], '屎': ['💩'],
    '微笑': ['😊'], '笑哭': ['😂'], '大笑': ['😂'], '笑死': ['🤣'],
    '你好': ['👋'], '挥手': ['👋'], '开心': ['😁', '🥰'],
    '喜欢': ['😍'], '爱心': ['❤️', '💕'], '谢谢': ['🙏'], '点赞': ['👍'], '赞': ['👍'],
    '蛇': ['🐍'], '猫': ['🐱'], '狗': ['🐶'], '龙': ['🐉'], '酷': ['🆒', '😎'],
    '哭': ['😭'], '哭泣': ['😭'], '庆祝': ['🎉'], '玫瑰': ['🌹'],
    '苹果': ['🍎'], '咖啡': ['☕'], '奶茶': ['🧋'],
}
mapping = {}
for word in sorted(names.keys() | keywords.keys() | preferred.keys()):
    values = preferred.get(word, []) + names.get(word, [])
    if len(keywords.get(word, [])) <= 6:
        values += keywords.get(word, [])
    # A one-character candidate must not fill the first page with near-identical
    # faces and push out the existing emoji/kaomoji dictionary entries.
    unique = list(dict.fromkeys(values))[:1 if len(word) == 1 else 3]
    if unique:
        mapping[word] = unique

folder = ROOT / 'Resources/Rime/opencc'
folder.mkdir(exist_ok=True)
outputs = {
    'fluent_emoji.txt': ''.join(f'{word}\t{word} {" ".join(glyphs)}\n' for word, glyphs in mapping.items()),
    'fluent_emoji.json': json.dumps({
        'name': 'Fluent IME emoji alternatives (Unicode CLDR)',
        'conversion_chain': [{'dict': {'type': 'text', 'file': 'fluent_emoji.txt'}}],
    }, ensure_ascii=False, indent=2) + '\n',
}
for name, value in outputs.items():
    path = folder / name
    if args.check:
        if not path.exists() or path.read_text() != value:
            raise SystemExit(f'{path}: stale; run scripts/generate-emoji-opencc.py')
    else:
        path.write_text(value)
print(f'OpenCC emoji mappings: {len(mapping)} words, {len(set(g for values in mapping.values() for g in values))} emoji.')
