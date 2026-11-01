#!/usr/bin/env python3
"""Extract the verified upstream commit, never a live working tree."""
from pathlib import Path
import hashlib,json,os,subprocess,tarfile
root=Path(__file__).resolve().parent.parent
sha='5811513d9820193c3c46ae8ee89b763641fa6686'
dest=root/'.build/dependencies/fluentkit-5811513/WinUI-macOS'
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
(root/'Resources/Licenses/fluentkit-source.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('FluentKit pinned and verified: '+sha)
