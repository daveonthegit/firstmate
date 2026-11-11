#!/usr/bin/env bash
# tests/fm-placed-task-control.test.sh - the primary steers, reads, peeks at,
# controls, and answers a ship it placed on a worker host
# (docs/remote-workers.md). The primary runs the real fm-send, fm-crew-state,
# fm-peek, fm-control, and fm-t3-answer with fm-on; a fake ssh decodes fm-on's
# argv stream and runs the named command in a fake worker-host home with the
# real host leg (fm-remote-worker-control.sh) and the host's own ordinary
# scripts underneath it (fake tmux, real git worktree), in the style of
# tests/fm-remote-worker-control.test.sh and tests/fm-spawn-host.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-placed-task-control)
CONTROL="$ROOT/bin/fm-remote-worker-control.sh"
TASK_BODY="## Captain's intent
Ship the placed sample change.

## Firstmate spec
Edit README only."

make_host_fakebin() {  # <dir>
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
  capture-pane) printf 'placed worker output\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes
  printf '%s\n' "$fakebin"
}

# Sets CASE PARENT HOST_HOME WT_DIR HOST_BIN PRIMARY_BIN for one primary home
# whose record t1 names worker host mbp, and one worker-host home where the
# real host leg placed t1 on project sample.
make_case() {  # <name>
  local out
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
  HOST_BIN=$(make_host_fakebin "$CASE/host-tools")

  # Any local backend touch on the primary is a defect: its tmux only logs.
  PRIMARY_BIN=$(fm_fakebin "$CASE/primary-tools")
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 99\n' "$CASE/backend.log" > "$PRIMARY_BIN/tmux"
  chmod +x "$PRIMARY_BIN/tmux"

  # The fake ssh checks fm-on's fixed transport shape, decodes the route and
  # argv it carries, and runs that tracked command as the host's job worker
  # would. FM_FAKE_SSH_DOWN=1 never reaches the host. FM_FAKE_SSH_LOSE_RESULT=1
  # runs the command on the host and loses its answer (exit 255 after the
  # remote side finished). FM_FAKE_SSH_LOSE_ONCE=<file> loses only the first
  # answer, then answers normally.
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
  -u FM_PROJECTS_OVERRIDE -u FM_SEND_PLACED_DELIVERY_ID FM_ROOT_OVERRIDE='' FM_HOME="\$home" \\
  HOME="$HOST_HOME/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 FM_GH_ACCOUNT=none \\
  FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" PATH="$HOST_BIN:\$PATH" \\
  "\$root/bin/\${argv[0]}" "\${argv[@]:1}" || rc=\$?
[ "\${FM_FAKE_SSH_LOSE_RESULT:-}" != 1 ] || exit 255
if [ -n "\${FM_FAKE_SSH_LOSE_ONCE:-}" ] && [ ! -e "\$FM_FAKE_SSH_LOSE_ONCE" ]; then
  : > "\$FM_FAKE_SSH_LOSE_ONCE"
  exit 255
fi
exit "\$rc"
SH
  chmod +x "$CASE/fake-ssh"

  out=$(printf '%s\n' "$TASK_BODY" | on_host "$CONTROL" spawn t1 sample \
    --mode local-only --yolo off --harness claude 2>&1) || fail "the host leg could not place t1: $out"
  fm_write_meta "$PARENT/state/t1.meta" "window=remote:t1" "endpoint_task_id=t1" "harness=claude" \
    "kind=ship" "mode=local-only" "yolo=off" "branch=fm/t1" "spawn_gen=s1.1.1" \
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
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$CASE/fake-ssh" \
    PATH="$PRIMARY_BIN:$PATH" "$@"
}

host_records() {  # number of pending steering records for t1 on the host
  find "$HOST_HOME/state/t1.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '
}

delivery_ids() {  # distinct delivery ids recorded in the host inbox
  cat "$HOST_HOME/state/t1.inbox/"*.msg 2>/dev/null | sed -n 's/^\[remote-worker delivery: \(.*\)\]$/\1/p' | sort -u
}

