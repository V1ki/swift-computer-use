#!/bin/bash
# Read-only target analysis. Writes only the fixed re/raw/bundle directory.
set -eu
/usr/bin/python3 - <<'PY'
import os, pathlib, subprocess, json, re, hashlib, plistlib, collections, datetime, shlex
ROOT=pathlib.Path('/Users/v1ki/.codex/computer-use/Codex Computer Use.app')
HOST=pathlib.Path('/Applications/ChatGPT.app')
OUT=pathlib.Path('/Users/v1ki/Desktop/test2/swift-computer-use/re/raw/bundle')
OUT.mkdir(parents=True,exist_ok=True)
commands=[]
def save(name,text):
 p=OUT/(name+'.txt'); p.parent.mkdir(parents=True,exist_ok=True); p.write_text(text,errors='replace')
def run(name,args,stdin=None,limit=40000000):
 cmd=shlex.join([str(a) for a in args]); commands.append(cmd)
 try:
  p=subprocess.run([str(a) for a in args],input=stdin,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=180)
  out=p.stdout.decode('utf-8','replace'); err=p.stderr.decode('utf-8','replace'); rc=p.returncode
 except subprocess.TimeoutExpired as e:
  out=(e.stdout or b'').decode('utf-8','replace');err='TIMEOUT after 180 seconds';rc=124
 text='$ '+cmd+'\n[exit code: '+str(rc)+']\n'+out+'\n[stderr]\n'+err
 if len(text)>limit: text=text[:limit]+f'\n[TRUNCATED: original {len(text)} characters]\n'
 save(name,text)
 return out
run('environment',['/usr/bin/sw_vers']);run('xcode',['/usr/bin/xcodebuild','-version'])
files=sorted(p for p in ROOT.rglob('*') if p.is_file()); dirs=sorted(p for p in ROOT.rglob('*') if p.is_dir())
magic={b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xfe\xed\xfa\xce',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'}
def ismacho(p):
 with p.open('rb') as f:return f.read(4) in magic
def role(p):
 s=str(p);n=p.name
 if ismacho(p):return 'Mach-O executable/library'
 if n=='Info.plist':return 'Bundle metadata'
 if n=='CodeResources':return 'Code signature resource seal'
 if n=='embedded.provisionprofile':return 'CMS provisioning profile'
 if n=='Assets.car':return 'Compiled asset catalog'
 if n.endswith('.coderequirement'):return 'Parent code-signing requirement'
 if n=='BUILD.bazel':return 'Bundled build rules'
 if n.endswith('.md'):return 'Built-in application/agent instructions'
 if n.endswith('.png'):return 'Lens animation frame'
 if n.endswith('.wav'):return 'Appshot sound'
 if n.endswith('.icns'):return 'App icon'
 if n=='PkgInfo':return 'Legacy bundle type/creator'
 if n.endswith('.xcprivacy'):return 'Privacy manifest'
 return 'Other resource'
save('tree','Root: '+str(ROOT)+'\n'+'\n'.join('DIR\t'+str(p.relative_to(ROOT)) for p in dirs)+'\n'+'\n'.join(f'{p.stat().st_size}\t{p.relative_to(ROOT)}\t{role(p)}' for p in files)+f'\nTOTAL files={len(files)} directories={len(dirs)} bytes={sum(p.stat().st_size for p in files)}\n')
save('hashes','\n'.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(ROOT)) for p in files))
plistindex=[]
for i,p in enumerate([p for p in files if p.name=='Info.plist' or p.suffix=='.xcprivacy']+[HOST/'Contents/Info.plist']):
 name=f'plists/{i:02d}-{p.parent.parent.name}-{p.name}';run(name,['/usr/bin/plutil','-convert','xml1','-o','-',p]);plistindex.append(name+'\t'+str(p))
save('plist-index','\n'.join(plistindex))
for i,p in enumerate(p for p in files if p.name=='embedded.provisionprofile'):
 run(f'profiles/{i:02d}-decoded',['/usr/bin/security','cms','-D','-i',p])
bundles=[ROOT]+sorted(p for p in dirs if p.suffix in ['.app','.bundle','.framework'])+[HOST]
for i,p in enumerate(bundles):
 run(f'signatures/{i:02d}-{p.name}',['/usr/bin/codesign','-dvvv','--entitlements',':-',p]);run(f'signatures/{i:02d}-{p.name}-requirement',['/usr/bin/codesign','-d','-r-',p])
