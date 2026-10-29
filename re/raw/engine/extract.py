from pathlib import Path
import re,json
p=Path(__file__).parent
nm=(p/'nm-demangled.txt').read_text().splitlines()
groups={
 'capture':r'ScreenshotImplementation|SkyshotOperation|ScreenCapture|Appshot.*capture|WindowServerSPI',
 'ax':r'ComputerUseCore\.|AccessibilitySPI|UIElementTreeTransaction|UIElementCache|Refetchable|UIElementProtocol\.(children|descendants|value|selected|focused)|AXHierarchy|Traversal',
 'input':r'CGEventAPI|Synthetic|ComputerUseAppController\.(click|drag|scroll|paste|select|setValue|type|press|prepare|position)|Clipboard|VirtualKey',
 'apps':r'AppUsageCatalog|ApplicationTarget|RunningApplications',
}
for name,pat in groups.items():
 rows=[f'{i+1}: {s}' for i,s in enumerate(nm) if re.search(pat,s) and '(__TEXT,__text) external' in s and not any(x in s for x in ['descriptor for','type metadata','getter','setter','modify','variable initialization','deinit','__deallocating','hash(into','hashValue','__derived','protocol witness','default argument'])]
 (p/(name+'-symbols.txt')).write_text('\n'.join(rows)+'\n')
strings=(p/'strings.txt').read_text().splitlines()
pat=r'AX|[Ss]creenshot|[Ee]lement|[Pp]aste|[Cc]lipboard|kMDItem|[Ss]elected|[Ff]ocus|[Cc]hromium|[Ee]lectron|[Ss]ky[Ll]ight|[Ss]tate|[Dd]epth|[Cc]hildren|[Tt]imeout'
(p/'string-hits.txt').write_text('\n'.join(f'{i+1}: {s}' for i,s in enumerate(strings) if re.search(pat,s))+'\n')
# Preserve short address-selected assembly slices without editing full evidence.
ranges={
 'spi-ax':(0x10025c43c,0x10025cd90),
 'spi-windowserver':(0x100272000,0x100273e8c),
 'capture-skylight':(0x100f30dc8,0x100f31e14),
 'render-line':(0x1006447e8,0x100645204),
 'render-presentation':(0x10063dd30,0x10063e500),
 'capture-branch':(0x100f37218,0x100f37450),
 'ax-hierarchy-call':(0x1006feb78,0x1006fed10),
 'input-post-pid':(0x10075ad38,0x10075ae94),
 'app-spotlight-query':(0x10004bf54,0x10004c0a8),
}
files={k:(p/(k+'.asm')).open('w') for k in ranges}
for line in (p/'disassembly.txt').open():
 m=re.match(r'([0-9a-f]+):',line)
 if not m:continue
 addr=int(m[1],16)
 for k,(a,b) in ranges.items():
  if a<=addr<b:files[k].write(line)
for f in files.values():f.close()
