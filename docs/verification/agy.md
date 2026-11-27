# Verification: the agy (Antigravity CLI) full harness adapter

Active empirical facts for firstmate's agy adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/agy.md`](../../.agents/skills/harness-adapters/references/harness/agy.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `agy 1.2.0`; the send-confirmation timing below was re-measured on `agy 1.2.1` (2026-09-12) |
| Verified | 2026-09-10 |
| Binary | `/home/andpod/.local/bin/agy`, an ELF 64-bit Go-compiled single executable |
| Platform | Linux x64 (Arch, kernel 7.2.3) |
| Backend | Herdr, in an isolated non-`default` lab session (`fm-lab-firstmate-agy-ad-*` via `bin/fm-herdr-lab.sh`); the live `default` session was unchanged throughout |

Every command below ran inside the disposable firstmate task worktree or the named Herdr lab session.
No captain fleet state was touched.

## Detection: ancestry only, no marker

```
$ agy --version
1.2.0
```

A live TUI's `/proc/<pid>/environ` carries no `AGY_*` or `ANTIGRAVITY_*` variable.
It does carry `AGENT=1` and `CLAUDECODE=1`, both inherited from the launching environment, so neither is an agy identity and neither is promoted to a marker.
Herdr's `pane process-info` for the same pane reports the foreground process as `name=agy` with `argv=["agy", ...]`, and `ps -o comm=` reports `agy`.
`bin/fm-harness.sh` therefore matches the anchored process name `agy` alone, and the spawn clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `FM_PI_HARNESS` at the launch boundary.
`tests/fm-agy-harness.test.sh` pins the anchored match, the rejection of unrelated names containing the fragment, and that an inherited `CLAUDECODE` never outranks a real `agy` ancestor once the spawn clears it.

## Launch: positional prompt-interactive with auto-submit

```
$ agy --prompt-interactive "Reply with exactly AGY_LIVE_PROBE_OK and nothing else" --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions
```

The brief submitted itself with no extra Enter, the turn ran, and the reply rendered in the pane.
A second launch into the same directory answered a fresh prompt the same way, so the shape is repeatable, not a first-run accident.
The footer rendered `Gemini 3.8 Flash · low`, proving both flags were accepted together.

## Trust dialog: pre-registered before launch, gated on a busy turn as the backstop

A first launch in a fresh worktree shows this dialog:

