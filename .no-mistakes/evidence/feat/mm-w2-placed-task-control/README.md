# W2 placed-task live validation

Oracle: the supplied Phase 2 W2 intent and `docs/remote-workers.md`: host-owned durable inbox with supervisor delivery identity, retry/resend deduplication, host-owned state and capture, unknown rather than dead on transport failure, remote interrupt/exit and question answering, approvals retained in T3.

## Surfaces actually executed

- Real Firstmate supervisor CLI -> `fm-on.sh` -> local transport boundary adapter -> real `fm-remote-worker-control.sh` -> ordinary real host CLI.
- Real tmux private `fm-lab` socket, 140x42 terminal, actual logged-in Claude CLI worker. No fake CLI or fake tmux. Delivery records were read from the host inbox; Claude consumed the records. Interrupt returned verified agent-alive; exit returned stopped and left the worker shell intact.
- Real isolated T3 0.1.7+fork.1 server, fresh disposable server data and OAuth grant, actual Claude provider. A native question was answered through placed-task `fm-t3-answer`, the request disappeared, and the assistant emitted `LABEL_BETA_CONFIRMED`. A separate approval-required thread produced a real permission approval: the answer CLI refused it, the approval remained pending, and the proposed file was not written.
- The local T3 state check used a synthetic blocked status record describing the observed pending question, as a normal worker/watcher would record it; the real T3 busy probe and host crew-state reconciliation ran. Supervisor output preserved the host's blocked reading.

The transport adapter decodes `fm-on`'s actual argv stream and executes the real host commands locally. It simulates SSH 255 before delivery and after a completed host write; it does not emulate the worker, backend, inbox, or T3 server. **This proves local orchestration, not real SSH connectivity, M1 setup, or production fleet behavior.** W2 explicitly requires no M1.

## Evidence

- `local-cli-transcript.log`: real steering, automatic lost-result retry, unconfirmed resend carrying the same delivery ID, delayed decision closure, invalid ID/raw-key/relaunch refusals, unknown transport outcomes, state/peek and real interrupt/exit.
- `durable-inbox.txt`, `decision-status.txt`: owned durable-record contracts, not implementation-source assertions.
- `claude-before-control.html`, `claude-after-interrupt.html`, `claude-after-exit.html`: rendered actual terminal captures.
- `t3-local-transcript.log`: actual T3 question, host state/capture, answer consumption, and adversarial approval boundary.
- `t3-question-{before,after}.json`, `t3-approval-{before,after}.json`: actual product responses.
- `t3-thread.html`: rendered completed thread capture, including the assistant's confirmation (not merely the marker in the user prompt).
- `targeted-tests.log`: three focused behavioral suites using fake SSH/backend boundaries; these are supplemental tests, not themselves live execution.
- `cleanup.txt`, `t3-server.log`: private tmux stopped, T3 threads archived without active runs, server shutdown awaited, isolated roots removed, no remaining processes referencing them. Startup pairing output was omitted.

Initial fixture issues (trust dialog selection, tmux target index, maintaining a shell after CLI exit, and supplying a worker status record) were corrected and scenarios re-driven. An approval-waiting provider's session-stop returned unconfirmed during teardown; subsequent archive confirmed no active run and server shutdown confirmed provider sessions stopped. No product repair was needed. Drivers are retained as `drive-local-cli.py` and `drive-local-t3.py`; they originally ran from this worktree and removed their fixtures in `finally` blocks. The worktree is clean.
