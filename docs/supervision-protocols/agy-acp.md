<!-- fm:supervision-protocol:v3 harness=agy-acp -->
Mode: Antigravity ACP foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one bounded watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
   If Antigravity ACP sends the running command to the background, wait reactively for its completion notification instead of polling in a loop.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, handle any queued captain message now visible, then start the next checkpoint.
6. Never use shell `&` for firstmate watcher supervision, and do not rely on `.agents/hooks.json` `Stop` hooks to park a turn boundary.
   Antigravity ACP (`agy_acp_server.par`) runs `Stop` hooks only on `session_end` and ignores `{"decision":"continue"}`, so a turn that ends without an active checkpoint leaves supervision parked nowhere.
7. Do not run `bin/fm-watch-arm.sh` as Antigravity ACP's normal supervision command.
   If the workspace hooks are trusted, a backgrounded, piped, or bundled watcher anti-pattern is denied automatically by the `PreToolUse` seatbelt (`bin/fm-arm-pretool-check.sh --agy`) registered in `.agents/hooks.json`.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh checkpoint.

The bounded checkpoint returns control regularly so captain messages and queued wakes are handled without relying on standalone `agy` CLI Stop-hook parking.
