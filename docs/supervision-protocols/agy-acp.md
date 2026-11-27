<!-- fm:supervision-protocol:v3 harness=agy-acp -->
Mode: Antigravity ACP foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one bounded watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
   Antigravity ACP waits at most 10 seconds for a command, so the checkpoint continues as a background task: stop generating with no text, and its completion notification resumes this same turn.
   Do not poll it with `manage_task` or `command_status`, and never start a second checkpoint while one is still running.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. Empty checkpoint: if the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway and handle anything the drain presents, then start the next checkpoint in this same turn and stop again with no text.
   An empty checkpoint is not a no-op that needs an answer: never reply `Captain, shipshape.` or any other captain-facing text for it.
   If Antigravity ACP will not end a step without text, write exactly `(supervising)` and nothing else.
6. A captain message ends the waiting turn and starts a new one while the checkpoint keeps running.
   Answer it, then stop with no further text; the running checkpoint's completion arrives in that turn, so do not start another.
   If a new checkpoint reports `watcher is already running` while your earlier one is still running, wait for that one instead of treating it as a failure.
7. Never use shell `&` for firstmate watcher supervision, and do not rely on `.agents/hooks.json` `Stop` hooks to park a turn boundary.
   Antigravity ACP (`agy_acp_server.par` or `antigravity acp`) runs `Stop` hooks only on `session_end` and ignores `{"decision":"continue"}`, so ending a turn with no checkpoint running leaves supervision parked nowhere.
8. Do not run `bin/fm-watch-arm.sh` as Antigravity ACP's normal supervision command.
   If the workspace hooks are trusted, a backgrounded, piped, or bundled watcher anti-pattern is denied automatically by the `PreToolUse` seatbelt (`bin/fm-arm-pretool-check.sh --agy`) registered in `.agents/hooks.json`.
9. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh checkpoint.

The bounded checkpoint returns control regularly so queued wakes are drained without standalone `agy` CLI Stop-hook parking, and a captain message never waits on it.
