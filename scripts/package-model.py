#!/usr/bin/env python3
"""Release the optional Core ML scorer independently of the application."""
from pathlib import Path
import hashlib, json, shutil, subprocess, zipfile

root = Path(__file__).resolve().parents[1]
dist = root / 'dist'
source = dist / 'Fluent IME.app/Contents/Resources/Models'
target = dist / 'Fluent-IME-Transformer'
if target.exists(): shutil.rmtree(target)
shutil.copytree(source, target)
assert (target / 'CHINESE-CONTEXT-LICENSE.txt').exists()
contract = {
    'format': 'fluent-ime-context-scorer', 'version': 1,
    'model': 'ChineseContextScorer.mlmodelc', 'vocabulary': 'chinese-context-vocab.txt',
    'inputs': {'input_ids': ['int32', [8, 32]], 'attention_mask': ['int32', [8, 32]],
               'positions': ['int32', [8]], 'targets': ['int32', [8]]},
    'output': {'token_scores': ['float32', [8]]},
    'tokenizer': 'BERT WordPiece; LF-separated vocabulary; PAD ID 0',
    'scoring': 'One masked token per row; log probability for targets at positions',
}
(target / 'interface.json').write_text(json.dumps(contract, indent=2) + '\n')
archive = dist / 'Fluent-IME-Transformer.zip'
expected = {str(path.relative_to(dist)): path for path in target.rglob('*') if path.is_file()}
unchanged = False
if archive.exists():
    with zipfile.ZipFile(archive) as existing:
        unchanged = {name for name in existing.namelist() if not name.endswith('/')} == set(expected)
        if unchanged:
            for name, path in expected.items():
                with existing.open(name) as stored, path.open('rb') as source_file:
                    if hashlib.file_digest(stored, 'sha256').digest() != hashlib.file_digest(source_file, 'sha256').digest():
                        unchanged = False
                        break
if not unchanged:
    archive.unlink(missing_ok=True)
    subprocess.run(['ditto', '-c', '-k', '--norsrc', '--keepParent', str(target), str(archive)], check=True)
sums = dist / 'SHA256SUMS'
previous = [line for line in sums.read_text().splitlines() if not line.endswith('  ' + archive.name)] if sums.exists() else []
sums.write_text('\n'.join(previous + [hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest() + '  ' + archive.name]) + '\n')
print(archive.name, round(archive.stat().st_size / 1024**2, 1), 'MiB')
