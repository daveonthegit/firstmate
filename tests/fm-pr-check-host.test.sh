#!/usr/bin/env bash
# tests/fm-pr-check-host.test.sh - the primary records the ready PR of a ship it
# placed on a worker host (docs/remote-workers.md). The primary runs the real
# fm-pr-check with fm-on; a fake ssh decodes fm-on's argv stream and runs the
# named command in a fake worker-host home with the real host leg
# (fm-remote-worker-control.sh named-head) and the host's own named-head gate
# underneath it (real git worktree), in the style of
# tests/fm-placed-task-control.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-check-host)
CONTROL="$ROOT/bin/fm-remote-worker-control.sh"
URL=https://github.com/acme/sample/pull/7
DONE_LINE="done: PR $URL checks green"
TASK_BODY="## Captain's intent
Ship the placed sample change.

## Firstmate spec
Edit README only."

# Sets CASE PARENT HOST_HOME WT_DIR HOST_BIN PRIMARY_BIN for one primary home
# whose record t1 names worker host mbp, and one worker-host home where the
# real host leg placed no-mistakes ship t1 on project sample.
make_case() {  # <name>
  local out fakebin
  CASE="$TMP_ROOT/$1"
  PARENT="$CASE/parent"
  HOST_HOME="$CASE/host"
  WT_DIR="$CASE/wt"
  mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" \
    "$HOST_HOME/data" "$HOST_HOME/projects" "$HOST_HOME/state" "$HOST_HOME/config" "$HOST_HOME/user-home"
  printf '%s\n' "$$" > "$PARENT/state/.lock"
  printf 'manual\n' > "$PARENT/config/backlog-backend"
  cat > "$PARENT/data/worker-hosts.md" <<EOF
# Worker hosts

- mbp - spare MacBook worker host (host: remote-mac; root: $ROOT; home: $HOST_HOME; added 2026-11-10)
EOF
  printf 'claude\n' > "$HOST_HOME/config/crew-harness"
  printf 'manual\n' > "$HOST_HOME/config/backlog-backend"
  : > "$HOST_HOME/.fm-worker-host"
  printf '%s\n' "$$" > "$HOST_HOME/state/.lock"
  touch "$HOST_HOME/state/.last-watcher-beat"
  fm_git_worktree "$HOST_HOME/projects/sample" "$WT_DIR" "fm/t1"

  fakebin=$(fm_fakebin "$CASE/host-tools")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
window_file="$(dirname "$0")/.spawn-window"
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
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes
  HOST_BIN=$fakebin

  # The primary has no copy of the work and no local backend: its tmux logs
  # any touch, and its gh answers nothing, so no forge head stands in for the
  # host's verdict.
  PRIMARY_BIN=$(fm_fakebin "$CASE/primary-tools")
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 99\n' "$CASE/backend.log" > "$PRIMARY_BIN/tmux"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$PRIMARY_BIN/gh"
  chmod +x "$PRIMARY_BIN/tmux" "$PRIMARY_BIN/gh"

  # FM_FAKE_SSH_DOWN=1 never reaches the host; FM_FAKE_SSH_LOSE_RESULT=1 runs
  # the command on the host and loses its answer (exit 255).
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
printf 'argv:%s\n' "\${argv[*]}" >> "$CASE/ssh.log"
rc=0
env -u FM_SUPERVISION_ACTOR -u FM_TRACE_CONTEXT -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \\
  -u FM_PROJECTS_OVERRIDE -u FM_HOME FM_ROOT_OVERRIDE='' FM_HOME="\$home" \\
  HOME="$HOST_HOME/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 FM_GH_ACCOUNT=none \\
  FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" PATH="$HOST_BIN:\$PATH" \\
  "\$root/bin/\${argv[0]}" "\${argv[@]:1}" || rc=\$?
[ "\${FM_FAKE_SSH_LOSE_RESULT:-}" != 1 ] || exit 255
exit "\$rc"
SH
  chmod +x "$CASE/fake-ssh"

  out=$(printf '%s\n' "$TASK_BODY" | on_host "$CONTROL" spawn t1 sample \
    --mode no-mistakes --yolo off --harness claude 2>&1) || fail "the host leg could not place t1: $out"
  fm_write_meta "$PARENT/state/t1.meta" "window=remote:t1" "endpoint_task_id=t1" "harness=claude" \
    "kind=ship" "mode=no-mistakes" "yolo=off" "branch=fm/t1" "spawn_gen=s1.1.1" \
    "remote_worker_host=mbp" "remote_root=$ROOT" "remote_home=$HOST_HOME" \
    "remote_backend=tmux" "remote_target=firstmate:fm-t1" "remote_worktree=$WT_DIR" \
    "remote_project=$HOST_HOME/projects/sample"
  : > "$CASE/ssh.log"
}

on_host() {  # <command...>: run one real script in the worker-host home
  env -u FM_TRACE_CONTEXT -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE='' FM_HOME="$HOST_HOME" \
    HOME="$HOST_HOME/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_GH_ACCOUNT=none FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$HOST_BIN:$PATH" "$@"
}

primary() {  # <command...>: run one real script in the primary home
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$CASE/fake-ssh" FM_GH_ACCOUNT=none \
    PATH="$PRIMARY_BIN:$PATH" "$@"
}

