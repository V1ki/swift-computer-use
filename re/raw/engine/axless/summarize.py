"""Summarize aggregate measurements; never include user AX strings."""
from pathlib import Path
import json, plistlib
base=Path(__file__).resolve().parent
for f in sorted(base.glob('*.jsonl')):
    if f.name=='inventory.jsonl':continue
    print('\nFILE',f.name)
    for l in f.read_text().splitlines():
        x=json.loads(l)
        if 'windowTree' not in x:print(x);continue
        print(x['label'], 'front='+x['frontmost'], 'active='+str(x['active']), 'hidden='+str(x['hidden']), 'windows='+str(x['windows']), 'windowNodes='+str(x['windowTree']['nodes']), 'appNodes='+str(x['appTree']['nodes']), 'truncated='+str(x['appTree']['truncated']), 'E='+x['AXEnhancedUserInterface']['value'], 'M='+x['AXManualAccessibility']['value'], 'webAreas='+str(x['windowTree']['roles'].get('AXWebArea',0)), 'CG410='+str(next((v['onscreen'] for v in x['cgWindows'] if v['id']==410),None)))
print('\nINSTALLED METADATA (not runtime framework classification)')
for name in ['Google Chrome','Cursor','ChatGPT','Claude','DingTalk','QQMusic','Obsidian','Blender','Godot','wpsoffice','Steam']:
    p=Path('/Applications')/(name+'.app')/'Contents'
    with (p/'Info.plist').open('rb') as f: data=plistlib.load(f)
    frameworks=p/'Frameworks'
    print(name, data.get('CFBundleIdentifier'),data.get('CFBundleShortVersionString'),data.get('CFBundleVersion'),'frameworks='+','.join(v.name for v in frameworks.glob('*.framework')))
