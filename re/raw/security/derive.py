#!/usr/bin/env python3
"""Read-only derivation of focused evidence; writes only beside this script."""
from pathlib import Path
import struct, re, json
p=Path(__file__).resolve().parent
app=Path('/Users/v1ki/.codex/computer-use/Codex Computer Use.app')
b=(app/'Contents/MacOS/SkyComputerUseService').read_bytes()
segments=[]; offset=32
for _ in range(struct.unpack_from('<I',b,16)[0]):
    cmd,size=struct.unpack_from('<II',b,offset)
    if cmd==0x19:
        _,va,sz,fo,_=struct.unpack_from('<16sQQQQ',b,offset+8); segments.append((va,sz,fo))
    offset+=size
def get(a,n):
    for va,sz,fo in segments:
        if va<=a<va+sz:return b[fo+a-va:fo+a-va+n]
    return b''
out=[]
for a in [0x1014c63c8,0x1014c6400,0x1014c6438,0x1014c64e8,0x1014c6530,0x1014c6578,0x1014c65c0]:
    out.append(hex(a)); data=get(a,32);out.append(data.hex())
    for j in range(min(struct.unpack_from('<Q',data,16)[0],15)):
        x,y=struct.unpack('<QQ',get(a+32+j*16,16))
        text=(struct.pack('<QQ',x,y)[:y>>56&15] if y>>60==0xe else get(y&0xfffffffffffffff,x&0xffffffffffff)).decode(errors='replace')
        out.append(f'{x:x} {y:x}: {text!r}')
(p/'auth-static-arrays.txt').write_text('\n'.join(out)+'\n')
ranges={'auth-disassembly.txt':(0x10017ed00,0x100184000),'lock-controller-disassembly.txt':(0x10022a800,0x10022e080),'physical-input-disassembly.txt':(0x100233d00,0x100234780),'auth-defaults-disassembly.txt':(0x100047dc0,0x100047eb0),'login-auth-server-disassembly.txt':(0x1001b171c,0x1001b3168)}
outputs={k:[] for k in ranges}
for line in (p/'service.disassembly.txt').read_text().splitlines():
    try:a=int(line.split('\t',1)[0],16)
    except ValueError:continue
    for k,(lo,hi) in ranges.items():
        if lo<=a<hi:outputs[k].append(line)
for k,lines in outputs.items():(p/k).write_text('\n'.join(lines)+'\n')
lines=[]
for f in sorted(p.glob('*.strings.txt')):
    for n,l in enumerate(f.read_text(errors='replace').splitlines(),1):
        if re.search(r'https?://|wss?://|(?:[a-zA-Z0-9-]+\.)+(?:com|net|org|io)(?:/|\b)',l) and len(l)<2000:lines.append(f'{f.name}:{n}: {l}')
(p/'network-domains.txt').write_text('\n'.join(lines)+'\n')
s=(p/'service.strings.txt').read_text(errors='replace').splitlines()
(p/'telemetry-fields.txt').write_text('\n'.join(f'{n}: {l}' for n,l in enumerate(s,1) if re.search('computer_use_|cua_|screen.*(count|size|text)|ocr|telemetry|privateAttributes|disableLogging|diagnostics|lock_screen',l,re.I))+'\n')
(p/'launchctl-matches.txt').write_text('\n'.join(l for l in (p/'launchctl.txt').read_text().splitlines() if re.search('sky|cua',l,re.I))+'\n')
log=(p/'logs.txt').read_text().splitlines();(p/'logs-excerpt.txt').write_text('\n'.join(log[381:403]+log[781:803])+'\n')
(p/'sessions-snapshot.json').write_text(json.dumps({f.name:f.read_text() for f in Path('/Users/v1ki/.codex/computer-use/sessions').glob('*.toml')},ensure_ascii=False,indent=2))
(p/'persistent-approvals.json').write_bytes(Path('/Users/v1ki/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/Library/Application Support/Software/ComputerUseAppApprovals.json').read_bytes())
(p/'client-parent.coderequirement').write_bytes((app/'Contents/SharedSupport/SkyComputerUseClient.app/Contents/Resources/SkyComputerUseClient_Parent.coderequirement').read_bytes())
