#!/usr/bin/env bash
# tests/fm-placement.test.sh - automatic placement by load (docs/remote-workers.md
# "How placement is chosen"). The primary runs the real fm-placement, fm-spawn,
# fm-capacity, and fm-on; a fake ssh decodes fm-on's argv stream and runs the
# named command in one of two fake worker-host homes with the real host leg
# (fm-remote-worker-control.sh) and that host's own fm-capacity and fm-spawn
# underneath it (fake tmux, real git worktree), as tests/fm-spawn-host.test.sh
# does for an explicit --host. Every machine's lane cap names a fresh
# lookout beat, so the verdicts never depend on this machine's own load.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the backlog transition is inert without it)\n'
  exit 0
}
command -v jq >/dev/null 2>&1 || {
  printf 'ok - skipped (jq is not installed; the fixture beats need it)\n'
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-placement)
SPAWN="$ROOT/bin/fm-spawn.sh"
PLACEMENT="$ROOT/bin/fm-placement.sh"

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

# write_beat <file>: a fresh lookout beat with no pressure, so the lane cap's
# verdict rests on lanes alone.
write_beat() {
  cat > "$1" <<'JSON'
{"schema":"lookout.beat","schema_version":"1.0","host":"beat-host","interval_s":15,
 "machine":{"id":"beat-host","load":{"l1":0.5,"runq_per_core":0.1},
  "mem":{"avail_gb":12,"total_gb":16,"swap_rate_pps_1m":0,"psi_some10":0},
  "disks":[{"label":"disk","free_gb":500}],"on_battery":false,
  "pressure":{"level":"ok","why":[]},"beat":{"errors":[]}}}
JSON
}

# set_cap <home> <cap>: the home's lane cap, judged on a fresh beat.
set_cap() {
  write_beat "$1/beat.json"
  printf '%s\npressure-file %s\n' "$2" "$1/beat.json" > "$1/config/lane-capacity"
}

# busy <home> <n>: n running ship records in that home, each holding a lane.
busy() {
  local i=0
  while [ "$i" -lt "$2" ]; do
    fm_write_meta "$1/state/busy-$i.meta" "kind=ship" "mode=no-mistakes"
    i=$((i + 1))
  done
}

# make_host <dir> <with-project:0|1>: one worker-host home.
make_host() {
  local home=$1
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/user-home"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  : > "$home/.fm-worker-host"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  if [ "$2" -eq 1 ]; then
    fm_git_worktree "$home/projects/sample" "$home.wt" "pooled"
    printf '%s\n' "$home.wt" > "$home/.fake-pane"
  fi
}

