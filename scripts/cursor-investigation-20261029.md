# Background cursor investigation — 2026-10-29

## Conclusion and limits

The originally reported three historical cursor samples do **not** identify the source of movement. No event log exists for that interval. I did not reproduce a SwiftCUA- or WeChat-attributed cursor move or a tap-invisible warp. Do not claim that WeChat 4.1.15 is proven faulty or that this hardening fixes a proven historical root cause.

Independent control evidence shows concurrent hardware/unattributed input (source PID 0, sourceState 1): a 10-second baseline with **no automation actions** recorded 263 mouse events, moving from `(481.121,-500.230)` to `(562.844,-783.469)`. PID 0 is consistent with hardware input but is not definitive proof of a human; injected events may also have incomplete metadata.

## Actual experiments

- macOS 27.2 (26B123), Swift 6 toolchain. Frontmost throughout: `com.google.Chrome`, PID 1522. WeChat PID 41969. Installed service PID 45690 was untouched; tests used separate sockets and service processes.
- TextEdit standalone probe PID 50775 → TextEdit PID 50489: AX set value, pid-directed Return, SCStream (5 frames), AX read all held `(677.223,805.336)` unchanged. No mouse events.
- WeChat standalone probe PID 53197, exact `AXTextArea title="knight"`, empty draft: AX write and pid Return held `(888.363,710.457)` unchanged. Main window SCStream **20075**, 5 frames: moved to `(886.738,668.461)`, with 5 matching continuous mouseMoved events **all sourcePID=0**, no WeChat/service/probe source PID. Subsequent AX read had no displacement. This is observed event-mediated movement, not evidence of a tap-invisible warp.
- The current WeChat main window had changed to `(747,-906,786,635)`, unlike the reported historical `(1512,-1410,1080,1890)`. No window resizing/activation was performed to recreate the old layout.
- Isolated service PID 50125, TextEdit `state/set-value/press-key`: each Δ=0 at `(382.0195,-493.1289)`, Chrome unchanged. Unified log: `setValue globalPosts=0`, `pressKey globalPosts=0 pidPosts=2`.
- Same service, knight self-chat `state/set-value/press-key`: each Δ=0 at `(883.0547,592.0391)`, Chrome unchanged.
- Final integrated TextEdit rerun **passed** with the final binary: all three steps Δ=0 at `(1299.5898,833.8320)`, Chrome unchanged, **zero tap events** throughout each step; evidence `/tmp/swiftcua-cursor.pUBmFj/steps.json` and `events.jsonl`.
- Other final-binary tests correctly **failed** during input activity. One attributed TextEdit run: read-only `state` Δ=589.449 pixels with **95 sourcePID=0** events; set-value and Return Δ=0, no mouse events. Frontmost unchanged. This demonstrates why endpoint-only validation must not be treated as process attribution.
- Earlier nonempty knight draft was refused rather than overwritten. When re-inspected it was empty; only then were self-chat probes run. No group/third-party recipient was tested. The probes test API delivery, not confirmation of message delivery.

## Changes

- `Sources/CUAEngine/CursorTrace.swift`: opt-in unified logging (`dev.v1ki.swiftcua`, category `cursor`), action IDs, service PID, before/after physical location/frontmost/policy, actual global and pid post counts; injectable `EventPoster` and task-local immutable input policy.
- `Sources/CUAEngine/InputSynthesis.swift`: every event funnels through the poster; default-deny global injection in background (`inputRejected`). Clipboard paste checks policy **before** clipboard mutation. No cursor restoration/warp hack.
- `Sources/CUAEngine/SkyEngine.swift`: each action captures policy so actor reentrancy cannot change policy mid-action; nested actions retain it. `launchApp` now respects background activation; `ensureActive` has an explicit guard; arbitrary secondary `AXRaise` is denied in background. All actions traced, including throwing exits.
- `Sources/CUAClient/CLI.swift`: policy reset errors fail closed for actual service actions, without breaking offline doctor/local session commands.
- `tests/CUAEngineTests/InputPolicyTests.swift`: 5 fake-poster tests; background global methods reject, pid methods use only target poster, explicit foreground global methods work, nested policy restores correctly. Tests do not post to a real cursor.
- `scripts/cursor-probe.swift`: standalone Swift tap + sampling/AX/keyboard/SCStream probe; exact self-chat and nonempty-draft safety gates; geometry-matched capture; no dependency on CLI.
- `scripts/verify-background.sh`: disposable uniquely named TextEdit document by default (`open -g`); explicit `--wechat-self-chat` requires exact knight text area and empty draft. Before/after diffs, frontmost identity, integrated independent tap event evidence in a unique `/tmp/swiftcua-cursor.*` directory. Concurrent input correctly fails the zero-displacement assertion. Does not close unrelated windows or delete documents.

