#!/usr/bin/env bash
# tests/fm-remote-worker-control.test.sh - the host-local leg a primary drives
# for a ship or scout it places on a worker host (docs/remote-workers.md).
# Every case runs the real bin/fm-remote-worker-control.sh inside a fake
# worker-host home with the real fm-brief, fm-spawn (fake tmux, real git
# worktree), fm-send, fm-remote-file, and fm-teardown underneath it, exactly
# as the remote job worker would run it after bin/fm-on.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-worker-control)
CONTROL="$ROOT/bin/fm-remote-worker-control.sh"

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
    printf '%s\n' "$name" > "$window_file"
    ;;
  capture-pane)
    case "${FM_FAKE_CAPTURE_MODE:-}" in
      missing) printf 'pane not found\n' >&2; exit 7 ;;
      large) perl -e 'print "x" x 131072' ;;
      large-failure) perl -e 'print "x" x 131072'; exit 7 ;;
      *) printf 'worker output\n' ;;
    esac
    ;;
  kill-window) : > "$window_file" ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes
  printf '%s\n' "$fakebin"
}

# Sets HOST_HOME WT_DIR FAKEBIN for one isolated worker-host home holding one
# cloned project, sample, and the pooled copy the fake pane reports for <task>.
make_host() {  # <name> <task>
  local dir="$TMP_ROOT/$1"
  HOST_HOME="$dir/host"
  WT_DIR="$dir/wt"
  mkdir -p "$HOST_HOME/data" "$HOST_HOME/projects" "$HOST_HOME/state" "$HOST_HOME/config" "$HOST_HOME/user-home"
  printf 'claude\n' > "$HOST_HOME/config/crew-harness"
  printf 'manual\n' > "$HOST_HOME/config/backlog-backend"
  printf 'mbp\n' > "$HOST_HOME/.fm-worker-host"
  printf '%s\n' "$$" > "$HOST_HOME/state/.lock"
  touch "$HOST_HOME/state/.last-watcher-beat"
  fm_git_worktree "$HOST_HOME/projects/sample" "$WT_DIR" "fm/$2"
  FAKEBIN=$(make_fakebin "$dir")
}

on_host() {  # <command...>: run one real script as the remote job worker would
  env -u FM_TRACE_CONTEXT -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE='' FM_HOME="$HOST_HOME" \
    HOME="$HOST_HOME/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_GH_ACCOUNT=none FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" "$@"
}

TASK_BODY="## Captain's intent
Ship the remote sample change.

## Firstmate spec
Edit README only."