# make_case <name>: a primary home with its own clone of sample and pooled copy,
# worker host mbp (cloned sample) at HOST_A, and worker host spare at HOST_B
# (no clone of sample). Nothing has a lane cap until a test sets one.
make_case() {
  CASE="$TMP_ROOT/$1"
  PARENT="$CASE/parent"
  HOST_A="$CASE/host-a"
  HOST_B="$CASE/host-b"
  mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$PARENT/user-home" "$CASE/claims"
  printf '%s\n' "$$" > "$PARENT/state/.lock"
  touch "$PARENT/state/.last-watcher-beat"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$PARENT/data/backlog.md"
  fm_test_tasks_toml "$PARENT/.tasks.toml"
  printf 'claude\n' > "$PARENT/config/crew-harness"
  fm_git_worktree "$PARENT/projects/sample" "$CASE/parent-wt" "pooled"
  cat > "$PARENT/data/worker-hosts.md" <<EOF
# Worker hosts

- mbp - spare MacBook worker host (host: remote-mac; root: $ROOT; home: $HOST_A; added 2026-11-10)
- spare - second worker host without the project (host: remote-spare; root: $ROOT; home: $HOST_B; added 2026-11-10)
EOF
  make_host "$HOST_A" 1
  make_host "$HOST_B" 0
  HOST_BIN=$(make_fakebin "$CASE/host-tools")
  PRIMARY_BIN=$(make_fakebin "$CASE/primary-tools")
  fm_test_track_procevent_home "$PARENT" "$CASE/claims"

  # The fake ssh decodes fm-on's route and argv and runs that tracked command
  # in the home fm-on named, as the host's job worker would. FM_FAKE_SSH_DOWN
  # names an alias it never reaches; FM_FAKE_SSH_LOSE_SPAWN=1 runs a host spawn
  # and then loses its answer, as an SSH exit 255 after the remote side ran.
  cat > "$CASE/fake-ssh" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
alias=\$1
[ "\$alias" != "\${FM_FAKE_SSH_DOWN:-}" ] || exit 255
case "\$alias" in remote-mac|remote-spare) ;; *) exit 91 ;; esac
[ "\$2" = fm-remote-entrypoint.sh ] || exit 92
decode() { printf '%s' "\$1" | base64 --decode 2>/dev/null || printf '%s' "\$1" | base64 -D; }
root=\$(decode "\$4")
home=\$(decode "\$5")
argv=()
while IFS= read -r -d '' arg; do argv+=("\$arg"); done < <(decode "\$6")
printf '%s %s\n' "\$alias" "\${argv[*]:1:2}" >> "$CASE/ssh.log"
pane=
[ ! -f "\$home/.fake-pane" ] || pane=\$(cat "\$home/.fake-pane")
rc=0
env -u FM_SUPERVISION_ACTOR -u FM_TRACE_CONTEXT -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \\
  -u FM_PROJECTS_OVERRIDE -u FM_PROCEVENT_CLAIM_ROOT FM_ROOT_OVERRIDE='' FM_HOME="\$home" \\
  HOME="\$home/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 FM_GH_ACCOUNT=none \\
  FM_FAKE_PANE_PATH="\$pane" TMUX="fake,1,0" PATH="$HOST_BIN:\$PATH" \\
  "\$root/bin/\${argv[0]}" "\${argv[@]:1}" || rc=\$?
if [ "\${argv[1]}" = headroom ] && [ "\$alias" = remote-mac ]; then
  case "\${FM_FAKE_FILL:-}" in
    local) fill="$PARENT" ;;
    remote) fill="\$home" ;;
    *) fill= ;;
  esac
  if [ -n "\$fill" ]; then
    printf 'kind=ship\\nmode=no-mistakes\\n' > "\$fill/state/raced.meta"
  fi
fi
[ "\${FM_FAKE_SSH_LOSE_SPAWN:-}" != 1 ] || [ "\${argv[1]}" != spawn ] || exit 255
exit "\$rc"
SH
  chmod +x "$CASE/fake-ssh"
}

primary() {  # <command...>: run one real script in the primary home
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
    FM_PROCEVENT_CLAIM_ROOT="$CASE/claims" FM_SSH_BIN="$CASE/fake-ssh" \
    HOME="$PARENT/user-home" CLAUDE_CONFIG_DIR='' FM_GH_ACCOUNT=none \
    FM_FAKE_PANE_PATH="$CASE/parent-wt" TMUX="fake,1,0" PATH="$PRIMARY_BIN:$PATH" \
    TASKS_AXI_BACKEND=markdown "$@"
}

place() {  # [--allow-fail] -> PLACE_OUT PLACE_RC for sample
  PLACE_RC=0
  PLACE_OUT=$(primary "$PLACEMENT" sample 2>&1) || PLACE_RC=$?
}

order() { printf '%s\n' "$PLACE_OUT" | sed -n 's/^order: *//p'; }

