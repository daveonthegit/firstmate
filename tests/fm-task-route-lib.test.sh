#!/usr/bin/env bash
# tests/fm-task-route-lib.test.sh - the shared routing helper every per-task
# entry point uses to tell a local task from one placed on a worker host and
# from a remote second mate (bin/fm-task-route-lib.sh).
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

fm_test_run test_routes test_refusals
