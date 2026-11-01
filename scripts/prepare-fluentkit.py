#!/usr/bin/env python3
"""Prepare the pinned upstream commit or record an explicit developer override."""
from pathlib import Path
import hashlib,json,os,subprocess,sys,tarfile
root=Path(__file__).resolve().parent.parent
sha='01c8e66094df7ca013833ffce8a8649fa6902399'
dest=root/'.build/dependencies/fluentkit-01c8e66/WinUI-macOS'
manifest_path=root/'Resources/Licenses/fluentkit-source.json'
override=os.environ.get('FLUENTKIT_PATH')
if override:
    supplied=Path(override).expanduser().resolve()
    if not (supplied/'Package.swift').is_file():
        raise SystemExit('FLUENTKIT_PATH must contain a Swift package: '+str(supplied))
    manifest={'revision':None,'archive_sha256':None,'snapshot':'developer override',
              'scope':'FLUENTKIT_PATH supplied by the developer; not verified against the pinned commit.'}
    manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
    print('FluentKit developer override: '+str(supplied))
    sys.exit(0)
archive=dest.parent/'source.tar'
source=Path(os.environ.get('FLUENTKIT_SOURCE',str(Path.home()/'Documents/WinUI-macOS')))
if not (dest/'.fluentime-revision').is_file():
    dest.mkdir(parents=True,exist_ok=True)
    if not source.is_dir():
        source=dest.parent/'upstream'
        source.mkdir(parents=True,exist_ok=True)
        subprocess.run(['git','-C',str(source),'init','-q'],check=True)
        subprocess.run(['git','-C',str(source),'fetch','--depth','1','https://github.com/egysoloman/FluentKit.git',sha],check=True)
    subprocess.run(['git','-C',str(source),'archive','--format=tar','--output='+str(archive),sha],check=True)
    with tarfile.open(archive) as tar:tar.extractall(dest,filter='data')
    (dest/'.fluentime-revision').write_text(sha+'\n')
assert (dest/'.fluentime-revision').read_text().strip()==sha
# Compare the extracted source to the immutable commit archive on every build.
with tarfile.open(archive) as tar:
    for member in tar:
        if member.isfile():
            assert hashlib.sha256((dest/member.name).read_bytes()).digest()==hashlib.sha256(tar.extractfile(member).read()).digest(),member.name
manifest={'revision':sha,'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'snapshot':str(dest.relative_to(root)),'scope':'Committed source only; excludes later working-tree changes.'}
manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
print('FluentKit pinned and verified: '+sha)
