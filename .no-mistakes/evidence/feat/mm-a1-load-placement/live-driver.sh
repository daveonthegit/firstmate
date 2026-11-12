#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M78R1VKSNRBXSR58MW0VQF7H
LAB="$ROOT/.live/home"
W="$ROOT/.live/worker"
bin/fm-lab-home.sh create "$LAB"
bin/fm-lab-home.sh create "$W"
trap 'rm -rf "$LAB" "$W"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_GATE_REFUSE_BYPASS
export FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1
# Real OpenSSH, with isolated configuration and no operator keys or agent.
printf 'Host *\n  Port 1\n  UserKnownHostsFile %s/.live/known_hosts\n  GlobalKnownHostsFile /dev/null\n  IdentityFile none\n  IdentityAgent none\n  IdentitiesOnly yes\n' "$ROOT" > "$ROOT/.live/ssh_config"
printf '#!/usr/bin/env bash\nexec /usr/bin/ssh -F %q "$@"\n' "$ROOT/.live/ssh_config" > "$ROOT/.live/ssh-isolated"
chmod +x "$ROOT/.live/ssh-isolated"
export FM_SSH_BIN="$ROOT/.live/ssh-isolated"
printf 'claude\n' > "$LAB/config/crew-harness"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
touch "$LAB/config/auto-placement"
git init -q "$LAB/projects/sample"
git -C "$LAB/projects/sample" -c user.name=Lab -c user.email=lab@example.invalid commit --allow-empty -qm initial
# Synthetic lookout beat: independent, explicitly unconstrained inputs so a
# one-lane cap with one running task MUST defer, regardless of host load.
beat() {
  printf '%s\n' '{"schema":"lookout.beat","schema_version":"1.0","host":"disposable-local","interval_s":3600,"machine":{"id":"disposable-local","load":{"l1":0.5,"runq_per_core":0.1},"mem":{"avail_gb":12,"total_gb":16,"swap_rate_pps_1m":0,"psi_some10":0},"disks":[{"label":"disk","free_gb":500}],"on_battery":false,"pressure":{"level":"ok","why":[]},"beat":{"errors":[]}}}' > "$1/beat.json"
  printf '1\npressure-file %s/beat.json\n' "$1" > "$1/config/lane-capacity"
}
beat "$LAB"
printf 'kind=ship\nmode=local-only\n' > "$LAB/state/busy.meta"
run() {
 local expect=$1 label=$2 rc=0; shift 2
 printf '\n### %s\n$ ' "$label"; printf '%q ' "$@"; printf '\n'
 "$@" > "$E/last-command.log" 2>&1 || rc=$?
 tee < "$E/last-command.log"
 printf 'exit=%s (expected %s)\n' "$rc" "$expect"
 [ "$rc" = "$expect" ] || exit 1
}
spawn() { "$ROOT/bin/fm-spawn.sh" "$1" "$LAB/projects/sample" --mode local-only --yolo off "${@:2}"; }
# Queueing is observed through the actual tasks-axi consumer, not source text.
TASKS_AXI_BACKEND=markdown tasks-axi add full 'Full local lane stays queued' --kind ship --file "$LAB/data/backlog.md" >/dev/null
run 0 full-capacity bin/fm-capacity.sh
run 75 full-automatic spawn full --harness claude
run 0 queued-item tasks-axi show full --file "$LAB/data/backlog.md"
[ ! -e "$LAB/state/full.meta" ]
run 75 full-raw-local-only spawn raw-full 'sleep 60'
run 75 full-account-local-only spawn account-full --harness claude --account lab
run 75 full-resume-local-only spawn resume-full --harness claude --herdr-resume-lock-wait
rm "$LAB/config/lane-capacity"
run 1 missing-cap-raw spawn raw-nocap 'sleep 60'
run 1 missing-cap-account spawn account-nocap --harness claude --account lab
beat "$LAB"
# Actual unreachable SSH endpoint. No replacement ssh executable or output.
printf '# Worker hosts\n\n- laptop - disposable unreachable endpoint (host: 127.0.0.1; root: %s; home: %s; added 2026-11-10)\n' "$ROOT" "$W" > "$LAB/data/worker-hosts.md"
run 0 full-and-unreachable bin/fm-placement.sh sample
run 75 full-and-unreachable-spawn spawn full --harness claude
# Pending outcome is an intentional persisted state contract, manually seeded
# as the result of an unanswered dispatch. No remote-success claim is made.
TASKS_AXI_BACKEND=markdown tasks-axi add pending 'Pending placement must retain ownership' --kind ship --file "$LAB/data/backlog.md" >/dev/null
bin/fm-brief.sh pending sample --mode local-only >/dev/null
perl -0pi -e 's/\{TASK\}/Wait for operator instruction; do not edit files./g; s/\{FIRSTMATE_SPEC\}/No file changes./g' "$LAB/data/pending/brief.md"
printf 'laptop\n' > "$LAB/state/pending.placement"
run 1 pending-refuses-local spawn pending --harness claude --host local
run 1 pending-refuses-other-host spawn pending --harness claude --host other
rm "$LAB/config/auto-placement"
run 1 pending-refuses-local-with-feature-off spawn pending --harness claude --host local
run 255 pending-unnamed-retry-unreachable spawn pending --harness claude
[ "$(<"$LAB/state/pending.placement")" = laptop ]
[ ! -e "$LAB/state/pending.meta" ]
# Exercise the actual destination-side public remote control interface against
# a second local lab home, without pretending this is an SSH deployment.
touch "$W/.fm-worker-host"
printf 'manual\n' > "$W/config/backlog-backend"
printf 'claude\n' > "$W/config/crew-harness"
beat "$W"
git clone -q "$LAB/projects/sample" "$W/projects/sample"
printf 'kind=scout\n' > "$W/state/busy.meta"
run 0 worker-headroom env FM_HOME="$W" bin/fm-remote-worker-control.sh headroom sample
run 75 worker-locked-admission env FM_HOME="$W" bin/fm-remote-worker-control.sh spawn remote-full sample --mode local-only --yolo off --harness claude --auto-placement <<< 'Do not edit files; this task must be deferred by capacity.'
[ ! -e "$W/state/remote-full.meta" ]
printf '\nAll exercised rejection paths left no new worker metadata.\n'
