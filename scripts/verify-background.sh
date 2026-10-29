#!/bin/bash
# Safe default: a new disposable TextEdit document, never a chat recipient.
# Usage: CUA=/path/to/cua SWIFTCUA_SOCKET=/path/to/socket scripts/verify-background.sh
# Explicit self-chat alternative: scripts/verify-background.sh --wechat-self-chat
# Requires Swift toolchain, python3, service AX permission. Keep hands off mouse.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-textedit}"
case "$MODE" in textedit|--wechat-self-chat) ;; *) echo 'Usage: verify-background.sh [--wechat-self-chat]' >&2; exit 2;; esac
OUT="$(mktemp -d /tmp/swiftcua-cursor.XXXXXX)"
export CURSOR_VERIFY_OUT="$OUT" CURSOR_VERIFY_MODE="$MODE"
export CUA="${CUA:-$ROOT/.build-cursor/debug/cua}"
if [[ ! -x "$CUA" && -x "$ROOT/.build-cursor/out/Products/Debug/cua" ]]; then export CUA="$ROOT/.build-cursor/out/Products/Debug/cua"; fi
swiftc -parse-as-library "$ROOT/scripts/cursor-probe.swift" -o "$OUT/cursor-probe"
echo "Evidence directory: $OUT"
python3 - <<'PY'
import json, math, os, pathlib, re, subprocess, sys, time
out = pathlib.Path(os.environ['CURSOR_VERIFY_OUT'])
cli = os.environ['CUA']
probe = str(out / 'cursor-probe')
wechat = os.environ['CURSOR_VERIFY_MODE'] == '--wechat-self-chat'
app = 'com.tencent.xinWeChat' if wechat else 'com.apple.TextEdit'
rows = []
# Independent listener spans the entire test, including inter-command gaps.
event_log = (out/'events.jsonl').open('w')
monitor = subprocess.Popen([probe, 'monitor', '120'], stdout=event_log, stderr=subprocess.STDOUT)
def call(*args):
    p = subprocess.run([cli, *args, '--json'], text=True, capture_output=True)
    if p.returncode:
        raise RuntimeError(f"{args[0]} failed ({p.returncode}): {p.stderr.strip()}")
    return json.loads(p.stdout)
def sample():
    return json.loads(subprocess.check_output([probe, 'sample'], text=True))
def step(name, action):
    before = sample()
    error = None
    try:
        result = action()
    except Exception as exc:
        error = exc
        result = None
    time.sleep(0.5)  # include delayed target-app reactions
    after = sample()
    dx, dy = after['x']-before['x'], after['y']-before['y']
    row = dict(step=name, before=before, after=after, dx=dx, dy=dy,
               distance=math.hypot(dx,dy), frontUnchanged=before['frontPID']==after['frontPID'])
    rows.append(row)
    print(f"{name}: cursor ({before['x']},{before['y']}) -> ({after['x']},{after['y']}) "
          f"delta=({dx},{dy}) distance={row['distance']} front={before['frontmost']}:{before['frontPID']} "
          f"-> {after['frontmost']}:{after['frontPID']}", flush=True)
    if error is not None:
        row['error'] = str(error)
        raise error
    return result
try:
    if not wechat:
        document_name = 'SwiftCUA-Cursor-Test-' + out.name + '.txt'
        doc = out / document_name
        doc.write_text('Disposable SwiftCUA cursor verification document.\n')
        subprocess.run(['open', '-g', '-a', 'TextEdit', str(doc)], check=True)
        time.sleep(1)
    windows = call('windows')['windows']
    candidates = [w for w in windows if w['app']==app and
                  ((wechat and w.get('isOnScreen') and w['bounds']['width'] > 200 and w['bounds']['height'] > 100)
                   or (not wechat and document_name in (w.get('title') or '')))]
    if len(candidates) != 1: raise RuntimeError('Cannot uniquely identify safe target window; close duplicate test windows')
    window = str(candidates[0]['id'])
    target = ['--app', app, '--window', window]
    if sample()['frontmost'] == app: raise RuntimeError('Target is foreground; switch to another app then rerun')
    state = step('state', lambda: call('state', *target, '--no-screenshot'))
    state = state.get('state', state)
    tree = state.get('text') or state.get('accessibility',{}).get('tree','')
    inputs = [line for line in tree.splitlines() if re.search(r'\[\d+\] (?:text area|textArea|text_area|AXTextArea|textarea)', line, re.I)]
    if wechat: inputs = [line for line in inputs if re.search(r'\] \S+(?: \S+)? "knight"(?: |$)', line)]
    if len(inputs)!=1: raise RuntimeError('Cannot uniquely verify safe AX text area: ' + repr(inputs))
    # WeChat opt-in is explicit and only the exactly named knight input qualifies.
    # Never overwrite a pre-existing draft.
    if wechat and 'value=' in inputs[0] and 'value=""' not in inputs[0]: raise RuntimeError('Self-chat draft is nonempty; clear it yourself before testing')
    index = re.search(r'\[(\d+)\]', inputs[0]).group(1)
    step('set-value', lambda: call('set-value', *target, '--element', index, '--value', 'SwiftCUA background cursor verification'))
    step('press-key', lambda: call('press-key', *target, '--key', 'Return'))
    ok = all(r['distance']==0 and r['frontUnchanged'] for r in rows)
    # Also catch movement in inter-command gaps.
    initial = rows[0]['before']
    ok = ok and all(r['before']['x']==initial['x'] and r['before']['y']==initial['y'] and
                    r['before']['frontPID']==initial['frontPID'] for r in rows)
    print('PASS: zero cursor displacement; foreground unchanged' if ok else 'FAIL: step diffs above; use cursor-probe monitor to attribute movement')
    exitcode = 0 if ok else 1
except Exception as exc:
    print('FAIL:', exc, file=sys.stderr)
    exitcode = 1
finally:
    monitor.terminate()
    monitor.wait()
    event_log.close()
    events = []
    for line in (out/'events.jsonl').read_text().splitlines():
        try: events.append(json.loads(line))
        except json.JSONDecodeError: pass
    for row in rows:
        seen = [e for e in events if e.get('kind')=='event' and row['before']['time'] <= e['time'] <= row['after']['time']]
        row['mouseEventCount'] = len(seen)
        row['mouseSourcePIDs'] = sorted(set(e['sourcePID'] for e in seen))
        print(f"{row['step']}: tapEvents={len(seen)} sourcePIDs={row['mouseSourcePIDs']} (PID 0 = hardware/unattributed, not proof of user)")
    if any(e.get('kind')=='error' for e in events):
        print('WARNING: event tap unavailable; see events.jsonl. Displacement assertion remains valid, attribution does not.')
    (out/'steps.json').write_text(json.dumps(rows, indent=2))
sys.exit(exitcode)
PY
