#!/usr/bin/env bash
# tests/fm-teardown-host.test.sh - fm-teardown.sh cleans up a ship or scout
# placed on a worker host in two legs (docs/remote-workers.md). The primary
# places the task with the real fm-spawn --host, then runs the real
# fm-teardown and fm-on; a fake ssh decodes fm-on's argv stream and runs the
# named command in a fake worker-host home with the real host leg
# (fm-remote-worker-control.sh) and the host's own fm-teardown underneath it,
# as tests/fm-spawn-host.test.sh does for placement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the backlog transition is inert without it)\n'
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-teardown-host)
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

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
  # FM_FAKE_SSH_DOWN=1 it never reaches the host; with FM_FAKE_SSH_LOSE_VERB set
  # to a host-leg verb, the host runs that verb and its answer is lost, as an
  # SSH exit 255 after the remote side finished.
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
if [ "\${FM_FAKE_SSH_PAUSE_TEARDOWN:-}" = 1 ] && [ "\${argv[1]:-}" = teardown ]; then
  touch "$CASE/host-finished"
  while [ ! -f "$CASE/release-host" ]; do sleep 0.05; done
fi
[ -z "\${FM_FAKE_SSH_LOSE_VERB:-}" ] || [ "\${argv[1]:-}" != "\$FM_FAKE_SSH_LOSE_VERB" ] || exit 255
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


# Place local-only ship <id> on the fake host through the real fm-spawn --host.
place_ship() {  # <id>
  local out
  make_brief "$1" --mode local-only --journal
  add_item "$1"
  out=$(primary "$SPAWN" "$1" sample --host mbp --mode local-only --yolo off --harness claude 2>&1) \
    || fail "placing $1 failed: $out"
  mkdir -p "$HOST_HOME/data/$1"
  printf 'what %s did\n' "$1" > "$HOST_HOME/data/$1/journal.md"
  printf 'working: placed\n' >> "$PARENT/state/$1.status"
}

# The primary record is still in place and the item has not moved.
assert_record_kept() {  # <id> <why>
  assert_present "$PARENT/state/$1.meta" "$2: the primary record was removed"
  assert_absent "$PARENT/state/$1.backlog-close" "$2: a pending backlog close was recorded"
  assert_equals in_flight "$(row_state "$1")" "$2: the backlog item moved"
}

# Every primary record, status included, is still in place.
assert_preserved() {  # <id> <why>
  assert_record_kept "$1" "$2"
  assert_present "$PARENT/state/$1.status" "$2: the primary status was retired"
}


mirror_sources() {
  primary "$ROOT/bin/fm-procevent.sh" list 2>&1 || true
}

test_two_leg_cleanup() {
  local out
  make_case success
  place_ship t1
  assert_contains "$(mirror_sources)" "remote-worker-mbp" "the fixture did not arm the mirror"
  out=$(primary "$TEARDOWN" t1 2>&1) || fail "two-leg cleanup failed: $out"
  assert_contains "$out" "teardown t1 complete (worker host mbp)" "cleanup did not report both legs"
  assert_absent "$HOST_HOME/state/t1.meta" "leg one left the host task record"
  assert_absent "$HOST_HOME/state/t1.remote-worker" "leg one left the host placement claim"
  assert_equals "what t1 did" "$(cat "$PARENT/data/t1/journal.md" 2>/dev/null)" "the journal was not fetched before the host released its claim"
  assert_absent "$PARENT/state/t1.meta" "leg two left the primary record"
  assert_absent "$PARENT/state/t1.status" "leg two left the primary status"
  assert_absent "$PARENT/state/t1.backlog-close" "leg two left its pending close"
  assert_equals done "$(row_state t1)" "leg two did not close the backlog item"
  assert_not_contains "$(mirror_sources)" "remote-worker-mbp" "the last member's cleanup left the host mirror armed"
  pass "cleanup runs the host's own teardown, fetches the journal, then retires the primary records and closes the item"
}

test_unreachable_host_preserves_records() {
  local out rc=0
  make_case down
  place_ship d1
  out=$(FM_FAKE_SSH_DOWN=1 primary "$TEARDOWN" d1 2>&1) || rc=$?
  [ "$rc" -eq 255 ] || fail "an unreachable host did not exit 255 (rc=$rc): $out"
  assert_preserved d1 "an unreachable host"
  assert_present "$HOST_HOME/state/d1.meta" "an unreachable host lost its record"
  assert_present "$HOST_HOME/state/d1.remote-worker" "an unreachable host lost its claim"
  assert_absent "$PARENT/data/d1/journal.md" "an unreachable host produced a journal"
  pass "an SSH exit 255 before the host is reached preserves every record and moves nothing"
}

