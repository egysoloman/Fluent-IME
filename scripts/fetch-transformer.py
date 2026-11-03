#!/usr/bin/env python3
"""Fetch precompiled Transformer model if source mlpackage is not in tree."""
from pathlib import Path
import os, subprocess, urllib.request, shutil

root = Path(__file__).resolve().parents[1]
models = root / 'Resources/Models'
if (models / 'ChineseContextScorer.mlpackage').exists():
    print('Local ChineseContextScorer.mlpackage present.')
    raise SystemExit(0)

if (models / 'ChineseContextScorer.mlmodelc').exists():
    print('ChineseContextScorer.mlmodelc already present.')
    raise SystemExit(0)

print('Fetching Transformer model from pinned release...')
dmg_url = 'https://github.com/egysoloman/Fluent-IME/releases/download/v0.7.3/Fluent-IME-0.7.3-Full-Setup.dmg'
dmg_path = root / '.build/transformer-source.dmg'
dmg_path.parent.mkdir(parents=True, exist_ok=True)
if not dmg_path.exists():
    urllib.request.urlretrieve(dmg_url, dmg_path)

mount_point = root / '.build/mnt-full'
mount_point.mkdir(parents=True, exist_ok=True)
try:
    subprocess.run(['hdiutil', 'attach', '-nobrowse', '-mountpoint', str(mount_point), str(dmg_path)], check=True)
    payload_models = mount_point / 'Fluent IME Setup.app/Contents/Resources/Payload/Fluent IME.app/Contents/Resources/Models'
    dest = root / 'Resources/Models/ChineseContextScorer.mlmodelc'
    if dest.exists(): shutil.rmtree(dest)
    shutil.copytree(payload_models / 'ChineseContextScorer.mlmodelc', dest)
    print('Extracted ChineseContextScorer.mlmodelc successfully.')
finally:
    subprocess.run(['hdiutil', 'detach', str(mount_point), '-force'], check=False)
