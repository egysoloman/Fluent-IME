#!/usr/bin/env python3
"""Fetch the catalog's MIT-licensed Fluent Emoji images at a fixed revision."""
import concurrent.futures, hashlib, json, subprocess, urllib.parse
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
REVISION = '1ffb34c752ecf5d402f04cfb4b392c77f57c54bc'
NAMES = {
'😊':'Smiling face with smiling eyes','😂':'Face with tears of joy','🤣':'Rolling on the floor laughing','❤️':'Red heart','😍':'Smiling face with heart-eyes','😒':'Unamused face',
'👌':'Ok hand','😘':'Face blowing a kiss','💕':'Two hearts','😁':'Beaming face with smiling eyes','👍':'Thumbs up','🙌':'Raising hands',
'😀':'Grinning face','🥰':'Smiling face with hearts','😎':'Smiling face with sunglasses','🤔':'Thinking face','😭':'Loudly crying face','🥹':'Face holding back tears','😴':'Sleeping face','😅':'Grinning face with sweat',
'😡':'Pouting face','🤗':'Hugging face','🤩':'Star-struck','🫡':'Saluting face','🙏':'Folded hands','👏':'Clapping hands','👋':'Waving hand','✌️':'Victory hand','🤝':'Handshake','💪':'Flexed biceps',
'🐍':'Snake','🐱':'Cat face','🐶':'Dog face','🐼':'Panda','🐉':'Dragon','🦊':'Fox','🌹':'Rose','🌸':'Cherry blossom','🌻':'Sunflower','🍀':'Four leaf clover','☀️':'Sun','🌈':'Rainbow',
'🍎':'Red apple','🍉':'Watermelon','🍓':'Strawberry','🍰':'Shortcake','☕':'Hot beverage','🧋':'Bubble tea','🎉':'Party popper','🎂':'Birthday cake','🎁':'Wrapped gift','🎈':'Balloon','✨':'Sparkles','🔥':'Fire','💯':'Hundred points','✅':'Check mark button',
'🚀':'Rocket','💻':'Laptop','📚':'Books','🎵':'Musical note','🆒':'Cool button'
}
paths = subprocess.check_output(['git','-C',str(ROOT/'Vendor/fluentui-emoji'),'ls-tree','-r','--name-only',REVISION],text=True).splitlines()
out = ROOT/'Resources/FluentEmoji'; out.mkdir(exist_ok=True)
manifest = {}; color_manifest = {}; tasks=[]
for emoji,name in NAMES.items():
    prefix = 'assets/'+name+'/'
    options = [p for p in paths if p.startswith(prefix) and p.endswith('.png') and ('/Default/3D/' in p or p.startswith(prefix+'3D/'))]
    if not options:
        print('Missing asset name:',emoji,name)
        continue
    path=options[0]; filename='-'.join(format(ord(c),'x') for c in emoji)+'.png'
    manifest[emoji]=filename; tasks.append((path,filename))
    colors = [p for p in paths if p.startswith(prefix) and p.endswith('.svg') and ('/Default/Color/' in p or p.startswith(prefix+'Color/'))]
    if colors:
        color_name = filename.replace('.png','.svg')
        color_manifest[emoji] = color_name; tasks.append((colors[0],color_name))
def fetch(task):
    path,filename=task; destination=out/filename
    if not destination.exists():
        subprocess.run(['curl','-fsSL','--retry','2','--connect-timeout','10','--max-time','45','https://raw.githubusercontent.com/microsoft/fluentui-emoji/'+REVISION+'/'+urllib.parse.quote(path),'-o',str(destination)],check=True)
    return {'path':path,'file':filename,'sha256':hashlib.sha256(destination.read_bytes()).hexdigest()}
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    files=list(pool.map(fetch,tasks))
subprocess.run(['curl','-fsSL','--retry','2','--max-time','30','https://raw.githubusercontent.com/microsoft/fluentui-emoji/'+REVISION+'/LICENSE','-o',str(out/'LICENSE')],check=True)
(out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
(out/'manifest-color.json').write_text(json.dumps(color_manifest,ensure_ascii=False,indent=2)+'\n')
(out/'sources.json').write_text(json.dumps({'repository':'https://github.com/microsoft/fluentui-emoji','revision':REVISION,'files':files},indent=2)+'\n')
print('Bundled',len(files),'Fluent Emoji images')