commit_on_host() {  # <file>: one new commit in the host's disposable copy
  printf 'change\n' > "$WT_DIR/$1"
  git -C "$WT_DIR" add "$1"
  git -C "$WT_DIR" -c user.name=t -c user.email=t@example.invalid commit --quiet -m "change $1"
}

recorded_pr() {
  grep '^pr=' "$PARENT/state/t1.meta" | tail -1 | cut -d= -f2- || true
}

test_pushed_host_head_registers() {
  local out rc=0
  make_case pushed
  commit_on_host a.txt
  git -C "$WT_DIR" push --quiet origin fm/t1 2>/dev/null || fail "the host copy could not push its branch"
  out=$(primary bash "$ROOT/bin/fm-pr-check.sh" t1 "$URL" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a placed task's pushed ready PR was not recorded (rc=$rc): $out"
  assert_equals "$URL" "$(recorded_pr)" "the placed task's PR was not recorded"
  assert_present "$PARENT/state/t1.check.sh" "merge monitoring was not armed for the placed task"
  assert_contains "$(cat "$CASE/ssh.log")" "argv:fm-remote-worker-control.sh named-head t1 $DONE_LINE" \
    "the named head was not verified through the host leg"
  assert_absent "$CASE/backend.log" "recording the PR touched the primary's local backend"
  pass "a placed task's ready PR whose head the host pushed is recorded and armed"
}

test_copy_only_head_is_refused() {
  local out rc=0 sha
  make_case copy-only
  commit_on_host b.txt
  sha=$(git -C "$WT_DIR" rev-parse HEAD)
  out=$(primary bash "$ROOT/bin/fm-pr-check.sh" t1 "$URL" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a head only in the host's disposable copy was not refused (rc=$rc): $out"
  assert_contains "$out" "on worker host mbp: named head $sha is unreachable outside the worker copy" \
    "the refusal did not carry the host's own reason"
  assert_equals "" "$(recorded_pr)" "a refused head still recorded the PR"
  assert_absent "$PARENT/state/t1.check.sh" "a refused head still armed merge monitoring"
  pass "a placed task's head that exists only in the host's disposable copy is refused"

  sed 's/^endpoint_task_id=t1$/endpoint_task_id=t2/' "$PARENT/state/t1.meta" > "$PARENT/state/t2.meta"
  chmod 600 "$PARENT/state/t2.meta"
  rc=0
  out=$(primary bash "$ROOT/bin/fm-pr-check.sh" t2 "$URL" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a task the host does not hold was not refused (rc=$rc): $out"
  assert_contains "$out" "on worker host mbp: task t2 was not placed on this worker host" \
    "the refusal did not say the host holds no such task"
  assert_absent "$PARENT/state/t2.check.sh" "a task the host does not hold still armed merge monitoring"
  pass "a placed task the host does not hold is refused, not retried as unreachable"
}

test_unreachable_host_is_retryable() {
  local out rc=0
  make_case unreachable
  commit_on_host c.txt
  git -C "$WT_DIR" push --quiet origin fm/t1 2>/dev/null || fail "the host copy could not push its branch"
  out=$(FM_FAKE_SSH_DOWN=1 primary bash "$ROOT/bin/fm-pr-check.sh" t1 "$URL" 2>&1) || rc=$?
  [ "$rc" -eq 75 ] || fail "an unreachable host did not exit 75 (rc=$rc): $out"
  assert_contains "$out" "named head cannot be verified now: worker host mbp is unreachable" \
    "an unreachable host was not reported as cannot-verify-now"
  assert_equals "" "$(recorded_pr)" "an unreachable host still recorded the PR"
  rc=0
  out=$(FM_FAKE_SSH_LOSE_RESULT=1 primary bash "$ROOT/bin/fm-pr-check.sh" t1 "$URL" 2>&1) || rc=$?
  [ "$rc" -eq 75 ] || fail "a lost host answer did not exit 75 (rc=$rc): $out"
  assert_equals "" "$(recorded_pr)" "a lost host answer still recorded the PR"
  pass "an unreachable host or lost answer records nothing and exits 75 to retry"

  printf '%s\n' "$DONE_LINE" > "$PARENT/state/t1.status"
  out=$(FM_FAKE_SSH_DOWN=1 primary bash "$ROOT/bin/fm-pr-check.sh" scan 2>&1) || fail "the scan failed: $out"
  assert_equals "" "$out" "the scan reported an unreachable host as a refusal"
  assert_absent "$PARENT/state/t1.pr-register-refused" "the scan marked an unreachable host as refused"
  assert_equals "" "$(recorded_pr)" "the scan recorded the PR while the host was unreachable"
  out=$(primary bash "$ROOT/bin/fm-pr-check.sh" scan 2>&1) || fail "the scan failed: $out"
  assert_equals "$URL" "$(recorded_pr)" "the scan did not record the PR once the host answered"
  assert_present "$PARENT/state/t1.check.sh" "the scan did not arm merge monitoring once the host answered"
  pass "the PR-register scan retries an unreachable host silently and records once it answers"
}

fm_test_run test_pushed_host_head_registers test_copy_only_head_is_refused test_unreachable_host_is_retryable
