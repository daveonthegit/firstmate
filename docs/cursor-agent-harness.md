# Cursor Agent crewmate harness

This is the crewmate-era empirical record, captured on 2026-07-23 against Cursor Agent `2026.07.20-8cc9c0b`, when Cursor was verified for crewmate and scout dispatch only.
Cursor is now a verified primary and secondmate harness as well, and its launch command, model handling, and composer classification have all changed since this capture.
[`verification/runtime-backends.md`](verification/runtime-backends.md#cursor-agent-cli) owns the current evidence and supersedes any launch, effort, or composer detail below.
The launch, profile, and task-local trust mechanics live in `bin/fm-spawn.sh`.
The operational recovery facts live in `.agents/skills/harness-adapters/SKILL.md`.

## Historical launch (2026-07-23)

The crewmate-era probe invoked the explicit `agent` entry point and launched an interactive session with this shape:

```sh
agent --force --trust --workspace "<isolated-task-directory>" --model "<mapped-model-id>" "<launch-brief>"
```

`--force` is the captain-approved unattended command posture for Firstmate-launched Cursor workers.
`--trust` is scoped by the accompanying `--workspace` argument to the isolated task directory.
The adapter never edits `~/.cursor/cli-config.json` or any other global Cursor setting.
A positional prompt starts the first turn and the TUI stays open for follow-ups.

The [Cursor adapter reference](../.agents/skills/harness-adapters/references/harness/cursor.md#operating-facts) owns current model validation and effort mapping; the dated catalog capture below is evidence, not a supported-model inventory.

## Current supervision

The [Cursor adapter reference](../.agents/skills/harness-adapters/references/harness/cursor.md) owns current transcript busy-state, composer, delivery, and primary-hook behavior; the captures below predate those integrations.

## Historical interrupt, exit, and resume (2026-07-23)

That build advertised `Ctrl+C` as the active-turn interrupt.
An automated PTY probe sent one `Ctrl+C` while token counts were increasing, but generation continued to completion.
In that build, an idle first press changed the TUI into the `Press Ctrl+C again to exit` state, so repeating `Ctrl+C` could exit rather than interrupt.
The [Cursor adapter reference](../.agents/skills/harness-adapters/references/harness/cursor.md#operating-facts) owns current interrupt, exit, and relaunch guidance.

The observed idle exit required two key presses:

1. Send `Ctrl+C` once.
2. Verify `Press Ctrl+C again to exit` is visible.
3. Send `Ctrl+C` once more.

The clean-exit banner printed `agent --resume=<chat-id>`.
The historical recovery command was `agent --force --trust --workspace <path> --resume=<chat-id>`, with `agent --continue` advertised for the most recent workspace session.

## Runtime backend review

[`verification/runtime-backends.md`](verification/runtime-backends.md#cursor-agent-cli) owns current backend verification, including primary and secondmate support; the earlier process capture below does not describe the current attribution rule.

## Empirical verification

Verification date: 2026-07-23.
Cursor Agent version: `2026.07.20-8cc9c0b`.
Host: macOS arm64.
The observations below incorporate the completed private verification report and the follow-up tmux integration probes run from this implementation branch.

### Version, authentication, and invocation

Commands:

```sh
which agent cursor
agent --version
cursor agent --version
agent status
agent about
```

Observed results, with the absolute home prefix normalized to `$HOME`:

```text
$HOME/.local/bin/agent
$HOME/.local/bin/cursor
2026.07.20-8cc9c0b
2026.07.20-8cc9c0b
✓ Logged in as <redacted account>
CLI Version         2026.07.20-8cc9c0b
Model               Cursor Grok 4.5 High
Subscription Tier   Team
```

One-shot prompt command:

```sh
agent --print --model cursor-grok-4.5-low --trust --workspace "$(pwd)" \
  "Reply with exactly the four characters PONG and nothing else."
```

Observed stdout was exactly `PONG` with exit status 0.
The equivalent `cursor agent --print ...` probe returned exactly `CURSOR_AGENT_OK` with exit status 0.

### Model catalog

Commands:

```sh
agent --help
agent models
```

`agent --help` advertised `--model <model>` and no separate `--effort` option.
Re-verified on 2026-08-18 with `cursor-agent --list-models` under CLI version `2026.08.04-aaa8809`, which listed these exact Cursor Grok entries:

```text
cursor-grok-4.6-high-fast - Cursor Grok 4.6 Fast
cursor-grok-4.6-low - Cursor Grok 4.6 Low
cursor-grok-4.6-low-fast - Cursor Grok 4.6 Low Fast
cursor-grok-4.6-medium - Cursor Grok 4.6 Medium
cursor-grok-4.6-medium-fast - Cursor Grok 4.6 Medium Fast
cursor-grok-4.6-high - Cursor Grok 4.6
cursor-grok-4.6-xhigh - Cursor Grok 4.6 Extra High
cursor-grok-4.6-xhigh-fast - Cursor Grok 4.6 Extra High Fast
cursor-grok-4.5-high - Cursor Grok 4.5
cursor-grok-4.5-high-fast - Cursor Grok 4.5 Fast
cursor-grok-4.5-low - Cursor Grok 4.5 Low
cursor-grok-4.5-low-fast - Cursor Grok 4.5 Low Fast
cursor-grok-4.5-medium - Cursor Grok 4.5 Medium
cursor-grok-4.5-medium-fast - Cursor Grok 4.5 Medium Fast
```

The capture listed both the 4.5 family and a distinct non-fast 4.6 id per effort rung.
The catalog also included model families whose effort is encoded in ids such as `-xhigh` and `-max`, plus parameterized model bracket overrides.
The [Cursor adapter reference](../.agents/skills/harness-adapters/references/harness/cursor.md#operating-facts) owns selection from this catalog.
Ids drift: re-run `cursor-agent --list-models` before relying on this dated sample.

### Interactive tmux supervision

Command typed into a scratch tmux window, in Cursor's default mode - no `--mode` flag, matching the shipped launch template:

```sh
agent --force --trust --workspace "$PWD" \
  --model cursor-grok-4.5-low 'Reply with exactly PONG.'
```

Observed busy capture:

```text
⠀⠞ Working
→ Add a follow-up                                             ctrl+c to stop
Cursor Grok 4.5 Low                                           Run Everything
```

Observed idle capture:

```text
PONG
→ Add a follow-up
Cursor Grok 4.5 Low · 15.8%                                   Run Everything
```

The shared tmux composer classifier returned `empty` for that idle pane.
The first idle `Ctrl+C` produced exactly `Press Ctrl+C again to exit`.
The second `Ctrl+C` returned the pane to `zsh`.

#### Default-mode re-capture (2026-07-28)

The signatures above were first captured with `--mode ask`, which the shipped launch template does not pass.
They were re-captured on 2026-07-28 with Cursor Agent `2026.07.20-8cc9c0b` on macOS arm64 in default mode, and are identical.
The busy row is `⠀⠞ Working`, with `ctrl+c to stop` rendered on the `→ Add a follow-up` composer row; the idle composer row is `→ Add a follow-up`; `pane_current_command` is `node`.
The only difference is that default mode omits the ask-mode-only `Ask (shift+tab to cycle)` line.
That line is cosmetic mode signage and is never used as a classifier signature, so both the busy signature (`ctrl+c to stop`) and the idle placeholder (`Add a follow-up`) hold in the mode the adapter actually launches.

### tmux process identity

Commands:

```sh
tmux display-message -p -t "$session:cursor" '#{pane_current_command}'
tmux display-message -p -t "$session:cursor" '#{pane_tty}'
ps -t "${tty#/dev/}" -o pid=,ppid=,pgid=,comm=,args=
```

The exact current-command output was `node`.
The foreground argv began with:

```text
$HOME/.local/bin/agent --use-system-ca $HOME/.local/share/cursor-agent/versions/2026.07.20-8cc9c0b/index.js --force --trust --workspace ...
```

This capture established the generic `node` name's ambiguity; [current tmux attribution](tmux-backend.md#agent-liveness-probe) uses structural executable identity instead of treating this historical name as the complete evidence.

### Workspace trust and permissions

Without `--trust`, a fresh workspace displayed this blocking modal:

```text
⚠ Workspace Trust Required
Cursor Agent can execute code and access files in this directory.
Do you trust the contents of this directory?
▶ [a] Trust this workspace
  [q] Quit
```

`q` exited cleanly.
`agent --help` documented `--force` and its `--yolo` alias as force-allowing commands unless denied.
The probed launch used `--force` explicitly without altering global approval configuration.
