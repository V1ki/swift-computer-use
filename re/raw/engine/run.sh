#!/bin/bash
# Read-only static extraction; writes exclusively to this evidence directory.
set -euo pipefail
OUT='/Users/v1ki/Desktop/test2/swift-computer-use/re/raw/engine'
BIN='/Users/v1ki/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService'
RES='/Users/v1ki/.codex/computer-use/Codex Computer Use.app/Contents/Resources'
/usr/bin/file "$BIN" > "$OUT/file.txt"
/usr/bin/shasum -a 256 "$BIN" > "$OUT/sha256.txt"
/usr/bin/otool -L "$BIN" > "$OUT/dylibs.txt"
/usr/bin/nm -nm "$BIN" > "$OUT/nm.txt"
xcrun swift-demangle < "$OUT/nm.txt" > "$OUT/nm-demangled.txt"
/usr/bin/strings -a -t x "$BIN" > "$OUT/strings.txt"
xcrun llvm-objdump --macho --disassemble --no-show-raw-insn "$BIN" > "$OUT/disassembly.txt"
python3 - "$RES" "$OUT" <<'PY'
import os,sys,json,plistlib
from pathlib import Path
res,out=map(Path,sys.argv[1:])
manifest=[]
for p in sorted(res.rglob('*')):
 if not p.is_file():continue
 manifest.append({'path':str(p.relative_to(res)),'bytes':p.stat().st_size})
 if p.suffix=='.plist':
  (out/(p.parent.parent.name+'-Info.json')).write_text(json.dumps(plistlib.loads(p.read_bytes()),indent=2,ensure_ascii=False,default=str))
 if p.name=='BUILD.bazel':
  (out/'BUILD.bazel.txt').write_text(p.read_text())
(out/'resource-manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False))
PY
