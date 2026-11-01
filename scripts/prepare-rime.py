#!/usr/bin/env python3
"""Fetch a pinned, relocatable Rime runtime; no system-wide library installation."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, tempfile, zipfile
root = Path(__file__).resolve().parents[1]
if os.environ.get('RIME_PREFIX'):
    prefix = Path(os.environ['RIME_PREFIX'])
    if not (prefix / 'include/rime_api.h').is_file() or not (prefix / 'lib/rime-plugins/librime-octagram.dylib').is_file():
        raise SystemExit('RIME_PREFIX needs headers, librime and the BSD Octagram plugin.')
    print('Using RIME_PREFIX: ' + str(prefix))
    raise SystemExit(0)
manifest = json.loads((root / 'Resources/Licenses/rime-runtime.json').read_text())
destination = root / '.build/rime-runtime'
def valid():
    return all((destination / name).is_file() and hashlib.sha256((destination / name).read_bytes()).hexdigest() == digest for name, digest in manifest['files'].items())
if not valid():
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='rime-download-') as temporary:
        temporary = Path(temporary); archive = temporary / 'runtime.zip'
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--proto', '=https', '--output', str(archive), manifest['url']], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['sha256']:
            raise SystemExit('Rime runtime checksum mismatch')
        with zipfile.ZipFile(archive) as contents:
            for item in contents.infolist():
                if Path(item.filename).is_absolute() or '..' in Path(item.filename).parts:
                    raise SystemExit('Invalid runtime archive path')
            contents.extractall(temporary / 'unpacked')
        if destination.exists(): shutil.rmtree(destination)
        shutil.move(str(temporary / 'unpacked'), destination)
    if not valid(): raise SystemExit('Rime runtime files failed verification')
print('Rime 1.17.0 + BSD Octagram: verified')
