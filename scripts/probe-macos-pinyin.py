#!/usr/bin/env python3
"""Isolated macOS 27 private-API experiment. Never installs a system/Rime dictionary."""
import json
import platform
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
if platform.system() != 'Darwin' or platform.mac_ver()[0].split('.')[0] != '27':
    raise SystemExit('This private ABI was only verified on macOS 27.2; no query attempted.')
out = (Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'artifacts/macos-query-probe').resolve()
out.mkdir(parents=True, exist_ok=True)
exe = out / 'MecabraProbe'
subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', str(root / 'Experiments/MecabraProbe.m'), '-o', str(exe)], check=True)
result = subprocess.run([str(exe)], capture_output=True, check=True, timeout=15)
rows = json.loads(result.stdout)
expected = {'nihao': ('你好', 'ni hao'), 'zhongguo': ('中国', 'zhong guo'), 'beijing': ('北京', 'bei jing')}
entries = []
for row in rows:
    word, code = expected[row['input']]
    if not row['candidates'] or row['candidates'][0]['text'] != word:
        raise SystemExit('Known-query validation failed; refusing to export.')
    for candidate in row['candidates']:
        text = candidate['text']
        if text and candidate['reading'] == row['input'] and all('\u3400' <= ch <= '\u9fff' for ch in text):
            entries.append(f'{text}\t{code}\t1')
(out / 'queries.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
header = '# Three queried spellings only. Weight 1 is a placeholder, not Apple frequency.\n---\nname: macos_probe\nversion: "2026.11.01"\nsort: original\n...\n\n'
(out / 'macos_probe.dict.yaml').write_text(header + '\n'.join(entries) + '\n')
print(f'Validated 3 spellings; exported {len(entries)} sample entries to {out}.')
