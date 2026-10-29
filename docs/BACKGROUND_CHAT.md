# Background chat commands (experimental WeChat 4.x adapter)

The chat adapter never activates an application, raises a window, moves the mouse,
or uses global keyboard events. It rejects `--activate` and always installs a
background-only input context, even if another RPC client enabled activation.

```sh
cua open-chat --app com.tencent.xinWeChat --name 'Codex 零号远征队' --limit 12
cua read-chat --app com.tencent.xinWeChat --name 'Codex 零号远征队' --limit 12
cua search-text --app com.tencent.xinWeChat --text '文件传输助手'
cua send --app com.tencent.xinWeChat --chat '文件传输助手' --text 'test'
```

RPC methods: `searchText`, `openChat`, `readChat`, `sendText`. Parameters are
`app`, optional `sessionId`, `name` (open/read), `text` (search/send), `chat`
(send), and `limit` (1–100). CLI automatically handshakes and propagates sessionId.
The installed service must be rebuilt/deployed to support these new methods;
this change does not replace or restart an installed user service.

## Safety and verification

* Only `文件传输助手` and `knight` are permitted send targets. There is deliberately
  no group-send override. Low-level pre-existing APIs are not a chat authorization
  boundary; callers must not use them to bypass the chat adapter policy.
* Send rejects unapproved targets **before navigation or text mutation**.
* Inline chat validation requires an exact composer title plus a message list in
  the same AXWindow. Detached chat windows require an exact window title and an
  `输入` composer. Names are UI labels, not cryptographically verified identities.
* A pre-existing composer draft is never overwritten. Return is sent once only;
  success requires a new exact message label and an empty composer. Verification
  failure means **delivery unknown**. Do not retry automatically.
* Search uses semantic AX field discovery, AXValue/read-back, AXFocused/read-back,
  and PID-scoped End/Space/BackSpace. Open selects a unique exact first-line result
  and tries AXPress, then guarded Down/Return. Any existing draft blocks navigation
  Return. An AX success status alone never proves that navigation happened.
* NSWorkspace and System Events foreground names/PIDs are recorded at every
  primitive boundary. Changes abort the operation. Samples cannot prove that no
  transient foreground change happened between boundaries, nor prevent unrelated
  user/client operations. Do not run concurrent GUI automation during validation.
* `read-chat` only reads an already verified open chat; it does not navigate.
* `messages` contains nonempty exposed AX row labels in order; WeChat sometimes
  returns empty virtualized rows, timestamp separators, or omits sender identity.
  `sender` is absent when not exposed, never guessed. The last 12 exposed labels
  are not necessarily the latest 12 actual messages. No scrolling-to-bottom is
  claimed. `capturedAt` is the observation time, not the message send time.

## Current limitations

Live testing on 2026-10-29 did **not** reproduce the previously reported background
search opening path. AX writes and focus read-backs succeeded, but targeted keys
and AXPress had no verified navigation effect. The adapter fails closed and does
not fall back to foreground operation. Read-back of a detached `knight` window
worked. Target group reading and a verified send remain unvalidated; see
[validation record](<VALIDATION.md>).
