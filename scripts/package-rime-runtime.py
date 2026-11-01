#!/usr/bin/env python3
"""Maintainer-only runtime rebuild. Normal builds use prepare-rime.py.

Usage: python3 scripts/package-rime-runtime.py SDK_DIRECTORY BOOST_INCLUDE_DIRECTORY
SDK_DIRECTORY contains the verified upstream runtime + dependency archives extracted
at the same location. scripts/build-octagram.sh checks out the pinned source trees.
"""
from pathlib import Path
import hashlib, json, shutil, subprocess, sys, zipfile
root = Path(__file__).resolve().parents[1]
sdk = Path(sys.argv[1]).resolve(); boost = Path(sys.argv[2]).resolve()
stage = root / '.build/rime-runtime-package'; destination = root / '.build/rime-runtime'
if stage.exists(): shutil.rmtree(stage)
(stage / 'lib/rime-plugins').mkdir(parents=True)
shutil.copytree(sdk / 'dist/include', stage / 'include')
shutil.copy2(sdk / 'dist/lib/librime.1.17.0.dylib', stage / 'lib/librime.1.dylib')
revision = '57d18b9f58e5284bd891d559f6bdd16cf60341e9'
for repository, expected in [('librime-octagram', revision), ('librime-source', '33e78140250125871856cdc5b42ddc6a5fcd3cd4')]:
    assert subprocess.check_output(['git','-C',str(root/'Vendor'/repository),'rev-parse','HEAD'], text=True).strip() == expected
config = root / '.build/plugins/include/rime'; config.mkdir(parents=True, exist_ok=True)
(config / 'build_config.h').write_text('#define RIME_ENABLE_LOGGING\n#define RIME_VERSION "1.17.0"\n')
for arch in ['arm64','x86_64']:
    subprocess.run(['clang++','-arch',arch,'-std=c++17','-O2','-mmacosx-version-min=13.0','-DGLOG_USE_GLOG_EXPORT','-dynamiclib',
        *map(str, (root/'Vendor/librime-octagram/src').glob('*.cc')),
        '-I',str(config.parent),'-I',str(root/'Vendor/librime-source/src'),'-I',str(root/'Vendor/librime-source/include'),
        '-I',str(sdk/'include'),'-I',str(boost),'-L',str(sdk/'dist/lib'),'-lrime','-L',str(sdk/'lib'),'-lglog','-lyaml-cpp','-lmarisa',
        '-Wl,-install_name,@rpath/librime-octagram.dylib','-o',str(stage/f'octagram-{arch}.dylib')], check=True)
plugin = stage/'lib/rime-plugins/librime-octagram.dylib'
subprocess.run(['lipo','-create',str(stage/'octagram-arm64.dylib'),str(stage/'octagram-x86_64.dylib'),'-output',str(plugin)],check=True)
for arch in ['arm64','x86_64']: (stage/f'octagram-{arch}.dylib').unlink()
for library in [stage/'lib/librime.1.dylib',plugin]: subprocess.run(['codesign','--force','--sign','-',str(library)],check=True)
shutil.copy2(stage/'lib/librime.1.dylib',stage/'lib/librime.dylib')
notices = stage/'Licenses'; notices.mkdir()
for pattern in ['librime-LICENSE','librime-octagram-LICENSE.txt','glog-COPYING','yaml-cpp-LICENSE','leveldb-LICENSE','marisa-COPYING.md','opencc-LICENSE','*darts*','RapidJSON*','Boost*','UTF8*','X11*']:
    for file in (root/'Resources/Licenses').glob(pattern): shutil.copy2(file,notices/file.name)
shutil.copy2(root/'Vendor/librime-octagram/LICENSE',notices/'librime-octagram-LICENSE.txt')
metadata = {'rime_revision':'33e78140250125871856cdc5b42ddc6a5fcd3cd4','octagram_revision':revision,
    'runtime_archive_sha256':'11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850',
    'dependencies_archive_sha256':'dfe6047e87be271963d7466bd1a6e3d9e660c30e5e73e4bb94e8782c0a6ac8df',
    'source':'https://github.com/rime/librime/releases/tag/1.17.0', 'build_script':'scripts/package-rime-runtime.py',
    'boost_headers':'1.92.0','architectures':['arm64','x86_64'],'minimum_macos':'13.0',
    'scope':'Upstream Rime runtime; upstream plugins excluded. Octagram rebuilt from the specified BSD-licensed revision.'}
(stage/'provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
archive=root/'dist/RimeRuntime-1.17.0-macOS.zip'; archive.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as out:
    for file in sorted(stage.rglob('*')):
        if file.is_file():out.write(file,file.relative_to(stage))
manifest={'url':'https://github.com/egysoloman/Fluent-IME/releases/download/v0.6.1/'+archive.name,
          'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(), **metadata,
          'files':{str(f.relative_to(stage)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(stage.rglob('*')) if f.is_file()}}
(root/'Resources/Licenses/rime-runtime.json').write_text(json.dumps(manifest,indent=2)+'\n')
if destination.exists(): shutil.rmtree(destination)
shutil.copytree(stage,destination)
print(archive,archive.stat().st_size)