PiP audit: `PreviewPanel` cannot become key/main, uses `.nonactivatingPanel` and `orderFrontRegardless`; status menu actions run only on user interaction. `PreviewHub` only publishes JPEG data. `WindowStream` has no activation/global events and sets `showsCursor=false`. No service source edits were needed/allowed. Source-wide audit leaves the sole Quartz global post in `QuartzEventPoster`, reached via the guarded synthesis seam; no AXFrontmost/makeKey/CGWarp calls.

## Reproduce

```bash
swift build --scratch-path .build-cursor
swift test --scratch-path .build-cursor
# Both passed. 55 XCTest cases, zero failures, including 5 new policy tests.

# Use the appropriate product path for your SwiftPM build system.
SWIFTCUA_TRACE_CURSOR=1 .build-cursor/out/Products/Debug/cua-service \
  --socket /tmp/swiftcua-cursor-manual.sock --home /tmp/swiftcua-cursor-manual-home \
  --auto-authorize true
# Separate terminal; keep mouse still for the measurement interval:
SWIFTCUA_SOCKET=/tmp/swiftcua-cursor-manual.sock scripts/verify-background.sh
# Only when you have selected your own knight conversation with an empty draft:
SWIFTCUA_SOCKET=/tmp/swiftcua-cursor-manual.sock scripts/verify-background.sh --wechat-self-chat

swiftc -parse-as-library scripts/cursor-probe.swift -o /tmp/cursor-probe
/tmp/cursor-probe monitor 10
/tmp/cursor-probe run com.tencent.xinWeChat --allow-self-chat
/usr/bin/log show --last 15m --style compact \
  --predicate 'subsystem == "dev.v1ki.swiftcua" AND category == "cursor"'
```

Trace must be enabled in the **service** environment, not merely the client. No screen/AX permission prompts are requested by the probe; it fails explicitly if missing. A nil/unavailable tap invalidates attribution, not the endpoint assertion. Tap PID fields are evidence, not authenticated provenance. A no-event location delta is warp-compatible but cannot identify the warping process with public APIs alone.

Raw local evidence is retained under `.build-cursor/`: `probe-baseline.jsonl`, `probe-textedit.jsonl`, `probe-wechat-main.jsonl`, `cursor-final.log`, `final-tests.log`, `verify-final-attributed.log`, plus step/tap JSON under the directories printed by each verification invocation. Build scratch files are local evidence, not required repository artifacts.

## Residual risks

Public AX/pid event APIs cannot prevent a receiving application from activating itself or warping the mouse internally. No such behavior was proven here, so no speculative WeChat workaround or AXPress-send substitution was introduced. If reproducible on the old geometry, repeat hands-off with the probe, compare baseline vs each step, and use foreground mode explicitly if the app cannot support safe background input. Do not compensate with cursor warps: that races the user and itself steals the cursor.

`setOptions` is still a shared engine option; two independent clients can interleave separate setOptions/action RPCs before an action starts. This patch freezes policy during an action but does not redesign wire/session ownership. A future per-request/session activation policy is needed to close cross-client policy races fully (service router is outside this task's allowed edit scope).