test_lost_answer_reruns_safely() {
  local out rc=0
  make_case lost
  place_ship l1
  out=$(FM_FAKE_SSH_LOSE_VERB=teardown primary "$TEARDOWN" l1 2>&1) || rc=$?
  [ "$rc" -eq 255 ] || fail "a lost host answer did not exit 255 (rc=$rc): $out"
  assert_contains "$out" "re-run this cleanup" "the unknown outcome did not say how to repair it"
  assert_preserved l1 "a lost host answer"
  assert_absent "$HOST_HOME/state/l1.meta" "the host did not finish cleanup before its answer was lost"
  assert_contains "$(mirror_sources)" "remote-worker-mbp" "a lost host answer disarmed the mirror"
  out=$(primary "$TEARDOWN" l1 2>&1) || fail "re-running after a lost host answer failed: $out"
  assert_contains "$out" "no task record remains on this worker host" "the re-run did not reuse the host's finished cleanup"
  assert_contains "$out" "teardown l1 complete (worker host mbp)" "the re-run did not finish leg two"
  assert_absent "$PARENT/state/l1.meta" "the re-run left the primary record"
  assert_equals done "$(row_state l1)" "the re-run did not close the backlog item"
  assert_equals "what l1 did" "$(cat "$PARENT/data/l1/journal.md")" "a refused read after host cleanup lost the cached journal"
  pass "an SSH exit 255 after the host finished keeps every primary record, and a re-run finishes leg two"
}