seal=[]
for p in files:
 if p.name=='CodeResources':
  d=plistlib.loads(p.read_bytes());seal.append({'path':str(p.relative_to(ROOT)),'bytes':p.stat().st_size,'counts':{k:len(v) for k,v in d.items() if isinstance(v,dict)}})
save('code-resources-summary',json.dumps(seal,ensure_ascii=False,indent=2))
run('signature-verification',['/usr/bin/codesign','--verify','--deep','--strict','--verbose=4',ROOT])
run('notarization-staple',['/usr/bin/xcrun','stapler','validate',ROOT])
run('gatekeeper-assessment',['/usr/sbin/spctl','--assess','--type','execute','-vv',ROOT])
machos=[p for p in files if ismacho(p)]
hp=plistlib.loads((HOST/'Contents/Info.plist').read_bytes());machos.append(HOST/'Contents/MacOS'/hp['CFBundleExecutable'])
index=[];summary=[];allstrings=[]
patterns={
 'urls-domains':r'https?://|wss?://|(?:[a-z0-9-]+\.)+(?:com|net|org|io|dev|app|ai)(?:[/ :]|$)',
 'ipc-launch-paths':r'(?i)xpc|socket|machservice|launchd|launchctl|SMAppService|LoginItem|SharedSupport|\.app/|\.sock|/Library/|\.codex|authorization|guardian',
 'logging':r'(?i)subsystem|os_log|logger|logging|loglevel|com\.openai|CUAService',
 'errors':r'(?i)error|failed|failure|unsupported|invalid|denied|not permitted|timed? ?out|cannot|could not',
 'permissions':r'(?i)permission|accessibility|screen.?record|TCC|NS.*UsageDescription|privacy|AXIsProcessTrusted',
 'updates-version':r'(?i)sparkle|appcast|feedurl|protocol.?version|client.?version|service.?version|minimum.?version|version.?mismatch|negotiat|handshake',
 'protobuf-json':r'(?i)protobuf|proto3|proto2|json|codingkeys|oneof|serialized|request.?id|session.?id|message.?type',
 'json-key-candidates':r'^[a-zA-Z_][a-zA-Z0-9_]{1,79}$',
 'system-api':r'AXUIElement|AXObserver|CGS|SLS|SkyLight|ScreenCaptureKit|SCShareable|SCStream|CGEvent|CGWindow|CGDisplay|Authorization|SecCode|SecRequirement|VZ|VirtualDisplay'
}
for i,p in enumerate(machos):
 tag=f'{i:02d}-{p.name}';base='macho/'+tag;index.append(f'{tag}\t{p.stat().st_size}\t{p}')
 run(base+'/file',['/usr/bin/file',p]);run(base+'/arch',['/usr/bin/lipo','-archs',p]);run(base+'/header',['/usr/bin/otool','-hv',p]);load=run(base+'/load-commands',['/usr/bin/otool','-l',p]);run(base+'/libraries',['/usr/bin/otool','-L',p]);
 blocks=re.split(r'(?=Load command \d+)',load);save(base+'/key-load-commands',''.join(b for b in blocks if re.search(r'LC_MAIN|LC_.*DYLIB|LC_RPATH|LC_BUILD_VERSION|LC_CODE_SIGNATURE|LC_UUID',b)))
 for flag in ['dependents','imports','exports']:run(base+'/dyld-'+flag,['/usr/bin/xcrun','dyld_info','-'+flag,p])
 nm=run(base+'/nm-all',['/usr/bin/nm','-m',p]);ex=run(base+'/nm-external-defined',['/usr/bin/nm','-gU',p]);un=run(base+'/nm-undefined',['/usr/bin/nm','-u',p]);dem=run(base+'/nm-demangled',['/usr/bin/xcrun','swift-demangle'],stdin=nm.encode())
 ss=run(base+'/strings',['/usr/bin/strings','-a',p]);allstrings += [f'{tag}\t{s}' for s in ss.splitlines()]
 for cat,pat in patterns.items():save(base+'/strings-'+cat,'# regex: '+pat+'\n'+'\n'.join(s for s in ss.splitlines() if re.search(pat,s)))
 types=sorted(set(re.findall(r'_Tt[CP][A-Za-z0-9_$]+',ss)))
 td=run(base+'/swift-runtime-types',['/usr/bin/xcrun','swift-demangle'],stdin=('\n'.join(types)+'\n').encode())
 save(base+'/swift-symbol-types-protocols','\n'.join(s for s in dem.splitlines() if re.search(r'type metadata|nominal type descriptor|protocol descriptor|protocol conformance|\$main|\.main\(',s)))
 objc=run(base+'/objc-metadata',['/usr/bin/otool','-ov',p],limit=30000000)
 save(base+'/objc-classes','\n'.join(sorted(set(re.findall(r'(?:_OBJC_(?:META)?CLASS_\$_)([^\s]+)',nm)))))
 run(base+'/signatures',['/usr/bin/codesign','-dvvv','--entitlements',':-',p])
 summary.append({'tag':tag,'path':str(p),'bytes':p.stat().st_size,'nm_lines':len(nm.splitlines()),'external_defined_lines':len(ex.splitlines()),'undefined_lines':len(un.splitlines()),'runtime_type_names':len(types),'strings_lines':len(ss.splitlines())})