test_spawn_renders_host_brief_and_reports_route() {
  local out brief launch
  make_host spawn t1
  out=$(printf '%s\n' "$TASK_BODY" | on_host "$CONTROL" spawn t1 sample \
    --mode local-only --yolo off --harness claude 2>"$TMP_ROOT/spawn.err") \
    || fail "remote worker spawn failed: $(cat "$TMP_ROOT/spawn.err")"
  assert_contains "$out" "schema=fm-remote-worker-control.v1" "the route block has no schema line"
  assert_contains "$out" "task=t1" "the route block does not name the task"
  assert_contains "$out" "kind=ship" "the route block does not name the kind"
  assert_contains "$out" "backend=tmux" "the route block does not name the host backend"
  assert_contains "$out" "worktree=" "the route block does not name the host worktree"
  assert_contains "$out" "mode=local-only" "the route block does not carry the delivery mode"
  assert_present "$HOST_HOME/state/t1.remote-worker" "spawn left no placement claim"
  brief=$(cat "$HOST_HOME/data/t1/brief.md")
  assert_contains "$brief" "Ship the remote sample change." "the primary's captain intent was not carried"
  assert_contains "$brief" "Edit README only." "the primary's firstmate spec was not carried"
  assert_not_contains "$brief" "{TASK}" "the scaffold placeholder survived"
  assert_contains "$brief" "$HOST_HOME/state/t1.status" "the brief does not name the host's own status file"
  assert_contains "$brief" "Delivery contract: mode=local-only" "the host brief lost its delivery contract"
  launch=$(cat "$HOST_HOME/data/t1/launch-brief.md")
  assert_contains "$launch" "$HOST_HOME/state/t1.inbox" "the launch brief does not name the host's steering inbox"
  pass "spawn renders the brief on the host, fills the primary's # Task, launches, and reports the route"

  out=$(printf '%s\n' "$TASK_BODY" | on_host "$CONTROL" spawn t1 sample \
    --mode local-only --yolo off --harness claude 2>"$TMP_ROOT/respawn.err") \
    || fail "a repeated spawn of a placed task failed: $(cat "$TMP_ROOT/respawn.err")"
  assert_contains "$out" "task=t1" "a repeated spawn did not report the existing route"
  assert_contains "$(cat "$TMP_ROOT/respawn.err")" "already placed" "a repeated spawn did not say it reused the route"
  [ "$(grep -c '^new-window' "$FAKEBIN/tmux.log")" -eq 1 ] \
    || fail "a repeated spawn launched a second endpoint"
  pass "a repeated spawn of a placed task is idempotent and launches nothing"

  out=$(on_host "$CONTROL" route t1) || fail "route failed for a placed task"
  assert_contains "$out" "task=t1" "route did not print the placed task"
  out=$(on_host "$CONTROL" state t1 2>&1) || fail "state failed for a placed task: $out"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] || fail "state did not print exactly one crew-state line: $out"
  case "$out" in
    'state: '*' source: '*) ;;
    *) fail "state did not print a crew-state verdict: $out" ;;
  esac
  pass "route and state answer for a placed task with the ordinary one-line crew state"

  out=$(on_host "$CONTROL" send t1 delivery-1 'continue' 2>&1) \
    || fail "send failed: $out"
  [ "$(find "$HOST_HOME/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "send did not write exactly one record"
  out=$(printf 'continue' | on_host "$CONTROL" send-stdin t1 delivery-1 2>&1) \
    || fail "a true retry through stdin failed: $out"
  [ "$(find "$HOST_HOME/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "a true retry was not deduplicated"
  mv "$HOST_HOME/state/t1.inbox/"*.msg "$HOST_HOME/state/t1.inbox/handled/"
  out=$(on_host "$CONTROL" send t1 delivery-1 'continue' 2>&1) \
    || fail "an acknowledged retry failed: $out"
  [ "$(find "$HOST_HOME/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "a true retry of an acknowledged send wrote another record"
  out=$(printf 'continue' | on_host "$CONTROL" send-stdin t1 delivery-2 2>&1) \
    || fail "a later identical steer failed: $out"
  [ "$(find "$HOST_HOME/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "an acknowledged identical steer swallowed a new delivery"
  out=$(on_host "$CONTROL" send t1 delivery-3 'continue' 2>&1) \
    || fail "a distinct pending steer failed: $out"
  [ "$(find "$HOST_HOME/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "a pending identical steer swallowed a new delivery"
  out=$(printf 'second line\nthird line' | on_host "$CONTROL" send-stdin t1 delivery-4 2>&1) \
    || fail "multiline send-stdin failed: $out"
  assert_contains "$(cat "$HOST_HOME/state/t1.inbox/"*.msg)" $'second line\nthird line' "stdin lost the multiline steer"
  if on_host "$CONTROL" send t1 --fire-and-forget old-id continue >/dev/null 2>&1; then
    fail "send accepted the removed delivery mode"
  fi
  if printf 'continue' | on_host "$CONTROL" send-stdin t1 --fire-and-forget old-id >/dev/null 2>&1; then
    fail "send-stdin accepted the removed delivery mode"
  fi
  pass "delivery tokens distinguish new steers from pending and acknowledged retries"

  out=$(on_host "$CONTROL" capture t1) || fail "ordinary capture failed"
  assert_equals 'worker output' "$out" "capture changed ordinary output"
  out=$(FM_FAKE_CAPTURE_MODE=large on_host "$CONTROL" capture t1 100) || fail "bounded capture failed"
  [ "${#out}" -eq 65536 ] || fail "capture did not enforce the byte bound"
  if FM_FAKE_CAPTURE_MODE=missing on_host "$CONTROL" capture t1 > /dev/null 2>&1; then
    fail "capture hid an unreadable endpoint"
  fi
  if FM_FAKE_CAPTURE_MODE=large-failure on_host "$CONTROL" capture t1 100 > /dev/null 2>&1; then
    fail "capture hid a failure after oversized output"
  fi
  pass "capture bounds successful output without hiding endpoint failures"

  mkdir -p "$HOST_HOME/data/t1"
  printf 'what happened\n' > "$HOST_HOME/data/t1/journal.md"
  out=$(on_host "$CONTROL" file t1 journal) || fail "file journal failed"
  assert_equals "what happened" "$out" "file did not return the journal"
  if on_host "$CONTROL" file t1 ../secrets >/dev/null 2>&1; then
    fail "file accepted a name outside report, journal, and brief"
  fi
  pass "file returns only the task's report, journal, or brief"

  if out=$(on_host "$CONTROL" control t1 relaunch 2>&1); then
    fail "control accepted relaunch for a remote worker"
  fi
  assert_contains "$out" "relaunch is not offered" "relaunch refusal did not say why"
  pass "control refuses relaunch for a remote worker"

  out=$(on_host "$CONTROL" teardown t1 --force 2>&1) || fail "forced teardown failed: $out"
  assert_absent "$HOST_HOME/state/t1.meta" "teardown left the host task record"
  assert_absent "$HOST_HOME/state/t1.remote-worker" "teardown left the placement claim"
  if on_host "$CONTROL" route t1 >/dev/null 2>&1; then
    fail "route still answered after teardown"
  fi
  pass "teardown runs the host's ordinary cleanup and releases the claim"
}

test_scout_spawn_and_journal_flag() {
  local out brief
  make_host scout s1
  out=$(printf '%s\n' "$TASK_BODY" | on_host "$CONTROL" spawn s1 sample --scout --journal --harness claude 2>&1) \
    || fail "remote scout spawn failed: $out"
  assert_contains "$out" "kind=scout" "the scout route block does not name its kind"
  brief=$(cat "$HOST_HOME/data/s1/brief.md")
  assert_contains "$brief" "$HOST_HOME/data/s1/report.md" "the scout brief does not name the host's report path"
  assert_contains "$brief" "# Work journal" "--journal did not add the work-journal section"
  assert_contains "$brief" "$HOST_HOME/data/s1/journal.md" "the journal section does not name the host's journal path"
  pass "a scout spawn renders the host's report path and the forwarded journal section"
}

test_refusals() {
  local out
  make_host refuse r1
  if out=$(printf '%s\n' "$TASK_BODY" | on_host "$CONTROL" spawn r1 sample --mode local-only --yolo off --account x 2>&1); then
    fail "spawn accepted an unsupported flag"
  fi
  assert_contains "$out" "unsupported remote worker spawn flag: --account" "an unsupported flag was not named"
  if out=$(printf '%s\n' "$TASK_BODY" | on_host "$CONTROL" spawn r1 missing --mode local-only --yolo off 2>&1); then
    fail "spawn accepted a project this host has not cloned"
  fi
  assert_contains "$out" "is not cloned on this worker host" "a missing clone was not named"
  if out=$(printf '  \n' | on_host "$CONTROL" spawn r1 sample --mode local-only --yolo off --harness claude 2>&1); then
    fail "spawn accepted an empty task body"
  fi
  assert_contains "$out" "empty # Task body" "an empty task body was not named"
  assert_absent "$HOST_HOME/state/r1.remote-worker" "a refused spawn left a placement claim"
  if out=$(on_host "$CONTROL" state r1 2>&1); then
    fail "state answered for a task no primary placed here"
  fi
  assert_contains "$out" "was not placed on this worker host" "an unplaced task was not named"
  printf 'markdown\n' > "$HOST_HOME/config/backlog-backend"
  if out=$(on_host "$CONTROL" route r1 2>&1); then
    fail "a host home with an automatic backlog was accepted"
  fi
  assert_contains "$out" "backlog-backend to manual" "an automatic host backlog was not named"
  printf 'manual\n' > "$HOST_HOME/config/backlog-backend"
  rm -f "$HOST_HOME/.fm-worker-host"
  if out=$(on_host "$CONTROL" route r1 2>&1); then
    fail "a home without the worker host marker was accepted"
  fi
  assert_contains "$out" "no .fm-worker-host marker" "a missing marker was not named"
  pass "the host leg refuses unsupported flags, missing clones, empty bodies, unplaced tasks, and unprepared homes"
}

test_capacity_deferral_passes_through_and_leaves_nothing() {
  local out rc
  make_host defer d0
  printf 'sample 1\n' > "$HOST_HOME/config/project-capacity"
  out=$(printf '%s\n' "$TASK_BODY" | on_host "$CONTROL" spawn d0 sample \
    --mode local-only --yolo off --harness claude 2>&1) || fail "the first worker on a capacity-1 host failed: $out"
  out=$(printf '%s\n' "$TASK_BODY" | on_host "$CONTROL" spawn d1 sample \
    --mode local-only --yolo off --harness claude 2>&1); rc=$?
  if [ "$rc" -ne 75 ]; then
    fail "a full host did not defer with exit 75 (rc=$rc): $out"
  fi
  assert_contains "$out" "deferred:" "the host's deferral line did not pass through"
  assert_absent "$HOST_HOME/state/d1.remote-worker" "a deferred spawn left a placement claim"
  assert_absent "$HOST_HOME/data/d1/brief.md" "a deferred spawn left its rendered brief"
  pass "a host at capacity defers with exit 75 and leaves no claim or brief behind"
}

test_spawn_renders_host_brief_and_reports_route
test_scout_spawn_and_journal_flag
test_refusals
test_capacity_deferral_passes_through_and_leaves_nothing

echo "all fm-remote-worker-control tests passed"