test_steer_writes_one_host_record() {
  local out rc=0
  make_case steer
  out=$(primary bash "$ROOT/bin/fm-send.sh" t1 $'continue with\nthe second step' 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a steer to a placed worker failed (rc=$rc): $out"
  assert_equals 1 "$(host_records)" "the steer did not land as exactly one host inbox record"
  assert_contains "$(cat "$HOST_HOME/state/t1.inbox/"*.msg)" $'continue with\nthe second step' \
    "the host record lost the multiline steer"
  assert_equals 1 "$(delivery_ids | wc -l | tr -d ' ')" "the host record carries no supervisor delivery id"
  delivery_ids | grep -Eq '^[a-f0-9]{16}$' || fail "the delivery id is not 16 hex characters: $(delivery_ids)"
  assert_contains "$(cat "$CASE/ssh.log")" "argv:fm-remote-worker-control.sh send-stdin t1 $(delivery_ids)" \
    "the steer did not cross the host leg's send-stdin with its delivery id"
  assert_absent "$PARENT/state/t1.inbox" "the primary wrote a local inbox for a placed task"
  assert_absent "$CASE/backend.log" "the steer touched the primary's local backend"
  pass "a steer to a placed worker writes one host inbox record under a supervisor-minted delivery id"

  out=$(primary bash "$ROOT/bin/fm-send.sh" t1 $'continue with\nthe second step' 2>&1) || fail "a repeat steer failed: $out"
  assert_equals 2 "$(host_records)" "a new identical steer was swallowed instead of minting a new delivery id"
  pass "a plain rerun is a new steer with a new delivery id"

  rc=0
  out=$(primary bash "$ROOT/bin/fm-send.sh" t1 --key Escape 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a raw key was accepted for a placed worker"
  assert_contains "$out" "fm-control.sh t1 interrupt" "the key refusal did not point at the control plane"
  pass "a raw key to a placed worker is refused with the control-plane pointer"
}

test_lost_answer_retries_with_the_same_id() {
  local out rc=0
  make_case retry
  out=$(FM_FAKE_SSH_LOSE_ONCE="$CASE/lost" primary bash "$ROOT/bin/fm-send.sh" t1 'retry me' 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a steer whose first answer was lost did not recover (rc=$rc): $out"
  assert_equals 2 "$(grep -c '^argv:fm-remote-worker-control.sh send-stdin' "$CASE/ssh.log")" \
    "the lost answer was not retried exactly once"
  assert_equals 1 "$(grep '^argv:fm-remote-worker-control.sh send-stdin' "$CASE/ssh.log" | sort -u | wc -l | tr -d ' ')" \
    "the automatic retry did not reuse the same delivery id"
  assert_equals 1 "$(host_records)" "the automatic retry duplicated the host record"
  pass "an ssh 255 after the host wrote the record retries once with the same delivery id and lands once"
}

test_unconfirmed_resend_reuses_the_id() {
  local out rc=0 resend id
  make_case resend
  printf '%s\n' 'needs-decision [at=1700000000] [key=k1]: pick the layout' > "$PARENT/state/t1.status"
  out=$(FM_FAKE_SSH_LOSE_RESULT=1 primary bash "$ROOT/bin/fm-send.sh" t1 --resolve-key k1 'use layout B' 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "an unconfirmed steer did not exit 3 (rc=$rc): $out"
  assert_contains "$out" "unconfirmed" "the unconfirmed steer did not say so"
  assert_equals 1 "$(host_records)" "the host did not hold the record whose answer was lost"
  assert_not_contains "$(cat "$PARENT/state/t1.status")" "resolved" "an unconfirmed answer closed the decision"
  id=$(delivery_ids)
  resend=$(printf '%s\n' "$out" | grep "FM_SEND_PLACED_DELIVERY_ID=$id ") \
    || fail "the printed resend does not carry the same delivery id $id: $out"
  assert_contains "$resend" "--resolve-key k1" "the printed resend dropped the decision key"
  pass "an unconfirmed steer exits 3 and prints a resend that reuses its delivery id"

  out=$(FM_SSH_BIN="$CASE/fake-ssh" PATH="$PRIMARY_BIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" bash -c "$resend" 2>&1) \
    || fail "the printed resend failed: $out"
  assert_equals 1 "$(host_records)" "the resend with the same delivery id duplicated the host record"
  assert_contains "$(cat "$PARENT/state/t1.status")" "resolved [key=k1]" \
    "the confirmed resend did not close the decision on the primary"
  pass "the resend lands on the same host record and closes the decision on the supervisor"

  rc=0
  out=$(FM_SEND_PLACED_DELIVERY_ID=not-hex primary bash "$ROOT/bin/fm-send.sh" t1 'x' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed reused delivery id was accepted"
  assert_contains "$out" "16 lowercase hex" "the malformed id was not named"
  pass "a malformed reused delivery id is refused before anything is sent"
}

test_state_relays_host_and_unknown_remote() {
  local out
  make_case state
  out=$(primary bash "$ROOT/bin/fm-crew-state.sh" t1 2>&1) || fail "crew-state failed: $out"
  case "$out" in
    'state: '*' · source: '*' · on worker host mbp'*) ;;
    *) fail "crew-state did not relay the host's reading: $out" ;;
  esac
  assert_contains "$(cat "$CASE/ssh.log")" "argv:fm-remote-worker-control.sh state t1" "crew-state did not ask the host"
  assert_not_contains "$out" "unknown-remote" "a reachable host read as unknown-remote"
  pass "crew-state relays the host's own one-line reading for a placed worker"

  out=$(FM_FAKE_SSH_DOWN=1 primary bash "$ROOT/bin/fm-crew-state.sh" t1 2>&1) || fail "crew-state failed: $out"
  assert_contains "$out" "state: unknown · source: worker-host · unknown-remote: worker host mbp" \
    "an ssh exit 255 did not read unknown-remote"
  assert_not_contains "$out" "dead" "an unreachable host read as dead"
  assert_not_contains "$out" "worktree gone" "an unreachable host fell back to a local reading"
  rm -f "$HOST_HOME/state/t1.remote-worker"
  out=$(primary bash "$ROOT/bin/fm-crew-state.sh" t1 2>&1) || fail "crew-state failed: $out"
  assert_contains "$out" "state: unknown · source: worker-host · unknown-remote: worker host mbp could not read" \
    "a host refusal did not read unknown-remote"
  assert_absent "$CASE/backend.log" "crew-state touched the primary's local backend"
  pass "an ssh exit 255 or host refusal reads unknown-remote, never dead or local"
}

test_peek_reads_the_host_pane() {
  local out rc=0 target
  make_case peek
  for target in t1 fm-t1; do
    out=$(primary bash "$ROOT/bin/fm-peek.sh" "$target" 500 2>"$CASE/peek.err") \
      || fail "peek via $target failed: $(cat "$CASE/peek.err")"
    assert_equals 'placed worker output' "$out" "peek via $target did not return the host pane"
  done
  assert_contains "$(cat "$CASE/ssh.log")" "argv:fm-remote-worker-control.sh capture t1 100" \
    "peek did not clamp its line count to the host cap"
  out=$(FM_FAKE_SSH_DOWN=1 primary bash "$ROOT/bin/fm-peek.sh" t1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "peek hid an unreachable host"
  assert_contains "$out" "worker host mbp" "the peek failure did not name the host"
  assert_contains "$out" "not thereby dead" "the peek failure claimed the worker dead"
  assert_absent "$CASE/backend.log" "peek touched the primary's local backend"
  pass "peek reads the host pane through the host leg and names an unreachable host"
}

test_control_and_answer_route_to_the_host() {
  local out rc verb
  make_case control
  for verb in interrupt exit; do
    rc=0
    out=$(primary bash "$ROOT/bin/fm-control.sh" t1 "$verb" 2>&1) || rc=$?
    assert_contains "$(cat "$CASE/ssh.log")" "argv:fm-remote-worker-control.sh control t1 $verb" \
      "control $verb did not reach the host leg"
    rc=0
    out=$(FM_FAKE_SSH_DOWN=1 primary bash "$ROOT/bin/fm-control.sh" t1 "$verb" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "control $verb claimed success over an unreachable host"
    assert_contains "$out" "is unknown" "control $verb did not report unknown completion on ssh 255"
  done
  : > "$CASE/ssh.log"
  rc=0
  out=$(primary bash "$ROOT/bin/fm-control.sh" t1 relaunch --note 'resume' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "relaunch was accepted for a placed worker"
  assert_contains "$out" "only interrupt and exit" "the relaunch refusal did not say why"
  [ ! -s "$CASE/ssh.log" ] || fail "a refused relaunch still reached the host"
  pass "interrupt and exit run on the host leg, ssh 255 is unknown, and relaunch is refused locally"

  rc=0
  out=$(primary bash "$ROOT/bin/fm-t3-answer.sh" t1 2>&1) || rc=$?
  assert_contains "$(cat "$CASE/ssh.log")" "argv:fm-remote-worker-control.sh answer t1" "a pending-request read did not reach the host"
  [ "$rc" -ne 0 ] || fail "a tmux worker's pending requests were reported"
  assert_contains "$out" "only T3 Code threads" "the host's own refusal did not pass through"
  : > "$CASE/ssh.log"
  rc=0
  out=$(primary bash "$ROOT/bin/fm-t3-answer.sh" t1 req-1 '{"q1":"yes"}' 2>&1) || rc=$?
  assert_contains "$(cat "$CASE/ssh.log")" 'argv:fm-remote-worker-control.sh answer t1 req-1 {"q1":"yes"}' \
    "an answer did not carry its request id and JSON to the host"
  rc=0
  out=$(FM_FAKE_SSH_DOWN=1 primary bash "$ROOT/bin/fm-t3-answer.sh" t1 req-1 '{"q1":"yes"}' 2>&1) || rc=$?
  [ "$rc" -eq 255 ] || fail "an answer over a lost transport did not exit 255 (rc=$rc): $out"
  assert_contains "$out" "is unknown" "an unconfirmed answer did not say its completion is unknown"
  assert_absent "$CASE/backend.log" "control or answer touched the primary's local backend"
  pass "pending-request reads and answers run on the host leg and report a lost answer as unknown"
}

fm_test_run test_steer_writes_one_host_record test_lost_answer_retries_with_the_same_id \
  test_unconfirmed_resend_reuses_the_id test_state_relays_host_and_unknown_remote \
  test_peek_reads_the_host_pane test_control_and_answer_route_to_the_host