test_host_refusal_passes_through() {
  local out rc=0
  make_case unlanded
  place_ship u1
  printf 'unsaved\n' > "$WT_DIR/scratch.txt"
  out=$(primary "$TEARDOWN" u1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "cleanup succeeded over unlanded host work: $out"
  assert_contains "$out" "worker host mbp: REFUSED" "the host's refusal was not passed through"
  assert_contains "$out" "worker host mbp refused to clean up u1" "the primary did not report the host refusal"
  assert_preserved u1 "a host refusal"
  assert_present "$HOST_HOME/state/u1.meta" "a host refusal removed the host record"
  assert_present "$HOST_HOME/state/u1.remote-worker" "a host refusal released the host claim"
  assert_present "$WT_DIR/scratch.txt" "a host refusal discarded the unlanded work"
  assert_equals "what u1 did" "$(cat "$PARENT/data/u1/journal.md")" "the refused cleanup did not fetch the initial journal"
  printf 'final journal\n' > "$HOST_HOME/data/u1/journal.md"
  out=$(primary "$TEARDOWN" u1 --force 2>&1) || fail "a forced cleanup did not forward --force: $out"
  assert_equals "final journal" "$(cat "$PARENT/data/u1/journal.md")" "the retry kept the stale journal instead of refreshing it"
  assert_absent "$HOST_HOME/state/u1.meta" "the forced cleanup left the host record"
  assert_absent "$PARENT/state/u1.meta" "the forced cleanup left the primary record"
  assert_equals done "$(row_state u1)" "the forced cleanup did not close the backlog item"
  pass "a host refusal for unlanded work passes through untouched, and only an explicit --force crosses"
}

test_sibling_keeps_mirror() {
  local out
  make_case sibling
  place_ship s1
  # A second placement on the same host, recorded here only: it keeps the
  # host's mirror source in use after s1 is cleaned up.
  fm_write_meta "$PARENT/state/s2.meta" kind=ship remote_worker_host=mbp \
    "remote_root=$ROOT" "remote_home=$HOST_HOME" remote_target=firstmate:fm-s2
  out=$(primary "$TEARDOWN" s1 2>&1) || fail "cleanup beside a sibling failed: $out"
  assert_absent "$PARENT/state/s1.meta" "cleanup left the primary record"
  assert_present "$PARENT/state/s2.meta" "cleanup touched the sibling record"
  assert_contains "$(mirror_sources)" "remote-worker-mbp" "cleanup disarmed a mirror the sibling still uses"
  pass "cleanup releases only its own task from a host mirror other tasks still use"
}

test_retirement_waits_for_mirror() {
  local pid i
  make_case serialization
  place_ship m1
  FM_FAKE_SSH_PAUSE_TEARDOWN=1 primary "$TEARDOWN" m1 > "$CASE/cleanup.out" 2>&1 &
  pid=$!
  for ((i=0; i<600; i++)); do
    [ ! -f "$CASE/host-finished" ] || break
    sleep 0.05
  done
  assert_present "$CASE/host-finished" "cleanup did not complete its host leg"
  . "$ROOT/bin/fm-procevent-remote-worker.sh"
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_remote_worker_with_lifecycle_lock "$PARENT/state" mbp hold_mirror_during_retirement \
    || fail "could not exercise mirror serialization"
  wait "$pid" || fail "cleanup failed after mirror release: $(cat "$CASE/cleanup.out")"
  assert_absent "$PARENT/state/m1.meta" "cleanup did not resume after mirror release"
  assert_absent "$PARENT/state/m1.status" "cleanup left status after mirror release"
  pass "primary retirement waits for the mirror lifecycle lock after the host leg"
}

hold_mirror_during_retirement() {
  touch "$CASE/release-host"
  sleep 1
  assert_present "$PARENT/state/m1.status" "cleanup retired status while mirror ingestion could still run"
  assert_present "$PARENT/state/m1.meta" "cleanup removed membership while mirror ingestion could still run"
}

test_backlog_failure_retires_mirror() {
  local transition verb out rc real_tasks
  real_tasks=$(command -v tasks-axi)
  for transition in close retain; do
    make_case "backlog-failure-$transition"
    place_ship b1
    verb=done
    if [ "$transition" = retain ]; then
      primary "$ROOT/bin/fm-captain-hold.sh" hold b1 --reason 'Captain approval needed' >/dev/null \
        || fail "could not hold b1 for the captain"
      verb=reopen
    fi
    mkdir -p "$CASE/failing-tools" "$PARENT/state/remote-workers/mbp"
    printf 'schema=fm-remote-worker-cursor.v1\noffset=0\nprefix_sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n' \
      > "$PARENT/state/remote-workers/mbp/b1.cursor"
    cat > "$CASE/failing-tools/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "$verb" ] && [ "\${2:-}" = b1 ]; then
  echo 'injected backlog mutation failure' >&2
  exit 1
fi
exec "$real_tasks" "\$@"
SH
    chmod +x "$CASE/failing-tools/tasks-axi"
    rc=0
    out=$(PATH="$CASE/failing-tools:$PATH" primary "$TEARDOWN" b1 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$transition reported success despite a backlog failure: $out"
    assert_contains "$out" 'injected backlog mutation failure' "$transition did not reach the injected failure"
    assert_absent "$HOST_HOME/state/b1.meta" "$transition did not finish the host leg"
    assert_absent "$PARENT/state/b1.meta" "$transition did not remove the primary record"
    assert_present "$PARENT/state/b1.backlog-close" "$transition lost its replayable backlog marker"
    assert_absent "$PARENT/state/remote-workers/mbp/b1.cursor" "$transition failure left a cursor for a removed member"
    assert_not_contains "$(mirror_sources)" remote-worker-mbp "$transition failure left the unused host mirror armed"
  done
  pass "failed backlog close and retain still retire the removed task's mirror and cursor"
}

test_route_drift_refused() {
  local out rc=0
  make_case drift
  place_ship r1
  perl -0pi -e 's/home: [^)]*\)/home: \/elsewhere; added 2026-11-10)/' "$PARENT/data/worker-hosts.md"
  : > "$CASE/ssh.log"
  out=$(primary "$TEARDOWN" r1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "cleanup accepted a drifted worker host route: $out"
  assert_contains "$out" "no longer matches worker host mbp's registry record" "the drift was not named"
  assert_preserved r1 "a drifted route"
  assert_equals "" "$(cat "$CASE/ssh.log")" "a drifted route still reached for the host"
  pass "cleanup refuses a placement whose route no longer matches the registry before reaching any host"
}

test_scout_report_and_gate() {
  local out rc=0
  make_case scout
  make_brief c1 --scout
  add_item c1 scout
  out=$(primary "$SPAWN" c1 sample --scout --host mbp --harness claude 2>&1) || fail "placing scout c1 failed: $out"
  out=$(primary "$TEARDOWN" c1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a scout with no report anywhere was cleaned up: $out"
  assert_contains "$out" "has no report" "the missing report was not named"
  assert_present "$HOST_HOME/state/c1.meta" "a missing report still reached the host's cleanup"
  assert_record_kept c1 "a missing report"
  mkdir -p "$HOST_HOME/data/c1"
  printf 'findings\n' > "$HOST_HOME/data/c1/report.md"
  rc=0
  out=$(primary "$TEARDOWN" c1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a scout without a captain-call inventory was cleaned up: $out"
  assert_contains "$out" "captain-call completion gate" "the inventory gate did not run here"
  assert_equals findings "$(cat "$PARENT/data/c1/report.md" 2>/dev/null)" "the report was not fetched before the gate"
  assert_present "$HOST_HOME/state/c1.meta" "the inventory gate still reached the host's cleanup"
  assert_record_kept c1 "the inventory gate"
  printf 'final findings\n' > "$HOST_HOME/data/c1/report.md"
  rc=0
  out=$(primary "$TEARDOWN" c1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a scout without inventory was cleaned up on retry: $out"
  assert_equals "final findings" "$(cat "$PARENT/data/c1/report.md")" "the gate retry kept the stale report instead of refreshing it"
  primary "$ROOT/bin/fm-captain-hold.sh" complete c1 --none >/dev/null 2>&1 || fail "could not complete c1's inventory"
  out=$(primary "$TEARDOWN" c1 2>&1) || fail "a scout with its report and inventory was not cleaned up: $out"
  assert_absent "$HOST_HOME/state/c1.meta" "leg one left the scout's host record"
  assert_absent "$PARENT/state/c1.meta" "leg two left the scout's primary record"
  assert_equals done "$(row_state c1)" "leg two did not close the scout's backlog item"
  pass "a scout's report is fetched and its captain-call gate checked here before the host cleans up"
}

fm_test_run test_two_leg_cleanup test_unreachable_host_preserves_records \
  test_lost_answer_reruns_safely test_host_refusal_passes_through \
  test_sibling_keeps_mirror test_retirement_waits_for_mirror test_backlog_failure_retires_mirror \
  test_route_drift_refused test_scout_report_and_gate
