#!/usr/bin/env python3
"""Read-only inventory of Apple's SYSTEM linguistic assets, not personal learning data."""
import json
import platform
import plistlib
import struct
from pathlib import Path

root = Path('/System/Library/LinguisticData/RequiredAssets_zh-Hans.bundle/AssetData')
report = {'macOS': platform.mac_ver()[0], 'system_directory': str(root), 'files': []}
for name in ['sys.dic', 'reverse.dic', 'syllable.dat', 'Chinese.lm/lm.dat']:
    path = root / name
    if not path.is_file():
        report['files'].append({'name': name, 'present': False})
        continue
    data = path.read_bytes()
    item = {'name': name, 'bytes': len(data), 'header_hex': data[:32].hex()}
    if name == 'sys.dic':
        item['first_u32_le'] = struct.unpack_from('<I', data)[0]
        item['utf16le_sample_offsets'] = {word: data.find(word.encode('utf-16le')) for word in ['中国', '北京', '你好']}
    report['files'].append(item)
params = root / 'Chinese.lm/params.dat'
if params.is_file():
    data = plistlib.loads(params.read_bytes())
    report['Chinese_model_parameters'] = {key: data.get(key) for key in ['DynamicModelOrder', 'StaticModelWeight', 'DynamicModelWeight', 'RecencyModelWeight', 'CacheModelWeight', 'AdaptationVersionNumber', 'dynamicDataSchema']}
net = Path('/System/Library/LinguisticData/RequiredAssets_en.bundle/AssetData/en.lm/unilm.bundle/unilm_joint_cpu.espresso.net')
if net.is_file():
    layers = json.loads(net.read_text()).get('layers', [])
    names = [layer.get('name', '') for layer in layers if 'gpt2' in layer.get('name', '').lower()]
    report['English_model'] = {'path': str(net), 'gpt2_named_layers': len(names), 'sample_layer_names': names[:4]}
report['limitations'] = ['Not a decoder or whole-dictionary export.', 'Layer names do not identify training weights or prove the Chinese IME uses this model.']
print(json.dumps(report, ensure_ascii=False, indent=2))
