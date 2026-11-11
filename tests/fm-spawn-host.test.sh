#!/usr/bin/env bash
# tests/fm-spawn-host.test.sh - fm-spawn.sh --host places a ship or scout on a
# worker host (docs/remote-workers.md). The primary runs the real fm-spawn and
# fm-on; a fake ssh decodes fm-on's argv stream and runs the named command in a
# fake worker-host home with the real host leg (fm-remote-worker-control.sh),
# fm-brief, and fm-spawn underneath it (fake tmux, real git worktree), the way
# tests/fm-remote-worker-control.test.sh drives that leg directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the backlog transition is inert without it)\n'
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-spawn-host)
SPAWN="$ROOT/bin/fm-spawn.sh"

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
window_file="$(dirname "$0")/.spawn-window"
printf '%s\n' "$*" >> "$(dirname "$0")/tmux.log"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" >> "$window_file"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes gh gh-axi
  printf '%s\n' "$fakebin"
}

# Sets CASE PARENT HOST_HOME WT_DIR HOST_BIN for one primary home and one
# worker-host home holding a cloned project, sample, whose pooled copy is the
# one the fake pane reports.
make_case() {  # <name>
  CASE="$TMP_ROOT/$1"
  PARENT="$CASE/parent"
  HOST_HOME="$CASE/host"
  WT_DIR="$CASE/wt"
  mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$CASE/claims" \
    "$HOST_HOME/data" "$HOST_HOME/projects" "$HOST_HOME/state" "$HOST_HOME/config" "$HOST_HOME/user-home"
  printf '%s\n' "$$" > "$PARENT/state/.lock"
  touch "$PARENT/state/.last-watcher-beat"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$PARENT/data/backlog.md"
  fm_test_tasks_toml "$PARENT/.tasks.toml"
  cat > "$PARENT/data/worker-hosts.md" <<EOF
# Worker hosts

- mbp - spare MacBook worker host (host: remote-mac; root: $ROOT; home: $HOST_HOME; added 2026-11-10)
EOF
  printf 'claude\n' > "$HOST_HOME/config/crew-harness"
  printf 'manual\n' > "$HOST_HOME/config/backlog-backend"
  : > "$HOST_HOME/.fm-worker-host"
  printf '%s\n' "$$" > "$HOST_HOME/state/.lock"
  touch "$HOST_HOME/state/.last-watcher-beat"
  fm_git_worktree "$HOST_HOME/projects/sample" "$WT_DIR" "pooled"
  HOST_BIN=$(make_fakebin "$CASE/host-tools")
  fm_test_track_procevent_home "$PARENT" "$CASE/claims"

  # The fake ssh checks fm-on's fixed transport shape, decodes the route and
  # argv it carries, and runs that tracked command as the host's job worker
  # would, in the worker-host home with the host's own fake tools. With
  # FM_FAKE_SSH_DOWN=1 it never reaches the host; with FM_FAKE_SSH_LOSE_RESULT=1
  # the host runs the command and the answer is lost, as an SSH exit 255 after
  # the remote side finished.
  cat > "$CASE/fake-ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE/ssh.log"
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "\${FM_FAKE_SSH_DOWN:-}" != 1 ] || exit 255
[ "\$1" = remote-mac ] || exit 91
[ "\$2" = fm-remote-entrypoint.sh ] || exit 92
[ "\$3" = 1 ] || exit 93
decode() { printf '%s' "\$1" | base64 --decode 2>/dev/null || printf '%s' "\$1" | base64 -D; }
root=\$(decode "\$4")
home=\$(decode "\$5")
argv=()
while IFS= read -r -d '' arg; do argv+=("\$arg"); done < <(decode "\$6")
rc=0
env -u FM_SUPERVISION_ACTOR -u FM_TRACE_CONTEXT -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \\
  -u FM_PROJECTS_OVERRIDE -u FM_PROCEVENT_CLAIM_ROOT FM_ROOT_OVERRIDE='' FM_HOME="\$home" \\
  HOME="$HOST_HOME/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 FM_GH_ACCOUNT=none \\
  FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" PATH="$HOST_BIN:\$PATH" \\
  "\$root/bin/\${argv[0]}" "\${argv[@]:1}" || rc=\$?
[ "\${FM_FAKE_SSH_LOSE_RESULT:-}" != 1 ] || exit 255
exit "\$rc"
SH
  chmod +x "$CASE/fake-ssh"
}