```
Accessing workspace:

/home/andpod/.treehouse/firstmate-7bab20/1/firstmate/agy-probe-tmp

Do you trust the contents of this project?

Antigravity CLI requires permission to read, edit, and execute files here.

> Yes, I trust this folder
  No, exit
```
`agy --help` (1.2.0) lists no trust flag or pre-registration command, but agy honours a `trustedWorkspaces` entry written to `~/.gemini/antigravity-cli/settings.json` ahead of launch.
Verified under a throwaway `HOME` holding a copy of `~/.gemini` (the real settings file was never written): a folder appended to that array by hand launched `--prompt-interactive` straight into its turn and rendered the reply with no dialog, while an unregistered sibling folder launched the same way parked on the dialog.
agy compares the pane's logical working directory, not its resolved path: a symlinked cwd whose real path alone was registered still parked on the dialog, so `bin/fm-agy-trust.sh` records both the logical path and its resolved form when they differ.
`bin/fm-spawn.sh` runs that helper before launch at the same point it pre-registers claude trust; the helper applies the same structural scope test (a linked worktree of the spawning project, never a primary checkout, a subdirectory, a plain directory, or the home directory), preserves every other key in the store, and writes atomically with a fingerprint check.
A failed registration is a stderr warning rather than a refusal, because agy's dialog preselects the safe answer and the gate below can answer it.
Two supervised Herdr runs in treehouse worktrees completed file-writing turns while the dialog was still unanswered at observation time (worker file and `done:` status line both verified on disk before Enter was ever sent to those panes).
Isolated runs in untrusted `/tmp` directories never reached the workspace until Enter: the turn spun through exploratory tool calls in agy's own scratch directory instead, and only the queued prompt ran after the answer.
One run left unanswered for several minutes wrote its file to agy's scratch directory instead of the workspace once finally answered.
The mechanism behind the difference was not established; path, backend, and latency were all varied across runs without isolating a single cause.
The spawn therefore does not depend on it: after pre-registration, `bin/fm-spawn.sh` runs a post-launch readiness gate (`agy_wait_for_working`) in the rovo/kimi launch-then-confirm shape as the backstop.
It polls the pane capture, answers the dialog with a single Enter the first time the `Do you trust the contents of this project?` text renders, and reports success only once `fm_busy_classify` returns a busy verdict for the pane (Herdr's native `working` status or the pinned `esc to cancel` status row).
Because Herdr's native `working` verdict is known to coexist with an unanswered dialog, the gate is strict about order: a busy verdict counts as ready only when the worktree was pre-registered before launch or the dialog has already been seen and answered; on an unregistered path it keeps polling for the dialog instead of accepting the early busy verdict.
When the brief cannot be confirmed to run within the window (an answered dialog never turns busy, a pre-trusted pane never turns busy, or an unregistered pane never shows the dialog), the spawn fails, records `failed:` in the task status, and closes the endpoint so no orphan worker survives outside task control.
`tests/fm-agy-harness.test.sh` covers the helper's registration and scope refusals against a throwaway store, and drives a fake pane whose dialog decision reads the store the spawn just wrote: the pre-trusted launch with no dialog, a dialog that renders anyway answered exactly once, the premature busy verdict on an unregistered path waiting for the dialog, and both fail-and-close paths.

## Model and effort

```
$ agy models
Fetching available models...
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
...
```

`agy --help` documents `--effort` as `low|medium|high` and `--model` as the model for the session.
The bare `gemini-3.8-flash` id from this home's previous config is not listed; only the suffixed `-high`, `-medium`, and `-low` variants are.
`bin/fm-spawn.sh`'s `agy_model_validate` refuses a requested id a reachable `agy models` listing omits, and launches unvalidated with a stderr notice when the listing is unreachable.
The listing is a remote fetch (`Fetching available models...`), so the probe runs with stdin detached under the shared hard bound from `bin/fm-timeout-lib.sh` (15 seconds by default, `FM_AGY_MODELS_TIMEOUT`; a non-positive or non-numeric value clamps back to that default); a stalled fetch or a sign-in prompt is cut off and falls through to the unvalidated launch instead of blocking the spawn before any pane exists.
Print mode (`agy -p "Reply with exactly: AGY_PRINT_PROBE_OK" --model gemini-3.8-flash-low`) returned the exact reply with exit 0 in about 8 seconds, proving the credential path without a pane.

## Busy state: the pinned status row, unknown on absence

Mid-turn the pane rendered the status row and a spinner line at once:

```
⣯  Generating...
└ Tip: When reviewing a file edit, press f to see the full diff.
...
esc to cancel                                                           Gemini 3.8 Flash · low
```

The completed turn showed the reply, then the idle composer:

```
>
──────────────────────────────────────────────────────────────────────────────
? for shortcuts                                                         Gemini 3.8 Flash · low
```

`fm_busy_agy_tail_busy` and the delivery guard in `bin/fm-composer-lib.sh` match the `esc to cancel` token alone: the TUI pins that status row to the bottom of the pane for the whole turn, and the idle row replaces it with `? for shortcuts`.
The `Generating...` spinner word is deliberately not a signal: it is a free-floating output line, so ordinary worker output such as `Generating report...` would otherwise classify an idle worker as busy or acknowledge a submit that did not land.
No busy phase without the status row was observed live; every captured mid-turn frame carried it.
`fm_busy_classify` reports `unknown agy-regex` when the token is absent, because a long turn can scroll the marker out of the captured tail.
The signature is hardcoded with no environment override, so a stray variable can never change worker-state classification.
Herdr's own registry agreed throughout: `agent get` reported `agent_status=working` mid-turn and `idle` after, so on Herdr the native verdict carries busy with no new code.

## Interrupt and exit

A single `Escape` sent mid-turn through `herdr pane send-keys` cancelled it and printed this row, with the composer back at idle and no repolluted text:

```
  ⎿  Interrupted · What should Antigravity CLI do instead?
```

Sending `/quit` plus Enter exited the process; the pane closed under the `exec` launch, and Herdr reported the pane gone.
`bin/fm-control-lib.sh` records `Escape` once, no clear key, no ack source, and `/quit` for agy.

## Backend liveness: Herdr recognizes agy, tmux names it

```
$ herdr agent get w2:p1 --session fm-lab-firstmate-agy-ad-1599574-8823
{"result":{"agent":{"agent":"agy","agent_status":"idle",...,"agent_session":{"agent":"agy","kind":"id","source":"herdr:antigravity_cli",...}}}}
```

Herdr tracks agy natively (`antigravity-cli` integration, detected as `agent=agy`), so `fm_backend_herdr_pane_agent_state` returns `live` for every registered agy status and no exit-detection hardening was needed.
The tmux adapter classifies the anchored process name `agy` as `agent` through the shared name vocabulary in `bin/fm-agent-process-lib.sh`, the muse/omp precedent for short bare-word names.
agy is included in the session-lock name vocabulary in `bin/fm-session-lock-lib.sh` (`FM_HARNESS_RE` and `FM_HARNESS_NAMES`), recognizing an agy ancestor process as a verified session-lock holder.

## Composer: unknown by design

Byte-level capture of the idle pane shows a bare unstyled `>` between two full-width `─` rules, with an unstyled `? for shortcuts` cell and a dim (`SGR 2`) model cell in the status row below.
The shared classifier reads that bare `>` as `unknown` under the dead-shell rule, never `empty`.
Steering still confirms delivery: the Herdr submit core leads with the native `idle`-to-`working` transition, which agy performs, and the delivery footer regex covers the tmux path.
agy renders the busy footer late for that confirm loop - about 1.5 s after Enter for a short steer and 4-5 s for a realistic longer brief, measured live on `agy 1.2.1` (2026-09-12) against the shared budget's 3 x 0.4 s - so `bin/fm-send.sh` gives agy typed targets a longer default submit-confirm budget (20 retries, about 8 s at the default cadence); an explicit `FM_SEND_RETRIES` still wins and every other harness keeps the shared 3-retry default.
`tests/fm-send-agy-confirm.test.sh` pins the raised default and `tests/fm-agy-harness.test.sh` pins the Herdr transition path.
This is the cursor precedent, not a gap to patch in shared code.

## Supervised task: spawn, steer, relaunch, and exit through the new path

A trivial scout ran end to end through `bin/fm-spawn.sh --harness agy` against the same isolated lab session: `spawned agy-e2e1 harness=agy kind=scout` with a treehouse-provisioned worktree, `--model gemini-3.8-flash-low`, and `--effort low` all recorded in task metadata.
The worker wrote its worktree file and appended `done: agy e2e turn complete` to its status file, which lives outside the worktree, proving prompt processing, tool execution, outside-workspace file access, and a new completion event.
Durable steering held: a `bin/fm-send.sh` message landed in the task inbox, the worker appended the steered lines to both files, and its inbox record moved to `handled/`.
Same-copy relaunch held: `bin/fm-control.sh relaunch --note` replaced the worker in place on the identical worktree, model, and effort, the replacement verified both prior lines intact and appended `relaunched: done`.
Exit held: `bin/fm-control.sh exit` stopped the worker, the registry returned `agent_not_found`, and the pane remained a lone shell in the worktree with all work intact.
No automatic quota failover was exercised or claimed; every handoff above was an explicit supervised relaunch.

## Primary and secondmate integration

Primary and persistent secondmate execution is verified through native `.agents/hooks.json` integration.
Session-open digest injection is implemented by `bin/fm-sessionstart-agy.sh` on the `SessionStart` event.
PreToolUse seatbelts enforce execution safety through `bin/fm-arm-pretool-check.sh --agy`, `bin/fm-cd-pretool-check.sh --agy`, and `bin/fm-subagent-pretool-check.sh --agy`.
In primary and secondmate homes, watcher commands are classified by the shared arm-command policy, `cd` commands are denied in favor of absolute paths or `cwd`, and subagent invocations (`invoke_subagent`, `define_subagent`) are denied while inspection tools (`manage_subagents`, `manage_task`) remain permitted.
Supervision continuity uses synchronous Stop-hook parking via `bin/fm-turnend-guard-agy.sh`, running `bin/fm-watch-arm.sh` (or the supervision host) which waits under the 28800s hook timeout until woken by an incoming event (bounded only when the optional `FM_AGY_PARK_TIMEOUT` is set) and falls back to bounded repair nagging via `bin/fm-turnend-guard.sh --agy`.
Session lock verification recognizes `agy` process ancestry via `bin/fm-session-lock-lib.sh`.

## agy 1.5.16 on macOS: the `antigravity` executable and per-model effort

Verified 2026-11-26 on macOS (Apple silicon) with `agy 1.5.16` from Homebrew and T3 Code `0.1.11+fork.1`.

The Homebrew `agy` command is a wrapper script that runs `exec ".../Caskroom/antigravity-cli/1.5.16,.../antigravity" "$@"`, and T3 Code's Antigravity ACP server is a different build of the same executable name:

```
$ ps -o ucomm=,args= -p <standalone print-mode pid>
antigravity      /opt/homebrew/Caskroom/antigravity-cli/1.5.16,5250855658717184/antigravity -p Reply with exactly OK --model gemini-3.8-flash-low
$ ps -o comm= -p <T3 ACP pid>
/Users/<user>/.t3/tools/antigravity-acp/darwin-arm64/versions/33f5617d.../antigravity
$ ps -o args= -p <T3 ACP pid>
/Users/<user>/.t3/tools/antigravity-acp/darwin-arm64/versions/33f5617d.../antigravity acp --gemini-dir ...
```

So the exact name `antigravity` identifies agy in the harness, session-lock, and agent-process vocabularies, and only the `acp` subcommand selects ACP supervision in `bin/fm-turnend-guard-agy.sh --capable`.
The patched classifiers were run against the live T3 ACP process: `fm_agent_process_classify_name` printed `agent` and `fm_harness_process_matches` matched.
`tests/fm-agy-harness.test.sh` and `tests/fm-agy-primary.test.sh` pin both shapes with real processes, including the standalone executable keeping Stop-hook parking.

`agy models` now lists level-suffixed ids per model (`gemini-4-neon-low|medium|high|xhigh`, `gemini-3.8-flash-low|medium|high`), and agy validates `--effort` against the model before any turn runs.
Each line below is `agy -p "Reply with exactly AGY_EFFORT_OK and nothing else" --output-format json` with the shown flags:

| Flags | Result |
|---|---|
| `--model gemini-4-neon --effort xhigh` | exit 0, `AGY_EFFORT_OK` |
| `--model gemini-4-neon --effort low` | exit 0, `AGY_EFFORT_OK` |
| `--model gemini-4-neon-xhigh` | exit 0, `AGY_EFFORT_OK` |
| `--model gemini-4-neon-high --effort high` | exit 0, `AGY_EFFORT_OK` |
| `--model gemini-4-neon-low --effort xhigh` | exit 1, `--model gemini-4-neon-low conflicts with --effort=xhigh` |
| `--model gemini-4-neon-high --effort max` | exit 1, `--model gemini-4-neon-high conflicts with --effort=max` |
| `--model gemini-4-neon --effort max` | exit 1, `gemini-4-neon has no "max" effort (available: low, medium, high, xhigh)` |
| `--model gemini-3.8-flash --effort xhigh` | exit 1, `gemini-3.8-flash has no "xhigh" effort (available: low, medium, high)` |

`bin/fm-spawn.sh` therefore accepts the unlisted family id, passes only a level agy accepts for the requested model, and records any other level in task metadata without passing it; `tests/fm-agy-harness.test.sh` pins each row's decision against a fake listing.

On T3 Code the Antigravity catalog names the reasoning option `thought_level` (role `reasoning`), not the older `thinking_level`.
`bin/fm-t3-mcp.mjs resolve-selection --harness agy --instance antigravity` against the live server resolved `gemini-4-neon` with `high` and `xhigh` to `thought_level`, resolved `gemini-4-neon-xhigh` to `gemini-4-neon` plus `thought_level: xhigh`, and omitted `max` with its notice.
An idle `launch` with `{"model":"gemini-4-neon","options":[{"id":"thought_level","value":"xhigh"}]}` passed the helper's binding read-back and was then archived (`closed: true`), so T3 binds the level a firstmate agy launch requests.

The TUI keeps the 1.2.0 signals: mid-turn the bottom row is `esc to cancel` beside `auto · Gemini 3.8 Flash · low`, and the settled row is `? for shortcuts`.
In a tmux pane `#{pane_current_command}` reports `antigravity`, which the agent-process classifier previously read as `other`, so tmux liveness would have treated a live macOS agy worker as gone.
A fresh workspace still parks on `Do you trust the contents of this project?`, and the turn does not start until it is answered.
`--settings '{"trustedWorkspaces":["<path>"]}'` trusts a folder for one session without writing `~/.gemini/antigravity-cli/settings.json` (byte-compared before and after).
Under a throwaway `HOME` holding a copy of `~/.gemini`, macOS agy is signed out and renders `Welcome to the Antigravity CLI. You are currently not signed in.` with `Select login method:`, because its login is not stored under `~/.gemini` there.

```
$ FM_AGY_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-agy-signals-live-e2e.test.sh
ok - the real agy worker processed its launch prompt
ok - tmux liveness reads the live agy pane command 'antigravity' as an agent
ok - the real agy busy footer matches fm_busy_agy_tail_busy on a long turn
ok - a single Escape cancels the real agy turn
ok - /quit stops the real agy process
```

## Antigravity ACP turns around a long command

Verified 2026-11-27 on macOS (Apple silicon) against `agy acp` 1.5.16, the same version as the T3 Code Antigravity ACP server then running (`.../antigravity-acp/darwin-arm64/versions/33f5617d.../antigravity --version` printed `1.5.16`), with model `gemini-3.8-flash`.
This is the evidence behind `docs/supervision-protocols/agy-acp.md`'s silent in-turn checkpoint chain.

The bundled `run_command` tool description says `WaitMsBeforeAsync` goes "up to 10000" and that "Commands that do not finish within the specified wait time continue running in the background as tasks; the system will notify you when they finish, so do not poll their status or set timers to check on them."

One prompt asking for two sequential `sleep 40` commands, then exactly `PROBE_END`:

```
$ acpx --agent "agy acp --dangerously-skip-permissions" --cwd <scratch> --approve-all --format json --model gemini-3.8-flash --timeout 380 exec "<prompt>"
tool_call  sleep 40; echo PROBE_ONE_DONE  {"WaitMsBeforeAsync": 10000}  in_progress
agent_message_chunk  "I have launched the probe command and will wait for it to complete."
tool_call_update  sleep 40; echo PROBE_ONE_DONE  completed  "PROBE_ONE_DONE"
tool_call  sleep 40; echo PROBE_TWO_DONE  {"WaitMsBeforeAsync": 10000}  in_progress
tool_call_update  sleep 40; echo PROBE_TWO_DONE  completed  "PROBE_TWO_DONE"
agent_message_chunk  "PROBE_END"
session/prompt result  {"stopReason": "end_turn"}   (one result, about 120s after the prompt)
```

Both commands went to the background at the 10-second cap, the model stopped generating between them (once with a text message, once with none), and each completion resumed the same `session/prompt` rather than ending it.
The model still called `manage_task` status several times despite the no-poll instruction.

A raw JSON-RPC client then sent one prompt running `sleep 60` and, 25 seconds later while the model waited with no text, a second `session/prompt` asking for exactly `SECOND_SEEN`:

```
7.5s   tool_call  sleep 60; echo FIRST_DONE  {"WaitMsBeforeAsync": 10000}  in_progress
26.2s  send session/prompt (second)
26.2s  first session/prompt result  {"stopReason": "end_turn"}
33.8s  agent_message_chunk  "SECOND_SEEN"
67.7s  tool_call_update  sleep 60; echo FIRST_DONE  completed
74.8s  agent_message_chunk  "END_ONE"
74.9s  second session/prompt result  {"stopReason": "end_turn"}
```

A new prompt ends a turn that is waiting on a background command at once, the command keeps running, and its completion arrives in the new turn.

## What is still unproven

The signed-out screen is now observed (above), but the spawn has no detector for it; any auth prompt stays a credential blocker, not a handled dialog.
No slash-skill invocation form was verified, so skill invocation stays natural language.
`--continue` and `--conversation` resume were never exercised; recovery uses deterministic relaunch from the brief on disk.
No supervised `bin/fm-spawn.sh` agy task was run on agy 1.5.16 or on macOS; the supervised-task evidence above is agy 1.2.0 on Linux, and the 1.5.16 evidence stops at the live guard.
A full agy turn on T3 with a non-default `thought_level` was not run; the evidence above stops at the bound selection.
The ACP turn evidence above drove `agy acp` directly, not through T3 Code, so how T3 delivers a captain message to a running Antigravity turn was not observed.

## Refreshing this record

Run the portable suite and the live guard after any agy upgrade, because the process name, marker set, trust dialog text, and rendered busy/interrupt text are all vendor-controlled surfaces that the spawn gate and the busy fallback match verbatim:

```
bin/fm-test-run.sh tests/fm-agy-harness.test.sh
FM_AGY_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-agy-signals-live-e2e.test.sh
```
