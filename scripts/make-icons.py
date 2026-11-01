#!/usr/bin/env python3
"""Build native macOS assets from the original SVG sources (no fonts)."""
from pathlib import Path
import sys, subprocess, shutil, xml.etree.ElementTree as ET
import cairosvg
root = Path(__file__).resolve().parents[1]
dest = Path(sys.argv[1]); dest.mkdir(parents=True, exist_ok=True)
source = (root/'Resources/Icons/AppIcon.svg').read_bytes()
small = ET.fromstring(source)
for element in list(small):
    if element.get('id') in ('latin-key', 'detail'): small.remove(element)
small = ET.tostring(small)
iconset = dest/'AppIcon.iconset'; iconset.mkdir(exist_ok=True)
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        pixels = size*scale
        cairosvg.svg2png(bytestring=small if size < 48 else source, output_width=pixels, output_height=pixels,
            write_to=str(iconset/f'icon_{size}x{size}{"@2x" if scale == 2 else ""}.png'))
cairosvg.svg2png(bytestring=source, output_width=1024, output_height=1024, write_to=str(dest/'AppIcon-1024.png'))
subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(dest/'AppIcon.icns')], check=True)
shutil.rmtree(iconset)
menu = root/'Resources/Icons/InputMenuIcon.svg'
cairosvg.svg2pdf(url=str(menu), write_to=str(dest/'InputMenuIcon.pdf'))
cairosvg.svg2png(url=str(menu), output_width=36, output_height=36, write_to=str(dest/'InputMenuIcon-36.png'))
print('Built AppIcon.icns + InputMenuIcon.pdf from SVG')