save('macho-index','\n'.join(index));save('macho-summary',json.dumps(summary,indent=2));save('all-strings','\n'.join(allstrings))
for i,p in enumerate(p for p in files if p.name=='Assets.car'):
 run(f'assets/{i:02d}-assetutil',['/usr/bin/assetutil','--info',p])
for i,p in enumerate(p for p in files if p.name=='BUILD.bazel' or p.suffix in ['.md','.coderequirement']):
 if p.suffix=='.coderequirement':run(f'resources/{i:02d}-{p.name}',['/usr/bin/plutil','-convert','xml1','-o','-',p])
 else:save(f'resources/{i:02d}-{p.name}','$ read '+str(p)+'\n'+p.read_text())
run('launchctl-gui',['/bin/launchctl','print',f'gui/{os.getuid()}'])
run('launchctl-service',['/bin/launchctl','print',f'gui/{os.getuid()}/com.openai.sky.CUAService'])
run('launchctl-system-service',['/bin/launchctl','print','system/com.openai.sky.CUAService'])
run('service-process',['/bin/ps','-p','14867','-o','pid,ppid,uid,lstart,command'])
launch=[]
for dr in ['/Users/v1ki/Library/LaunchAgents','/Library/LaunchAgents','/Library/LaunchDaemons']:
 for p in sorted(pathlib.Path(dr).glob('*.plist')):
  try:
   d=plistlib.loads(p.read_bytes());blob=repr(d)
   if re.search(r'openai\.sky|SkyComputerUse|CUAService|CUALockScreen|Codex Computer Use',blob,re.I):launch.append(str(p)+'\n'+plistlib.dumps(d).decode())
  except Exception as e:launch.append(str(p)+' PARSE ERROR '+str(e))
save('launch-plists','\n'.join(launch) if launch else 'No matching launch plist in user LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons.\n')
# Compare host's packaged copy without executing either target.
copy=HOST/'Contents/Resources/cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app'
comparison=[]
for p in files:
 q=copy/p.relative_to(ROOT)
 comparison.append(f'{p.relative_to(ROOT)}\t'+('IDENTICAL' if q.is_file() and hashlib.sha256(p.read_bytes()).digest()==hashlib.sha256(q.read_bytes()).digest() else 'DIFFERENT_OR_ABSENT'))
save('host-copy-comparison','\n'.join(comparison))
save('commands','\n'.join(commands))
print('Completed',len(files),'files;',len(machos),'Mach-O binaries; output',OUT)
PY
# Fast aggregation / supplemental evidence (can rerun separately).
/usr/bin/python3 - <<'PY'
import pathlib,re,json,collections,subprocess,shlex,plistlib
O=pathlib.Path('/Users/v1ki/Desktop/test2/swift-computer-use/re/raw/bundle'); R=pathlib.Path('/Users/v1ki/.codex/computer-use/Codex Computer Use.app')
def put(n,s): (O/(n+'.txt')).write_text(s)
def cmd(n,a):
 p=subprocess.run(a,stdout=subprocess.PIPE,stderr=subprocess.PIPE);put(n,'$ '+shlex.join(a)+'\n[exit code: '+str(p.returncode)+']\n'+p.stdout.decode(errors='replace')+'\n[stderr]\n'+p.stderr.decode(errors='replace'))