primary() {  # <command...>: run one real script in the primary home
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
    FM_PROCEVENT_CLAIM_ROOT="$CASE/claims" FM_SSH_BIN="$CASE/fake-ssh" \
    TASKS_AXI_BACKEND=markdown "$@"
}

# A filled primary brief for <id>, scaffolded by the real fm-brief.sh.
make_brief() {  # <id> <brief-args...>
  local id=$1 brief
  shift
  primary "$ROOT/bin/fm-brief.sh" "$id" sample "$@" >/dev/null || fail "fm-brief.sh failed for $id"
  brief="$PARENT/data/$id/brief.md"
  perl -0pi -e 's/\{TASK\}/Ship the placed sample change./; s/\{FIRSTMATE_SPEC\}/Edit README only./' "$brief"
}

add_item() {  # <id> [kind]
  tasks-axi add "$1" "item for $1" --kind "${2:-ship}" --file "$PARENT/data/backlog.md" >/dev/null \
    || fail "could not add backlog item $1"
}

row_state() {  # <id>
  tasks-axi show "$1" --file "$PARENT/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

meta_value() {  # <id> <key>
  grep "^$2=" "$PARENT/state/$1.meta" 2>/dev/null | tail -1 | cut -d= -f2-
}

new_windows() {
  grep -c '^new-window' "$HOST_BIN/tmux.log" 2>/dev/null || true
}

test_successful_placement() {
  local out rc=0 brief
  make_case place
  make_brief t1 --mode local-only --journal
  add_item t1
  out=$(primary "$SPAWN" t1 "$PARENT/projects/sample" --host mbp --mode local-only --yolo off \
    --harness claude 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "placement failed (rc=$rc): $out"
  assert_contains "$out" "spawned t1 harness=claude kind=ship mode=local-only yolo=off window=remote:t1" \
    "placement did not report the spawned worker"
  assert_contains "$out" "host=mbp backend=tmux" "placement did not name the host and its backend"

  assert_equals mbp "$(meta_value t1 remote_worker_host)" "the record does not name the worker host"
  assert_equals "$ROOT" "$(meta_value t1 remote_root)" "the record does not carry the host's code root"
  assert_equals "$HOST_HOME" "$(meta_value t1 remote_home)" "the record does not carry the host's home"
  assert_equals tmux "$(meta_value t1 remote_backend)" "the record does not carry the host's backend"
  assert_equals firstmate:fm-t1 "$(meta_value t1 remote_target)" "the record does not carry the host's endpoint"
  assert_equals "$HOST_HOME/projects/sample" "$(meta_value t1 remote_project)" "the record does not carry the host's project"
  assert_equals fm/t1 "$(meta_value t1 branch)" "the record does not carry the ship branch"
  assert_not_contains "$(cat "$PARENT/state/t1.meta")" "remote_host=" \
    "a placed task recorded the second-mate routing key"
  assert_not_contains "$(cat "$PARENT/state/t1.meta")" $'\nworktree=' \
    "a placed task recorded a host path as a local worktree"
  assert_not_contains "$(cat "$PARENT/state/t1.meta")" $'\nproject=' \
    "a placed task recorded a host path as a local project"
  # shellcheck source=bin/fm-task-route-lib.sh
  . "$ROOT/bin/fm-task-route-lib.sh"
  fm_task_route "$PARENT/state/t1.meta" || fail "the routing helper refused the placed record: $FM_TASK_ROUTE_ERROR"
  assert_equals "worker-host mbp" "$FM_TASK_ROUTE $FM_TASK_ROUTE_HOST" "the routing helper does not see a placed task"
  assert_equals in_flight "$(row_state t1)" "the backlog item did not move In flight"
  assert_absent "$PARENT/data/t1/launch-brief.md" "the primary rendered a local launch brief for a placed task"

  assert_present "$HOST_HOME/state/t1.remote-worker" "the host holds no placement claim"
  brief=$(cat "$HOST_HOME/data/t1/brief.md")
  assert_contains "$brief" "Ship the placed sample change." "the primary's captain intent did not reach the host"
  assert_contains "$brief" "$HOST_HOME/state/t1.status" "the host brief does not name the host's status file"
  assert_contains "$brief" "Delivery contract: mode=local-only" "the host brief lost its delivery contract"
  assert_contains "$brief" "$HOST_HOME/data/t1/journal.md" "the work-journal section was not forwarded"
  assert_equals 1 "$(new_windows)" "the host did not launch exactly one worker"

  out=$(primary "$ROOT/bin/fm-procevent.sh" list 2>&1) || fail "procevent list failed: $out"
  assert_contains "$out" "remote-worker-mbp" "the host's status mirror was not armed"
  pass "--host places the worker on the host, records its route, moves the item In flight, and arms the mirror"
}

test_capacity_deferral_stays_queued() {
  local out rc=0
  make_case defer
  printf 'sample 1\n' > "$HOST_HOME/config/project-capacity"
  make_brief d0 --scout
  make_brief d1 --scout
  add_item d0 scout
  add_item d1 scout
  out=$(primary "$SPAWN" d0 sample --scout --host mbp --harness claude 2>&1) \
    || fail "the first placement on a capacity-1 host failed: $out"
  out=$(primary "$SPAWN" d1 sample --scout --host mbp --harness claude 2>&1) || rc=$?
  [ "$rc" -eq 75 ] || fail "a full host did not defer with exit 75 (rc=$rc): $out"
  assert_contains "$out" "deferred: worker host mbp has no free place for project sample" \
    "the primary did not report the deferral"
  assert_absent "$PARENT/state/d1.meta" "a deferred placement left a record"
  assert_equals queued "$(row_state d1)" "a deferred placement moved its backlog item"
  assert_absent "$HOST_HOME/state/d1.remote-worker" "a deferred placement left a host claim"
  pass "a host at capacity defers with exit 75 and leaves the item queued with nothing recorded"
}

test_unconfirmed_result_reruns_safely() {
  local out rc=0
  make_case rerun
  make_brief r1 --mode local-only
  add_item r1
  out=$(FM_FAKE_SSH_LOSE_RESULT=1 primary "$SPAWN" r1 sample --host mbp --mode local-only --yolo off \
    --harness claude 2>&1) || rc=$?
  [ "$rc" -eq 255 ] || fail "a lost host answer did not exit 255 (rc=$rc): $out"
  assert_contains "$out" "re-run this same spawn" "the unknown outcome did not say how to repair it"
  assert_absent "$PARENT/state/r1.meta" "an unconfirmed placement left a record"
  assert_equals queued "$(row_state r1)" "an unconfirmed placement moved its backlog item"
  assert_present "$HOST_HOME/state/r1.meta" "the host did not launch before the answer was lost"
  assert_equals 1 "$(new_windows)" "the host did not launch exactly one worker"

  out=$(primary "$SPAWN" r1 sample --host mbp --mode local-only --yolo off --harness claude 2>&1) \
    || fail "re-running the unconfirmed placement failed: $out"
  assert_contains "$out" "already placed" "the re-run did not reuse the host's existing worker"
  assert_equals 1 "$(new_windows)" "the re-run launched a second worker"
  assert_equals firstmate:fm-r1 "$(meta_value r1 remote_target)" "the re-run did not record the existing route"
  assert_equals in_flight "$(row_state r1)" "the re-run did not move the backlog item In flight"
  pass "an unconfirmed SSH placement records nothing, and re-running it records the one existing worker"
}

test_unknown_host_refused() {
  local out rc=0
  make_case unknown
  make_brief u1 --mode local-only
  add_item u1
  out=$(primary "$SPAWN" u1 sample --host nope --mode local-only --yolo off --harness claude 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown host was accepted: $out"
  assert_contains "$out" "no worker host 'nope' is registered" "the unknown host was not named"
  assert_absent "$PARENT/state/u1.meta" "a refused placement left a record"
  assert_equals queued "$(row_state u1)" "a refused placement moved its backlog item"
  assert_absent "$CASE/ssh.log" "a refused placement reached for a host"
  rc=0
  out=$(primary "$SPAWN" u1 sample --host mbp --mode local-only --yolo off --account a 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "--host accepted an account pin it cannot forward: $out"
  assert_contains "$out" "not forwarded to a worker host" "the unforwardable flag was not named"
  pass "--host refuses an unregistered host and unforwardable flags before reaching any host"
}

test_failed_mirror_arm_keeps_record_and_reruns() {
  local out rc cap
  for cap in 1 2; do
  rc=0
  make_case "arm-$cap"
  cat > "$PARENT/state/.afk-contract" <<EOF
version: 2
entered: 2026-11-10T01:00:00Z
entered_epoch: 1794272400
expected_return: -
reach_channels: none
reach_announced: No phone channel is configured.
spend_max_concurrent_workers: $cap
confirmed: 2026-11-10T01:00:00Z
confirmed_epoch: 1794272400
words: |-
  Continue queued work.
EOF
  primary "$ROOT/bin/fm-afk-contract.sh" validate || fail 'invalid away fixture'
  make_brief a1 --mode local-only
  add_item a1
  # A regular file where the process-event state root belongs makes arming fail.
  : > "$PARENT/state/procevent"
  out=$(FM_SUPERVISION_ACTOR=branch primary "$SPAWN" a1 sample --host mbp --mode local-only --yolo off --harness claude 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a placement whose mirror could not be armed reported success: $out"
  assert_contains "$out" "status mirror could not be armed" "the arm failure was not named"
  assert_equals firstmate:fm-a1 "$(meta_value a1 remote_target)" "the arm failure lost the placed record"
  assert_equals in_flight "$(row_state a1)" "the arm failure moved the backlog item back"
  make_brief a2 --mode local-only
  add_item a2
  if [ "$cap" -eq 2 ]; then
    tasks-axi start a2 --file "$PARENT/data/backlog.md" >/dev/null || fail 'could not stage In flight item'
  fi
  rc=0
  out=$(FM_SUPERVISION_ACTOR=branch primary "$SPAWN" a2 sample --host mbp --mode local-only --yolo off --harness claude 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "new work bypassed away admission with cap $cap"
  if [ "$cap" -eq 1 ]; then
    assert_contains "$out" 'caps concurrent workers at 1' 'new work bypassed the spend cap'
  else
    assert_contains "$out" 'only queued unblocked work' 'new work bypassed queued-only admission'
  fi
  assert_absent "$PARENT/state/a2.meta" 'refused new work published a record'
  rm -f "$PARENT/state/procevent"
  out=$(FM_SUPERVISION_ACTOR=branch primary "$SPAWN" a1 sample --host mbp --mode local-only --yolo off --harness claude 2>&1) \
    || fail "re-running after a failed arm failed: $out"
  assert_contains "$out" "already placed" "the re-run did not reuse the host's existing worker"
  assert_equals 1 "$(new_windows)" "the re-run launched a second worker"
  out=$(primary "$ROOT/bin/fm-procevent.sh" list 2>&1) || fail "procevent list failed: $out"
  assert_contains "$out" "remote-worker-mbp" "the re-run did not arm the host's status mirror"
  done
  pass "away recovery finishes existing placement at or below the cap without admitting new work"
}

test_local_launches_preserve_worker_host_placement() {
  local out rc before operation primary_bin
  make_case local-refusals
  make_brief p1 --mode local-only
  add_item p1
  out=$(primary "$SPAWN" p1 sample --host mbp --mode local-only --yolo off --harness claude 2>&1) \
    || fail "placement failed: $out"
  before=$(< "$PARENT/state/p1.meta")
  primary_bin=$(make_fakebin "$CASE/primary-tools")
  for operation in spawn relaunch; do
    rc=0
    if [ "$operation" = spawn ]; then
      out=$(PATH="$primary_bin:$PATH" primary "$SPAWN" p1 "$WT_DIR" --mode local-only --yolo off --harness claude 2>&1) || rc=$?
    else
      out=$(PATH="$primary_bin:$PATH" primary "$SPAWN" p1 --relaunch --harness claude 2>&1) || rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "local $operation accepted a worker-host placement"
    assert_contains "$out" "task placed on worker host mbp" "local $operation did not identify the owning host"
    assert_equals "$before" "$(< "$PARENT/state/p1.meta")" "local $operation changed the placement record"
    assert_equals in_flight "$(row_state p1)" "local $operation changed the backlog state"
    assert_absent "$primary_bin/.spawn-window" "local $operation launched a duplicate worker"
    assert_equals 1 "$(new_windows)" "local $operation launched another host worker"
  done
  pass "local spawn and direct relaunch refuse existing worker-host placements"
}

fm_test_run test_successful_placement test_capacity_deferral_stays_queued \
  test_unconfirmed_result_reruns_safely test_unknown_host_refused \
  test_failed_mirror_arm_keeps_record_and_reruns \
  test_local_launches_preserve_worker_host_placement
