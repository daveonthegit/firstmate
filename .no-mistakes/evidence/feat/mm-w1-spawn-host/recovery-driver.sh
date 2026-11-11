#!/usr/bin/env bash
set -eu
ROOT="$PWD"; E=~/.no-mistakes/evidence/01M74AZP4ES3P09BD6H6CSXGGX
exec > "$E/live-recovery.log" 2>&1
trap 'printf "RECOVERY_EXIT=%s\n" "$?"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_SOCKET_PATH FM_BACKEND FM_GATE_REFUSE_BYPASS
P="$ROOT/.live/recovery"; H="$ROOT/.live/host"
"$ROOT/bin/fm-lab-home.sh" create "$P"
export FM_HOME="$P" FM_SSH_BIN="$ROOT/.live/loopback-ssh" FM_PROCEVENT_CLAIM_ROOT="$ROOT/.live/claims" FM_SPAWN_NO_GUARD=1
# New task shells acquire their disposable pool inside the worktree.
tmux set-environment -g TREEHOUSE_ROOT "$ROOT/.live/pool"
printf 'root = "%s"\n' "$ROOT/.live/pool" > "$H/projects/sample/treehouse.toml"
printf 'sample 5\n' > "$H/config/project-capacity"
printf '%s\n' "$$" > "$P/state/.lock"; touch "$P/state/.last-watcher-beat" "$P/config/supervision-host"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$P/data/backlog.md"
cp "$ROOT/.live/primary/.tasks.toml" "$P/.tasks.toml"
cp "$ROOT/.live/primary/data/worker-hosts.md" "$P/data/worker-hosts.md"
brief() {
  "$ROOT/bin/fm-brief.sh" "$1" sample --scout
  BRIEF="$P/data/$1/brief.md" python3 - <<'PY'
import os
from pathlib import Path
p=Path(os.environ['BRIEF']); p.write_text(p.read_text().replace('{TASK}', 'Read README only. Do not edit source files. Report what it says.').replace('{FIRSTMATE_SPEC}', 'Stay in the disposable project; do not install tools or push or use network.'))
PY
  tasks-axi add "$1" "Synthetic recovery $1" --kind scout --file "$P/data/backlog.md"
}
brief lost1
printf '\n=== lose completed placement response ===\n'
rc=0; LAB_LOSE_RESULT=1 "$ROOT/bin/fm-spawn.sh" lost1 sample --scout --host lab --harness claude || rc=$?
printf 'lost_result_exit=%s\n' "$rc"; [ "$rc" = 255 ]
[ ! -e "$P/state/lost1.meta" ]; [ -e "$H/state/lost1.meta" ]
tasks-axi show lost1 --file "$P/data/backlog.md"
printf '\n=== recover unknown placement ===\n'
"$ROOT/bin/fm-spawn.sh" lost1 sample --scout --host lab --harness claude
[ "$(tmux list-windows -a -F '#{window_name}' | grep -c '^fm-lost1$')" = 1 ]
grep '^remote_' "$P/state/lost1.meta"
printf '\n=== unknown host refused without placement ===\n'
brief unknown1
rc=0; "$ROOT/bin/fm-spawn.sh" unknown1 sample --scout --host nonexistent --harness claude || rc=$?
printf 'unknown_host_exit=%s\n' "$rc"; [ "$rc" != 0 ]; [ ! -e "$P/state/unknown1.meta" ]
tasks-axi show unknown1 --file "$P/data/backlog.md"
# Remove completed recovery from this synthetic primary's active census only;
# host task and its endpoint stay available for evidence and final teardown.
mv "$P/state/lost1.meta" "$P/state/lost1.meta.saved"
cat > "$P/state/.afk-contract" <<'EOF'
version: 2
entered: 2026-11-10T01:00:00Z
entered_epoch: 1794272400
expected_return: -
reach_channels: none
reach_announced: No phone channel is configured.
spend_max_concurrent_workers: 1
confirmed: 2026-11-10T01:00:00Z
confirmed_epoch: 1794272400
words: |-
  Continue queued work.
EOF
"$ROOT/bin/fm-afk-contract.sh" validate
brief arm1
mv "$P/state/procevent" "$P/state/procevent.saved"
: > "$P/state/procevent"
printf '\n=== away placement succeeds but mirror storage fails ===\n'
rc=0; FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-spawn.sh" arm1 sample --scout --host lab --harness claude || rc=$?
printf 'failed_arm_exit=%s\n' "$rc"; [ "$rc" != 0 ]
[ -e "$P/state/arm1.meta" ]; tasks-axi show arm1 --file "$P/data/backlog.md"
printf '\n=== new away work remains blocked by cap ===\n'
rc=0; FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-spawn.sh" unknown1 sample --scout --host lab --harness claude || rc=$?
printf 'new_work_exit=%s\n' "$rc"; [ "$rc" != 0 ]; [ ! -e "$P/state/unknown1.meta" ]
rm "$P/state/procevent"; mv "$P/state/procevent.saved" "$P/state/procevent"
printf '\n=== same-placement recovery bypasses only new-work admission ===\n'
FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-spawn.sh" arm1 sample --scout --host lab --harness claude
[ "$(tmux list-windows -a -F '#{window_name}' | grep -c '^fm-arm1$')" = 1 ]
"$ROOT/bin/fm-procevent.sh" list
grep '^remote_' "$P/state/arm1.meta"
printf '\nLIVE_RECOVERY_COMPLETE\n'