for p in R.rglob('*.coderequirement'):cmd('parent-'+p.stem,['/usr/bin/plutil','-convert','xml1','-o','-',str(p)])
cmd('launchctl-agent',['/bin/launchctl','print','gui/501/com.openai.sky.CUAService.agent'])
cmd('registration-process-parent',['/bin/ps','-p','14867,1508','-o','pid,ppid,uid,lstart,command'])
cmd('authorizationdb-screensaver',['/usr/bin/security','authorizationdb','read','system.login.screensaver'])
cmd('authorizationdb-remote',['/usr/bin/security','authorizationdb','read','com.openai.sky.CUAService.AuthorizationPlugin.remote'])
cmd('installed-plugin-list',['/bin/ls','-ld','/Library/Security/SecurityAgentPlugins/CodexComputerUseAuthorizationPlugin.bundle'])
cmd('disassembly-skylight',['/usr/bin/xcrun','llvm-objdump','-d','--start-address=0x100f30bb4','--stop-address=0x100f31200',str(R/'Contents/MacOS/SkyComputerUseService')])
cmd('disassembly-cgevent',['/usr/bin/xcrun','llvm-objdump','-d','--start-address=0x10025ec08','--stop-address=0x10025ec84',str(R/'Contents/MacOS/SkyComputerUseService')])
summary=[]
for d in sorted((O/'macho').iterdir()):
 nm=(d/'nm-all.txt').read_text();dem=(d/'nm-demangled.txt').read_text();load=(d/'load-commands.txt').read_text();ss=(d/'strings.txt').read_text()
 types=sorted(set(re.findall(r'nominal type descriptor for (.+)',dem)))
 protocols=sorted(set(re.findall(r'(?<!conformance )protocol descriptor for (.+)',dem)))
 groups=collections.defaultdict(list)
 for t in types:groups[t.split('.')[0]].append(t)
 (d/'swift-types-all-grouped.txt').write_text('\n'.join('## '+k+' ('+str(len(v))+')\n'+'\n'.join(v) for k,v in sorted(groups.items())))
 (d/'swift-protocols-all.txt').write_text('\n'.join(protocols))
 runtime=(d/'swift-runtime-types.txt').read_text(); runtimegroups=collections.defaultdict(list)
 for line in runtime.splitlines():
  if line and not line.startswith(('$ ','[')):
   typ=line.split(' ---> ',1)[-1];runtimegroups[typ.split('.')[0]].append(typ)
 (d/'swift-runtime-types-grouped.txt').write_text('\n'.join('## '+k+' ('+str(len(v))+')\n'+'\n'.join(sorted(v)) for k,v in sorted(runtimegroups.items())))
 (d/'objc-classes-defined.txt').write_text('\n'.join(sorted(set(re.findall(r'^.*(?<!undefined\)) (?:external|non-external) _OBJC_CLASS_\$_([^\s]+)$',nm,re.M)))))
 entries=[s for s in dem.splitlines() if '<redacted LC_MAIN>' in s or re.search(r' external (_main|_AuthorizationPluginCreate)$',s)]
 (d/'entrypoint-summary.txt').write_text('\n'.join(entries)+'\n'+'\n'.join(re.findall(r'cmd LC_MAIN\n.*\n.*\n.*',load)))
 summary.append({'binary':d.name,'nominal_type_descriptors':len(types),'protocol_descriptors':len(protocols),'nm_total':len([s for s in nm.splitlines() if re.match(r'^[0-9a-f]{16} |^\s+\(undefined\)',s)]),'nm_undefined':nm.count('(undefined)'),'nm_external_defined':len([s for s in nm.splitlines() if ' external ' in s and '(undefined)' not in s]),'nm_redacted':nm.count('<redacted'),'dyld_imports':len(re.findall(r'^\s+0x[0-9A-Fa-f]+', (d/'dyld-imports.txt').read_text(),re.M)),'dyld_exports':len(re.findall(r'^\s+0x[0-9A-Fa-f]+', (d/'dyld-exports.txt').read_text(),re.M)),'type_modules':{k:len(v) for k,v in sorted(groups.items())}})
put('symbol-statistics',json.dumps(summary,indent=2))
assets=[]
for p in sorted((O/'assets').glob('*.txt')):
 text=p.read_text();j=text[text.index('\n[exit code: 0]\n')+len('\n[exit code: 0]\n'):].split('\n[stderr]')[0]
 data=json.loads(j);names=sorted(set(x['Name'] for x in data if 'Name' in x));assets.append(text.splitlines()[0]+'\n'+'\n'.join(names))
put('asset-names','\n\n'.join(assets))
put('failures-and-truncations','\n'.join(str(p.relative_to(O))+': '+m.group(0) for p in O.rglob('*.txt') for m in re.finditer(r'^\[exit code: [1-9]\d*\]|^\[TRUNCATED:.*',p.read_text(errors='replace'),re.M)))
PY
