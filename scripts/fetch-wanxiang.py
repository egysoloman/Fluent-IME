#!/usr/bin/env python3
"""Fetch the pinned upstream grammar model, verify before bundling."""
from pathlib import Path
import hashlib, json, urllib.request
root=Path(__file__).resolve().parent.parent
folder=root/'Vendor/wanxiang';folder.mkdir(parents=True,exist_ok=True)
meta=json.loads((folder/'model.json').read_text())
model=folder/'wanxiang-lts-zh-hans.gram'
if not model.exists():
    temporary=model.with_suffix('.download')
    urllib.request.urlretrieve('https://github.com/amzxyz/rime-wanxiang-data/releases/download/LTS/'+model.name,temporary)
    if hashlib.file_digest(temporary.open('rb'),'sha256').hexdigest()!=meta['sha256']:
        raise SystemExit('Upstream LTS changed; verify and pin the new release before updating.')
    temporary.replace(model)
with model.open('rb') as f:
    if hashlib.file_digest(f,'sha256').hexdigest()!=meta['sha256']: raise SystemExit('Wanxiang checksum mismatch')
print('Wanxiang grammar SHA-256 verified.')