make_brief() {  # <id> <brief-args...>
  local id=$1 brief
  shift
  primary "$ROOT/bin/fm-brief.sh" "$id" sample "$@" >/dev/null || fail "fm-brief.sh failed for $id"
  brief="$PARENT/data/$id/brief.md"
  perl -0pi -e 's/\{TASK\}/Ship the sample change./; s/\{FIRSTMATE_SPEC\}/Edit README only./' "$brief"
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

windows() {  # <fakebin>
  [ -f "$1/tmux.log" ] || { echo 0; return; }
  grep -c '^new-window' "$1/tmux.log" || true
}

auto_spawn() {  # <id> [extra args] -> SPAWN_OUT SPAWN_RC
  local id=$1
  shift
  SPAWN_RC=0
  SPAWN_OUT=$(primary "$SPAWN" "$id" projects/sample --mode local-only --yolo off --harness claude "$@" 2>&1) || SPAWN_RC=$?
}

# --- the placement decision -------------------------------------------------

test_share_of_own_cap_wins() {
  make_case share
  set_cap "$PARENT" 2
  busy "$PARENT" 1
  set_cap "$HOST_A" 6
  busy "$HOST_A" 2
  place
  expect_code 0 "$PLACE_RC" "placement"
  assert_contains "$PLACE_OUT" "placement: this machine admits - 1 of 2 lanes open (1 running;" \
    "this machine's headroom was not shown"
  assert_contains "$PLACE_OUT" "placement: worker host mbp admits - 4 of 6 lanes open (2 running;" \
    "the host's headroom was not shown"
  assert_contains "$PLACE_OUT" "placement: worker host spare skipped - it has no clone of sample" \
    "a host without the project was not skipped as ineligible"
  assert_contains "$PLACE_OUT" "placement: chose worker host mbp" "the larger share did not win"
  assert_equals "mbp local" "$(order)" "the order is not best share first"
  pass "machines are ranked by open share of their own cap, and a host without the project is skipped"
}

test_ties_break_on_open_lanes_then_this_machine() {
  make_case ties
  set_cap "$PARENT" 2
  busy "$PARENT" 1
  set_cap "$HOST_A" 4
  busy "$HOST_A" 2
  place
  assert_equals "mbp local" "$(order)" "an equal share did not prefer more open lanes"
  rm -f "$HOST_A"/state/busy-*.meta
  set_cap "$HOST_A" 2
  busy "$HOST_A" 1
  place
  assert_equals "local mbp" "$(order)" "a full tie did not prefer this machine"
  pass "an equal share prefers more open lanes, then this machine"
}

test_unreachable_and_uncapped_hosts_are_skipped() {
  make_case skipped
  set_cap "$PARENT" 1
  busy "$PARENT" 1
  set_cap "$HOST_A" 4
  PLACE_RC=0
  PLACE_OUT=$(FM_FAKE_SSH_DOWN=remote-mac primary "$PLACEMENT" sample 2>&1) || PLACE_RC=$?
  expect_code 0 "$PLACE_RC" "placement with an unreachable host"
  assert_contains "$PLACE_OUT" "placement: worker host mbp skipped - unreachable" "the unreachable host was not skipped"
  assert_contains "$PLACE_OUT" "placement: this machine does not admit - full, 1 of 1 lanes running" \
    "a full machine was not reported"
  assert_contains "$PLACE_OUT" "placement: no machine admits the task now" "nothing admitting was not reported"
  assert_equals "" "$(order)" "an unreachable host was treated as free"
  rm -f "$HOST_A/config/lane-capacity"
  place
  assert_contains "$PLACE_OUT" "placement: worker host mbp skipped - no lane cap declared" \
    "a host without a lane cap was not skipped"
  assert_equals "" "$(order)" "a host without a lane cap was ranked"
  pass "an unreachable host and a host without a lane cap are skipped, never treated as free"
}

test_this_machine_needs_its_cap() {
  make_case nocap
  set_cap "$HOST_A" 4
  place
  [ "$PLACE_RC" -eq 1 ] || fail "placement without this machine's cap did not exit 1 (rc=$PLACE_RC): $PLACE_OUT"
  assert_contains "$PLACE_OUT" "this machine declares no lane cap" "the missing local cap was not named"
  pass "automatic placement refuses to judge without this machine's own lane cap"
}

test_placed_tasks_count_on_their_host() {
  local out
  make_case counted
  set_cap "$PARENT" 3
  busy "$PARENT" 1
  fm_write_meta "$PARENT/state/far-1.meta" "kind=ship" "remote_worker_host=mbp" "remote_root=$ROOT" "remote_home=$HOST_A"
  fm_write_meta "$PARENT/state/far-2.meta" "kind=scout" "remote_worker_host=mbp" "remote_root=$ROOT" "remote_home=$HOST_A"
  out=$(FM_HOME="$PARENT" "$ROOT/bin/fm-capacity.sh" 2>&1 | head -n 1)
  assert_contains "$out" "free_lanes=2 reason=ok lanes=1 target=3" "placed tasks held lanes on the supervisor"
  assert_contains "$out" " placed=2" "placed tasks were not reported separately"
  pass "a task placed on a worker host holds no lane on the supervisor's machine"
}

# --- fm-spawn ---------------------------------------------------------------

test_spawn_off_by_default() {
  make_case off
  set_cap "$PARENT" 1
  busy "$PARENT" 1
  set_cap "$HOST_A" 4
  make_brief o1 --mode local-only
  add_item o1
  auto_spawn o1
  expect_code 0 "$SPAWN_RC" "a plain spawn without the setting ($SPAWN_OUT)"
  assert_not_contains "$SPAWN_OUT" "placement:" "placement ran without config/auto-placement"
  assert_absent "$CASE/ssh.log" "a spawn without the setting reached a worker host"
  assert_equals "" "$(meta_value o1 remote_worker_host)" "a spawn without the setting was placed"
  assert_equals 1 "$(windows "$PRIMARY_BIN")" "the local spawn did not launch here"
  pass "without config/auto-placement a spawn runs here exactly as before"
}

test_spawn_places_on_the_emptier_host() {
  make_case to-host
  : > "$PARENT/config/auto-placement"
  set_cap "$PARENT" 3
  busy "$PARENT" 2
  set_cap "$HOST_A" 4
  make_brief h1 --mode local-only
  add_item h1
  auto_spawn h1
  expect_code 0 "$SPAWN_RC" "automatic placement on a host ($SPAWN_OUT)"
  assert_contains "$SPAWN_OUT" "placement: this machine admits - 1 of 3 lanes open" "the decision did not show this machine"
  assert_contains "$SPAWN_OUT" "placement: chose worker host mbp" "the decision did not name the choice"
  assert_contains "$SPAWN_OUT" "host=mbp" "the spawn did not report the host"
  assert_equals mbp "$(meta_value h1 remote_worker_host)" "the record does not carry the placement"
  assert_equals in_flight "$(row_state h1)" "the backlog item did not move In flight"
  assert_absent "$PARENT/state/h1.placement" "a confirmed placement left its pending note"
  assert_equals 1 "$(windows "$HOST_BIN")" "the host did not launch exactly one worker"
  assert_equals 0 "$(windows "$PRIMARY_BIN")" "this machine launched a worker too"
  pass "a spawn with no machine named goes to the host with the larger open share"
}

test_spawn_stays_here_when_this_machine_is_emptier() {
  make_case to-local
  : > "$PARENT/config/auto-placement"
  set_cap "$PARENT" 4
  set_cap "$HOST_A" 4
  busy "$HOST_A" 3
  make_brief l1 --mode local-only
  add_item l1
  auto_spawn l1
  expect_code 0 "$SPAWN_RC" "automatic placement here ($SPAWN_OUT)"
  assert_contains "$SPAWN_OUT" "placement: chose this machine" "the decision did not name this machine"
  assert_equals "" "$(meta_value l1 remote_worker_host)" "a local choice was recorded as placed"
  assert_equals 1 "$(windows "$PRIMARY_BIN")" "this machine did not launch the worker"
  assert_equals 0 "$(windows "$HOST_BIN")" "the host launched a worker too"
  assert_not_contains "$(cat "$CASE/ssh.log")" "spawn" "a local choice still sent a spawn to the host"
  pass "a spawn stays on this machine when it has the larger open share"
}

test_spawn_named_machine_wins() {
  make_case named
  : > "$PARENT/config/auto-placement"
  set_cap "$PARENT" 4
  busy "$PARENT" 4
  set_cap "$HOST_A" 4
  make_brief n1 --mode local-only
  add_item n1
  auto_spawn n1 --host local
  expect_code 0 "$SPAWN_RC" "--host local ($SPAWN_OUT)"
  assert_not_contains "$SPAWN_OUT" "placement:" "--host local still ran automatic placement"
  assert_absent "$CASE/ssh.log" "--host local reached a worker host"
  assert_equals 1 "$(windows "$PRIMARY_BIN")" "--host local did not launch here"
  pass "--host local keeps a task on this machine on purpose"
}

test_spawn_nothing_admits_stays_queued() {
  make_case queued
  : > "$PARENT/config/auto-placement"
  set_cap "$PARENT" 1
  busy "$PARENT" 1
  set_cap "$HOST_A" 1
  busy "$HOST_A" 1
  make_brief q1 --mode local-only
  add_item q1
  auto_spawn q1
  expect_code 75 "$SPAWN_RC" "a spawn no machine admits ($SPAWN_OUT)"
  assert_contains "$SPAWN_OUT" "deferred: no machine admits task q1 now" "the deferral was not reported"
  assert_absent "$PARENT/state/q1.meta" "a deferred spawn left a record"
  assert_equals queued "$(row_state q1)" "a deferred spawn moved its backlog item"
  pass "when no machine admits the task it stays queued with exit 75"
}

test_spawn_deferral_falls_to_next_machine() {
  make_case fallthrough
  : > "$PARENT/config/auto-placement"
  set_cap "$PARENT" 10
  set_cap "$HOST_A" 4
  busy "$HOST_A" 1
  # One local worker already holds sample's single place on this machine.
  printf 'sample 1\n' > "$PARENT/config/project-capacity"
  fm_write_meta "$PARENT/state/holder.meta" "kind=ship" "mode=no-mistakes" "project=$PARENT/projects/sample"
  make_brief f1 --mode local-only
  add_item f1
  auto_spawn f1
  expect_code 0 "$SPAWN_RC" "fall-through placement ($SPAWN_OUT)"
  assert_contains "$SPAWN_OUT" "placement: chose this machine" "this machine was not first"
  assert_contains "$SPAWN_OUT" "placement: this machine deferred f1 at spawn; trying the next machine" \
    "the local deferral was not passed on"
  assert_equals mbp "$(meta_value f1 remote_worker_host)" "the task did not land on the next machine"
  assert_equals 0 "$(windows "$PRIMARY_BIN")" "this machine launched despite deferring"
  pass "a machine that defers at spawn passes the task to the next one"
}

test_spawn_lost_answer_reruns_on_same_host() {
  make_case lost
  : > "$PARENT/config/auto-placement"
  set_cap "$PARENT" 4
  busy "$PARENT" 2
  set_cap "$HOST_A" 4
  make_brief r1 --mode local-only
  add_item r1
  SPAWN_RC=0
  SPAWN_OUT=$(FM_FAKE_SSH_LOSE_SPAWN=1 primary "$SPAWN" r1 projects/sample --mode local-only --yolo off \
    --harness claude 2>&1) || SPAWN_RC=$?
  expect_code 255 "$SPAWN_RC" "a lost host answer ($SPAWN_OUT)"
  assert_equals mbp "$(cat "$PARENT/state/r1.placement" 2>/dev/null)" "the unconfirmed placement was not noted"
  assert_equals 1 "$(windows "$HOST_BIN")" "the host did not launch before its answer was lost"
  # This machine now has the larger share, but the task must not start twice.
  rm -f "$PARENT"/state/busy-*.meta
  local destination setting
  for setting in on off; do
    [ "$setting" = on ] || rm -f "$PARENT/config/auto-placement"
    for destination in local spare; do
      auto_spawn r1 --host "$destination"
      expect_code 1 "$SPAWN_RC" "pending placement redirected to $destination ($SPAWN_OUT)"
      assert_contains "$SPAWN_OUT" "re-run with --host mbp" "refusal did not identify recovery host"
      assert_equals mbp "$(cat "$PARENT/state/r1.placement")" "refusal lost pending ownership"
      assert_equals 0 "$(windows "$PRIMARY_BIN")" "refusal launched locally"
      assert_equals 1 "$(windows "$HOST_BIN")" "refusal launched another remote worker"
    done
  done
  auto_spawn r1
  expect_code 0 "$SPAWN_RC" "re-running after a lost answer ($SPAWN_OUT)"
  assert_contains "$SPAWN_OUT" "last sent to worker host mbp and its answer was lost" "the re-run did not follow the note"
  assert_equals mbp "$(meta_value r1 remote_worker_host)" "the re-run did not record the host's worker"
  assert_equals 1 "$(windows "$HOST_BIN")" "the re-run launched a second worker on the host"
  assert_equals 0 "$(windows "$PRIMARY_BIN")" "the re-run launched a second worker here"
  assert_absent "$PARENT/state/r1.placement" "the confirmed re-run left its pending note"
  printf 'mbp\n' > "$PARENT/state/r1.placement"
  auto_spawn r1 --host mbp
  expect_code 0 "$SPAWN_RC" "explicit same-host recovery ($SPAWN_OUT)"
  assert_absent "$PARENT/state/r1.placement" "explicit recovery retained pending note"
  assert_equals 1 "$(windows "$HOST_BIN")" "explicit recovery launched a second worker"
  make_brief d1 --mode local-only
  add_item d1
  printf 'sample 1\n' > "$HOST_A/config/project-capacity"
  printf 'mbp\n' > "$PARENT/state/d1.placement"
  auto_spawn d1 --host mbp
  expect_code 75 "$SPAWN_RC" "pending placement refused by host ($SPAWN_OUT)"
  assert_absent "$PARENT/state/d1.placement" "host deferral retained pending ownership"
  assert_equals queued "$(row_state d1)" "host deferral moved queued item"
  pass "a placement whose answer was lost is re-run on the same host, never placed twice"
}

test_spawn_rechecks_lane_admission() {
  local destination expected_host
  for destination in local remote; do
    make_case "race-$destination"
    : > "$PARENT/config/auto-placement"
    set_cap "$PARENT" 1
    set_cap "$HOST_A" 2
    if [ "$destination" = local ]; then
      busy "$HOST_A" 1
      expected_host=mbp
    else
      busy "$PARENT" 0
      set_cap "$PARENT" 2
      busy "$PARENT" 1
      set_cap "$HOST_A" 1
      expected_host=
    fi
    make_brief a1 --mode local-only
    add_item a1
    FM_FAKE_FILL=$destination auto_spawn a1
    expect_code 0 "$SPAWN_RC" "lane-race fallback ($SPAWN_OUT)"
    assert_contains "$SPAWN_OUT" "deferred a1 at spawn; trying the next machine" "stale admission was accepted"
    assert_equals "$expected_host" "$(meta_value a1 remote_worker_host)" "task did not reach remaining machine"
    if [ "$destination" = local ]; then
      assert_equals 0 "$(windows "$PRIMARY_BIN")" "full local destination launched"
      assert_equals 1 "$(windows "$HOST_BIN")" "fallback host did not launch"
    else
      assert_equals 1 "$(windows "$PRIMARY_BIN")" "local fallback did not launch"
      assert_equals 0 "$(windows "$HOST_BIN")" "full remote destination launched"
      assert_absent "$PARENT/state/a1.placement" "deferral retained pending placement"
      make_brief a2 --mode local-only
      add_item a2
      auto_spawn a2 --host mbp
      expect_code 0 "$SPAWN_RC" "named full host override ($SPAWN_OUT)"
      assert_equals 1 "$(windows "$HOST_BIN")" "named host did not override lane admission"
    fi
  done
  pass "automatic destinations recheck lanes while named destinations override"
}

fm_test_run test_share_of_own_cap_wins test_ties_break_on_open_lanes_then_this_machine \
  test_unreachable_and_uncapped_hosts_are_skipped test_this_machine_needs_its_cap \
  test_placed_tasks_count_on_their_host \
  test_spawn_off_by_default test_spawn_places_on_the_emptier_host \
  test_spawn_stays_here_when_this_machine_is_emptier test_spawn_named_machine_wins \
  test_spawn_nothing_admits_stays_queued test_spawn_deferral_falls_to_next_machine \
  test_spawn_lost_answer_reruns_on_same_host test_spawn_rechecks_lane_admission
