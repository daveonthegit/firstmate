#!/usr/bin/env bash
set -eu
ROOT="$PWD"
P="$ROOT/.live/primary"; H="$ROOT/.live/host"
E=~/.no-mistakes/evidence/01M74AZP4ES3P09BD6H6CSXGGX
exec > "$E/live-product.log" 2>&1
trap 'printf "DRIVER_EXIT=%s\n" "$?"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_SOCKET_PATH FM_BACKEND FM_GATE_REFUSE_BYPASS
export FM_HOME="$P" FM_SSH_BIN="$ROOT/.live/loopback-ssh" FM_PROCEVENT_CLAIM_ROOT="$ROOT/.live/claims" FM_SPAWN_NO_GUARD=1 TREEHOUSE_ROOT="$ROOT/.live/pool"
mkdir -p "$FM_PROCEVENT_CLAIM_ROOT"
printf 'manual\n' > "$H/config/backlog-backend"
printf 'claude\n' > "$H/config/crew-harness"
printf 'tmux\n' > "$H/config/backend"
printf 'sample 1\n' > "$H/config/project-capacity"
touch "$H/.fm-worker-host" "$P/config/supervision-host"
printf '%s\n' "$$" > "$P/state/.lock"
printf '%s\n' "$$" > "$H/state/.lock"
touch "$H/state/.last-watcher-beat" "$P/state/.last-watcher-beat"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$P/data/backlog.md"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$P/.tasks.toml"
printf -- '- lab - loopback validation (host: lab-loopback; root: %s; home: %s; added 2026-11-10)\n' "$ROOT" "$H" > "$P/data/worker-hosts.md"
git init -q "$H/projects/sample"
git -C "$H/projects/sample" config user.name 'Lab'
git -C "$H/projects/sample" config user.email 'lab@example.invalid'
printf '# Synthetic project\n' > "$H/projects/sample/README.md"
git -C "$H/projects/sample" add README.md
git -C "$H/projects/sample" -c core.hooksPath=/dev/null commit -qm initial
for id in live1 live2; do
  "$ROOT/bin/fm-brief.sh" "$id" sample --scout
  BRIEF="$P/data/$id/brief.md" python3 - <<'PY'
import os
from pathlib import Path
p=Path(os.environ['BRIEF'])
p.write_text(p.read_text().replace('{TASK}', 'Read README.md only. Do not edit anything. Report a short description of this synthetic project.').replace('{FIRSTMATE_SPEC}', 'Stay inside this disposable project. Do not use git push, install tools, or access any external services.'))
PY
  tasks-axi add "$id" "Synthetic local placement $id" --kind scout --file "$P/data/backlog.md"
done
printf '\n=== place real scout through loopback transport ===\n'
"$ROOT/bin/fm-spawn.sh" live1 sample --scout --host lab --harness claude
printf '\n=== recorded route ===\n'
/usr/bin/grep -E '^(kind|remote_|window|branch)=' "$P/state/live1.meta" || true
printf '\n=== full public task record ===\n'
/usr/bin/grep -E '^(kind|remote_|window|branch)' "$P/state/live1.meta"
"$ROOT/bin/fm-procevent.sh" list
printf '\n=== full host defers second scout ===\n'
rc=0; "$ROOT/bin/fm-spawn.sh" live2 sample --scout --host lab --harness claude || rc=$?
printf 'capacity_exit=%s\n' "$rc"; [ "$rc" = 75 ]
tasks-axi show live2 --file "$P/data/backlog.md"
[ ! -e "$P/state/live2.meta" ]
printf '\n=== same placement retry ===\n'
"$ROOT/bin/fm-spawn.sh" live1 sample --scout --host lab --harness claude
printf '\n=== real tmux endpoint ===\n'
tmux list-windows -a -F '#{session_name}:#{window_name} #{pane_current_path}'
printf '\n=== unsupported primary operations ===\n'
for cmd in 'fm-send.sh live1 hello' 'fm-peek.sh live1' 'fm-control.sh live1 interrupt' 'fm-t3-answer.sh live1' 'fm-teardown.sh live1'; do
  rc=0; "$ROOT/bin/${cmd%% *}" ${cmd#* } || rc=$?; printf 'refusal_exit=%s\n' "$rc"; [ "$rc" != 0 ]
done
"$ROOT/bin/fm-crew-state.sh" live1
printf '\nLIVE_DRIVER_COMPLETE\n'
