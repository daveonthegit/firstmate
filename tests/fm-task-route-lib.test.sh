#!/usr/bin/env bash
# tests/fm-task-route-lib.test.sh - the shared routing helper every per-task
# entry point uses to tell a local task from one placed on a worker host and
# from a remote second mate (bin/fm-task-route-lib.sh). The host-leg behavior
# of each placed-task entry point is covered by
# tests/fm-placed-task-control.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-route-lib.sh
. "$ROOT/bin/fm-task-route-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-route-lib)

route_of() {  # <meta> -> "<route> <host>" or "refused: <error>"
  if fm_task_route "$1"; then
    printf '%s %s\n' "$FM_TASK_ROUTE" "$FM_TASK_ROUTE_HOST"
  else
    printf 'refused: %s|%s|%s\n' "$FM_TASK_ROUTE_ERROR" "$FM_TASK_ROUTE" "$FM_TASK_ROUTE_HOST"
  fi
}

test_routes() {
  local meta="$TMP_ROOT/t.meta"
  fm_write_meta "$meta" "kind=ship" "window=fm-t" "worktree=/tmp/wt"
  assert_equals "local " "$(route_of "$meta")" "a local record did not route locally"
  fm_write_meta "$meta" "kind=ship" "remote_worker_host=old" "remote_worker_host=mbp" "remote_home=/h"
  assert_equals "worker-host mbp" "$(route_of "$meta")" "a placed record did not route to its worker host"
  fm_write_meta "$meta" "kind=secondmate" "remote_host=remote-mac" "remote_root=/r"
  assert_equals "remote-secondmate remote-mac" "$(route_of "$meta")" "a remote second mate did not route to its host"
  fm_write_meta "$meta" "kind=ship" "remote_worker_host=" "remote_host="
  assert_equals "local " "$(route_of "$meta")" "empty routing keys did not mean local"
  pass "the helper routes local, placed, and remote second-mate records by their recorded keys"
}

test_refusals() {
  local meta="$TMP_ROOT/r.meta" out
  fm_write_meta "$meta" "kind=ship" "remote_worker_host=mbp" "remote_host=remote-mac"
  out=$(route_of "$meta")
  assert_contains "$out" "refused: " "a record naming both remote routes was accepted"
  assert_contains "$out" "names both worker host mbp and remote second-mate host remote-mac" "the contradiction was not named"
  assert_contains "$out" "||" "a refusal left a route behind"
  fm_write_meta "$meta" "kind=ship" "remote_worker_host=../evil"
  assert_contains "$(route_of "$meta")" "unsafe worker host id" "an unsafe worker host id was accepted"
  assert_contains "$(route_of "$TMP_ROOT/missing.meta")" "no readable task record" "a missing record was accepted"
  ln -s "$meta" "$TMP_ROOT/link.meta"
  assert_contains "$(route_of "$TMP_ROOT/link.meta")" "no readable task record" "a symlinked record was accepted"
  pass "the helper refuses contradictory, unsafe, missing, and symlinked records"
}

test_placed_entry_points() {
  local home="$TMP_ROOT/primary" tools out rc kind target verb
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'manual\n' > "$home/config/backlog-backend"
  tools=$(fm_fakebin "$TMP_ROOT/tools")
  printf '#!/usr/bin/env bash\nprintf "backend touched\\n" >> "%s"\nexit 99\n' "$home/backend.log" > "$tools/tmux"
  chmod +x "$tools/tmux"
  for kind in ship scout; do
    fm_write_meta "$home/state/t.meta" "kind=$kind" "remote_worker_host=mbp" \
      "window=remote:t" "remote_backend=t3code" "remote_target=thread-1"
    for target in t fm-t remote:t; do
      for verb in send peek; do
        rc=0
        if [ "$verb" = send ]; then
          out=$(FM_HOME="$home" PATH="$tools:$PATH" bash "$ROOT/bin/fm-send.sh" "$target" hello 2>&1) || rc=$?
        else
          out=$(FM_HOME="$home" PATH="$tools:$PATH" bash "$ROOT/bin/fm-peek.sh" "$target" 2>&1) || rc=$?
        fi
        [ "$rc" -ne 0 ] || fail "$verb succeeded for placed $kind via $target with no registered host"
        assert_contains "$out" 'worker host mbp' "$verb did not identify placement via $target"
      done
    done
    for verb in interrupt exit relaunch; do
      rc=0
      out=$(FM_HOME="$home" bash "$ROOT/bin/fm-control.sh" t "$verb" 2>&1) || rc=$?
      [ "$rc" -ne 0 ] || fail "control $verb accepted placed $kind"
      assert_contains "$out" 'worker host mbp' "control $verb did not identify placement"
    done
    for verb in query answer; do
      rc=0
      case "$verb" in
        query) out=$(FM_HOME="$home" bash "$ROOT/bin/fm-t3-answer.sh" t 2>&1) || rc=$? ;;
        answer) out=$(FM_HOME="$home" bash "$ROOT/bin/fm-t3-answer.sh" t request '{}' 2>&1) || rc=$? ;;
      esac
      [ "$rc" -ne 0 ] || fail "$verb succeeded for placed $kind with no registered host"
      assert_contains "$out" 'worker host mbp' "$verb did not identify placement"
    done
    # Cleanup is supported through the host leg (tests/fm-teardown-host.test.sh);
    # with no registered host it refuses before any local or remote action.
    rc=0
    out=$(FM_HOME="$home" PATH="$tools:$PATH" bash "$ROOT/bin/fm-teardown.sh" t 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "cleanup of placed $kind succeeded with no registered worker host"
    assert_contains "$out" 'worker host mbp is not resolvable' "cleanup did not name the unresolvable host"
    out=$(FM_HOME="$home" bash "$ROOT/bin/fm-crew-state.sh" t 2>&1) || fail "crew-state failed: $out"
    assert_contains "$out" 'state: unknown' 'placed current state was guessed'
    assert_contains "$out" 'unknown-remote: worker host mbp' 'crew-state did not identify placement'
    assert_not_contains "$out" 'worktree gone' 'a placed worker was interpreted locally'
    assert_present "$home/state/t.meta" 'cleanup removed the placed record'
    assert_absent "$home/backend.log" 'a placed operation touched the local backend'
  done
  pass "placed ship and scout operations route to their host, never a local backend, and cleanup refuses an unresolvable host"
}

fm_test_run test_routes test_refusals test_placed_entry_points
