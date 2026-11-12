#!/usr/bin/env bash
# tests/fm-handoff-host.test.sh - bin/fm-handoff.sh --to <host> moves a ship or
# scout between the supervisor and its worker hosts (docs/remote-workers.md).
# The supervisor runs the real fm-handoff, fm-spawn (local and --host),
# fm-teardown (local and two-leg), fm-send, fm-rescue, and fm-on; a fake ssh
# decodes fm-on's argv stream and runs the named command in one of two fake
# worker-host homes with the real host leg (fm-remote-worker-control.sh) and
# that home's own scripts underneath, as tests/fm-teardown-host.test.sh does.
# A second fake ssh, set as GIT_SSH_COMMAND, serves git's SSH transport for the
# rescue repository's <dest>:<path> URL by running git's own pack command
# locally, so a host's push to the supervisor's rescue repository takes the
# same path it takes across two machines. A "worker" is simulated by committing
# in its copy, writing notes in its own home, pushing, and appending the ready
# line; the supervisor's mirrored status is appended directly.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the hand-off backlog transitions need it)\n'
  exit 0
}

unset TASKS_AXI_BACKEND FM_TASK_INBOX FM_GH_ACCOUNT || :

TMP_ROOT=$(fm_test_tmproot fm-handoff-host)
HANDOFF="$ROOT/bin/fm-handoff.sh"
GIT_ID=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
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
    name=; previous=
    for arg in "$@"; do [ "$previous" = -n ] && name=$arg; previous=$arg; done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
  kill-window)
    target=; previous=
    for arg in "$@"; do [ "$previous" = -t ] && target=$arg; previous=$arg; done
    target=${target##*:}; target=${target#=}
    grep -Fvx -- "$target" "$window_file" 2>/dev/null > "$window_file.tmp" || true
    mv "$window_file.tmp" "$window_file"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes gh gh-axi
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# A worker host home <name> with a clone of the shared origin and one pooled copy.
make_host_home() {  # <name>
  local home=$CASE/$1
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/user-home"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  : > "$home/.fm-worker-host"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  git clone --quiet "$CASE/origin.git" "$home/projects/sample"
  git -C "$home/projects/sample" worktree add --quiet --detach "$CASE/wt-$1" HEAD
  make_fakebin "$CASE/tools-$1" >/dev/null
}

# Sets CASE PARENT MBP M1 for one supervisor home and two worker host homes,
# mbp (alias remote-mac) and m1 (alias other-mac), sharing one origin.
make_case() {  # <name>
  CASE="$TMP_ROOT/$1"
  PARENT="$CASE/parent"
  MBP="$CASE/mbp"
  M1="$CASE/m1"
  mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$CASE/claims" "$CASE/user-home"
  printf '%s\n' "$$" > "$PARENT/state/.lock"
  touch "$PARENT/state/.last-watcher-beat"
  printf 'claude\n' > "$PARENT/config/crew-harness"
  printf 'supervisor\n' > "$PARENT/config/rescue-ssh"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$PARENT/data/backlog.md"
  fm_test_tasks_toml "$PARENT/.tasks.toml"
  cat > "$PARENT/data/worker-hosts.md" <<EOF
# Worker hosts

- mbp - spare MacBook worker host (host: remote-mac; root: $ROOT; home: $MBP; added 2026-11-10)
- m1 - always-on worker host (host: other-mac; root: $ROOT; home: $M1; added 2026-11-10)
EOF
  fm_git_init_commit "$CASE/seed"
  fm_git_add_origin "$CASE/seed" "$CASE/origin.git"
  git clone --quiet "$CASE/origin.git" "$PARENT/projects/sample"
  git -C "$PARENT/projects/sample" worktree add --quiet --detach "$CASE/wt-local" HEAD
  make_fakebin "$CASE/tools-local" >/dev/null
  make_host_home mbp
  make_host_home m1
  fm_test_track_procevent_home "$PARENT" "$CASE/claims"

  # fm-on's transport: run the decoded command in the named home, with that
  # home's tools and pooled copy. FM_FAKE_SSH_DOWN=1 never reaches a host.
  cat > "$CASE/fake-ssh" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "\${FM_FAKE_SSH_DOWN:-}" != 1 ] || exit 255
case "\$1" in remote-mac) name=mbp ;; other-mac) name=m1 ;; *) exit 91 ;; esac
[ "\$2" = fm-remote-entrypoint.sh ] || exit 92
decode() { printf '%s' "\$1" | base64 --decode 2>/dev/null || printf '%s' "\$1" | base64 -D; }
root=\$(decode "\$4")
home=\$(decode "\$5")
argv=()
while IFS= read -r -d '' arg; do argv+=("\$arg"); done < <(decode "\$6")
exec env -u FM_SUPERVISION_ACTOR -u FM_TRACE_CONTEXT -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \\
  -u FM_PROJECTS_OVERRIDE -u FM_PROCEVENT_CLAIM_ROOT FM_ROOT_OVERRIDE='' FM_HOME="\$home" \\
  HOME="$CASE/\$name/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 FM_GH_ACCOUNT=none \\
  FM_FAKE_PANE_PATH="$CASE/wt-\$name" TMUX="fake,1,0" PATH="$CASE/tools-\$name/fakebin:\$PATH" \\
  "\$root/bin/\${argv[0]}" "\${argv[@]:1}"
SH
  chmod +x "$CASE/fake-ssh"
  # git's SSH transport to the supervisor: run git's pack command locally.
  cat > "$CASE/git-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o|-p) shift 2 ;; -*) shift ;; *) break ;; esac
done
[ "$1" = supervisor ] || { echo "fake git ssh: unknown destination $1" >&2; exit 255; }
shift
exec sh -c "$*"
SH
  chmod +x "$CASE/git-ssh"
}

primary() {  # <command...>: run one real script in the supervisor home
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" HOME="$CASE/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_GH_ACCOUNT=none FM_PROCEVENT_CLAIM_ROOT="$CASE/claims" FM_SSH_BIN="$CASE/fake-ssh" \
    GIT_SSH_COMMAND="$CASE/git-ssh" FM_FAKE_PANE_PATH="$CASE/wt-local" TMUX="fake,1,0" \
    TASKS_AXI_BACKEND=markdown PATH="$CASE/tools-local/fakebin:$PATH" "$@" 2>&1
}

make_brief() {  # <id> <brief-args...>
  local id=$1 brief
  shift
  primary "$ROOT/bin/fm-brief.sh" "$id" sample "$@" >/dev/null || fail "fm-brief.sh failed for $id"
  brief="$PARENT/data/$id/brief.md"
  perl -0pi -e "s/\\{TASK\\}/Ship the moved sample change for $id./; s/\\{FIRSTMATE_SPEC\\}/Edit widget.txt only./" "$brief"
}

row_field() {  # <id> <field>
  tasks-axi show "$1" --file "$PARENT/data/backlog.md" --full 2>/dev/null | sed -n "s/^  $2: *//p" | head -n 1
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Start <id> here (local) or on worker host <host>, as firstmate would have.
start_task() {  # <id> <ship|scout> <local|mbp|m1>
  local id=$1 kind=$2 where=$3 out
  if [ "$kind" = ship ]; then make_brief "$id" --mode direct-PR; else make_brief "$id" --scout; fi
  tasks-axi add "$id" "moved work" --kind "$kind" --repo sample --file "$PARENT/data/backlog.md" >/dev/null ||
    fail "could not add backlog item $id"
  local -a args=("$id")
  if [ "$where" = local ]; then args+=("$PARENT/projects/sample"); else args+=(sample --host "$where" --harness claude); fi
  if [ "$kind" = ship ]; then args+=(--mode direct-PR --yolo off); else args+=(--scout); fi
  out=$(primary "$ROOT/bin/fm-spawn.sh" "${args[@]}") || fail "could not start $id on $where: $out"
}

# The worker's side of a ship's steer, in the copy where it runs: commit,
# notes in its own home, push to <remote>, ready line. Prints the head.
worker_ships_ready() {  # <id> <local|mbp|m1> <remote>
  local id=$1 where=$2 remote=$3 wt=$CASE/wt-$2 home=$PARENT head
  [ "$where" = local ] || home=$CASE/$where
  git -C "$wt" checkout --quiet -b "fm/$id"
  printf 'first half\n' > "$wt/widget.txt"
  git -C "$wt" add widget.txt
  git -C "$wt" "${GIT_ID[@]}" commit -qm 'first half of the widget'
  printf 'scratch\n' > "$wt/untracked-wip.txt"
  git -C "$wt" add -A
  git -C "$wt" "${GIT_ID[@]}" commit -qm 'wip: hand-off'
  mkdir -p "$home/data/$id"
  printf 'Done: first half. Left: second half.\n' > "$home/data/$id/handoff-notes.md"
  GIT_SSH_COMMAND="$CASE/git-ssh" git -C "$wt" push --quiet "$remote" "fm/$id" ||
    fail "the simulated worker could not push to $remote"
  head=$(git -C "$wt" rev-parse HEAD)
  ready_line "$id" "$where" "handoff ready fm/$id $head"
  printf '%s\n' "$head"
}

# Append the ready line where the worker writes it, and to the supervisor's
# mirrored status for a placed task.
ready_line() {  # <id> <local|mbp|m1> <note>
  local line
  line="paused [at=$(date +%s)]: $3"
  printf '%s\n' "$line" >> "$PARENT/state/$1.status"
  [ "$2" = local ] || printf '%s\n' "$line" >> "$CASE/$2/state/$1.status"
}

newest_msg() {  # <inbox-dir>
  find "$1" -maxdepth 1 -name '*.msg' 2>/dev/null | sort -V | tail -n 1
}

test_local_ship_moves_to_a_host() {
  local out head new=lh1-c2 msg
  make_case local-to-host
  start_task lh1 ship local

  out=$(primary "$HANDOFF" lh1 --to mbp --remote fm-rescue --reason "free the laptop")
  expect_code 0 $? "the request to a worker host should succeed"$'\n'"$out"
  msg=$(newest_msg "$PARENT/state/lh1.inbox")
  assert_grep "another machine (worker host mbp)" "$msg" "the steer does not say the work moves to the host"
  assert_grep "push fm-rescue fm/lh1" "$msg" "the steer does not ask for the rescue push"
  assert_grep "$PARENT/data/lh1/handoff-notes.md" "$msg" "a local worker is not told to write notes in this home"

  head=$(worker_ships_ready lh1 local fm-rescue)
  out=$(primary "$HANDOFF" lh1 --to mbp --remote fm-rescue --harness claude)
  expect_code 0 $? "the hand-off to mbp should finish"$'\n'"$out"
  assert_contains "$out" "handed-off: lh1 -> $new on mbp" "the hand-off was not reported"
  assert_absent "$PARENT/state/lh1.meta" "the old local task was not cleaned up"
  assert_equals "done" "$(row_field lh1 state)" "the old backlog item is not closed"
  tasks-axi show lh1 --full --file "$PARENT/data/backlog.md" | grep -F "continued as $new on mbp" >/dev/null ||
    fail "the old item does not say it continued on mbp"
  assert_equals in_flight "$(row_field "$new" state)" "the continuation's item is not in flight"
  assert_equals mbp "$(meta_value "$PARENT/state/$new.meta" remote_worker_host)" "the continuation is not placed on mbp"
  assert_equals lh1 "$(meta_value "$PARENT/state/$new.meta" continued_from)" "the supervisor's record lost continued_from"
  assert_grep 'to=mbp' "$PARENT/data/$new/continuation" "the supervisor's continuation record does not name mbp"
  assert_equals "$head" "$(git -C "$CASE/wt-mbp" rev-parse HEAD)" "the host's copy is not at the carried commit"
  assert_present "$CASE/wt-mbp/untracked-wip.txt" "the work-in-progress commit did not reach the host"
  assert_equals "supervisor:$CASE/user-home/fm-rescue/sample.git" \
    "$(git -C "$MBP/projects/sample" remote get-url fm-rescue)" "the host's clone does not reach the rescue repository over SSH"
  assert_grep 'to=local' "$MBP/data/$new/continuation" "the host's own record does not say the continuation runs there"
  assert_grep 'Continued from: lh1' "$MBP/data/$new/brief.md" "the host's brief does not name the old task"
  assert_grep 'Ship the moved sample change for lh1.' "$MBP/data/$new/brief.md" "the host's brief lost the intent"
  assert_grep "$MBP/data/$new/handoff.md" "$MBP/data/$new/brief.md" "the host's brief does not point at its own handoff copy"
  assert_grep 'which ran on the supervisor and now continues on worker host mbp' "$MBP/data/$new/handoff.md" \
    "the staged handoff does not say the work moved"
  assert_grep 'Done: first half. Left: second half.' "$MBP/data/$new/handoff.md" "the staged handoff lost the notes"
  pass "a local ship moves to a worker host through the rescue repository and keeps one live item"
}

test_placed_ship_moves_back_to_the_supervisor() {
  local out head new=hl1-c2 msg
  make_case host-to-local
  start_task hl1 ship mbp

  out=$(primary "$HANDOFF" hl1 --to local --remote fm-rescue)
  expect_code 0 $? "the request back to the supervisor should succeed"$'\n'"$out"
  assert_equals "supervisor:$CASE/user-home/fm-rescue/sample.git" \
    "$(git -C "$CASE/wt-mbp" remote get-url fm-rescue)" "the placed copy was not given the rescue remote"
  msg=$(newest_msg "$MBP/state/hl1.inbox")
  [ -n "$msg" ] || fail "the placed worker was not steered through its host"
  assert_grep "$MBP/data/hl1/handoff-notes.md" "$msg" "a placed worker is not told to write notes in its own home"
  assert_grep "push fm-rescue fm/hl1" "$msg" "the steer does not ask for the rescue push"

  out=$(primary "$HANDOFF" hl1 --to local --remote fm-rescue)
  expect_code 75 $? "a silent worker must leave the hand-off waiting"
  assert_present "$PARENT/state/hl1.meta" "waiting changed the old task"

  head=$(worker_ships_ready hl1 mbp fm-rescue)
  out=$(primary "$HANDOFF" hl1 --to local --remote fm-rescue --harness claude)
  expect_code 0 $? "the hand-off back should finish"$'\n'"$out"
  assert_contains "$out" "handed-off: hl1 -> $new on local" "the hand-off was not reported"
  assert_equals 'Done: first half. Left: second half.' "$(cat "$PARENT/data/hl1/handoff-notes.md")" \
    "the host's notes were not fetched"
  assert_absent "$MBP/state/hl1.meta" "the host leg of cleanup did not run"
  assert_absent "$PARENT/state/hl1.meta" "the supervisor leg of cleanup did not run"
  assert_equals "done" "$(row_field hl1 state)" "the old backlog item is not closed"
  assert_equals in_flight "$(row_field "$new" state)" "the continuation's item is not in flight"
  assert_equals "" "$(meta_value "$PARENT/state/$new.meta" remote_worker_host)" "the continuation was placed instead of run here"
  assert_equals "$head" "$(git -C "$CASE/wt-local" rev-parse HEAD)" "the local copy is not at the carried commit"
  assert_equals "$CASE/user-home/fm-rescue/sample.git" "$(git -C "$PARENT/projects/sample" remote get-url fm-rescue)" \
    "the supervisor's clone was not given the rescue remote"
  assert_grep 'which ran on worker host mbp and now continues on the supervisor' "$PARENT/data/$new/handoff.md" \
    "the handoff composed on the host does not say the work moved"
  assert_grep 'Done: first half. Left: second half.' "$PARENT/data/$new/handoff.md" "the handoff lost the notes"
  assert_grep 'Ship the moved sample change for hl1.' "$PARENT/data/$new/brief.md" "the continuation brief lost the intent"
  pass "a placed ship moves back to the supervisor: notes fetched, work verified on the host, two-leg cleanup"
}

test_placed_ship_moves_to_another_host() {
  local out head new=hh1-c2
  make_case host-to-host
  start_task hh1 ship mbp
  out=$(primary "$HANDOFF" hh1 --to m1 --remote origin)
  expect_code 0 $? "the request to another host should succeed"$'\n'"$out"
  head=$(worker_ships_ready hh1 mbp origin)

  git -C "$CASE/wt-mbp" "${GIT_ID[@]}" commit -q --allow-empty -m 'after the ready line'
  out=$(primary "$HANDOFF" hh1 --to m1 --remote origin --harness claude)
  expect_code 1 $? "work the host leg cannot verify must stop the hand-off"
  assert_contains "$out" "not the reported $head" "the moved branch was not named"
  assert_present "$PARENT/state/hh1.meta" "a refused verification cleaned up the old task"
  git -C "$CASE/wt-mbp" reset --quiet --hard "$head"

  out=$(primary "$HANDOFF" hh1 --to local --remote origin)
  expect_code 1 $? "a finish must name the requested target"
  assert_contains "$out" "requested to m1" "the target mismatch was not named"

  out=$(primary "$HANDOFF" hh1 --to m1 --remote origin --harness claude)
  expect_code 0 $? "the hand-off to m1 should finish"$'\n'"$out"
  assert_contains "$out" "handed-off: hh1 -> $new on m1" "the hand-off was not reported"
  assert_absent "$MBP/state/hh1.meta" "mbp did not clean up the old task"
  assert_equals m1 "$(meta_value "$PARENT/state/$new.meta" remote_worker_host)" "the continuation is not placed on m1"
  assert_equals "$head" "$(git -C "$CASE/wt-m1" rev-parse HEAD)" "m1's copy is not at the carried commit"
  assert_grep 'which ran on worker host mbp and now continues on worker host m1' "$M1/data/$new/handoff.md" \
    "m1's handoff does not say the work moved"
  pass "a placed ship moves between two worker hosts through origin"
}

test_local_scout_moves_to_a_host() {
  local out new=ls1-c2
  make_case scout
  start_task ls1 scout local
  out=$(primary "$HANDOFF" ls1 --to m1 --remote origin)
  expect_code 0 $? "the scout request should succeed"$'\n'"$out"
  printf '# Interim\nFindings so far.\n' > "$PARENT/data/ls1/report.md"
  printf 'Left: check the second source.\n' > "$PARENT/data/ls1/handoff-notes.md"
  out=$(primary "$ROOT/bin/fm-captain-hold.sh" complete ls1 --none) || fail "fixture: the completion gate failed: $out"
  ready_line ls1 local "handoff ready"
  out=$(primary "$HANDOFF" ls1 --to m1 --remote origin --harness claude)
  expect_code 0 $? "the scout hand-off should finish"$'\n'"$out"
  assert_equals scout "$(meta_value "$PARENT/state/$new.meta" kind)" "the continuation is not a scout"
  assert_equals m1 "$(meta_value "$PARENT/state/$new.meta" remote_worker_host)" "the scout is not placed on m1"
  assert_equals "$(cat "$PARENT/data/ls1/report.md")" "$(cat "$M1/data/ls1/report.md" 2>/dev/null)" \
    "the interim report was not carried to m1"
  assert_grep "$M1/data/ls1/report.md" "$M1/data/$new/brief.md" "m1's brief does not point at the carried report"
  pass "a scout moves to a worker host with its interim report"
}

test_refusals_change_nothing() {
  local out msgs
  make_case refuse
  start_task rf1 ship local

  out=$(primary "$HANDOFF" rf1 --to nowhere --remote origin)
  expect_code 1 $? "an unregistered target must be refused"
  assert_contains "$out" "no worker host 'nowhere' is registered" "the unregistered target was not named"

  out=$(FM_FAKE_SSH_DOWN=1 primary "$HANDOFF" rf1 --to mbp --remote origin)
  expect_code 1 $? "an unreachable target must be refused"
  assert_contains "$out" "unreachable" "the unreachable target was not named"

  printf '1\n' > "$MBP/config/lane-capacity"
  printf 'kind=ship\n' > "$MBP/state/busy.meta"
  out=$(primary "$HANDOFF" rf1 --to mbp --remote origin)
  expect_code 75 $? "a target that does not admit the task must defer"
  assert_contains "$out" "does not admit" "the admission refusal was not named"
  rm -f "$MBP/config/lane-capacity" "$MBP/state/busy.meta"

  rm -rf "$M1/projects/sample"
  out=$(primary "$HANDOFF" rf1 --to m1 --remote origin)
  expect_code 1 $? "a target without the project must be refused"
  assert_contains "$out" "not cloned" "the missing project was not named"

  out=$(primary "$HANDOFF" rf1 --to mbp --remote origin --account other)
  expect_code 1 $? "--account must not be sent to a worker host"
  assert_contains "$out" "--account is not forwarded" "the account refusal was not named"

  rm -f "$PARENT/config/rescue-ssh"
  out=$(primary "$HANDOFF" rf1 --to mbp --remote fm-rescue)
  expect_code 1 $? "fm-rescue cannot cross machines without config/rescue-ssh"
  assert_contains "$out" "config/rescue-ssh is not set" "the missing rescue destination was not named"

  assert_absent "$PARENT/data/rf1/handoff-request" "a refused hand-off left a request"
  msgs=$(find "$PARENT/state/rf1.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
  assert_equals 0 "$msgs" "a refused hand-off steered the worker"

  # A placed worker whose host cannot be reached is never asked to move.
  start_task rf2 ship mbp
  out=$(FM_FAKE_SSH_DOWN=1 primary "$HANDOFF" rf2 --to local --remote origin)
  expect_code 1 $? "a worker that cannot be steered must stop the hand-off"
  assert_contains "$out" "could not steer task rf2" "the failed steer was not named"
  assert_absent "$PARENT/data/rf2/handoff-request" "an unsteered hand-off left a request"
  pass "fm-handoff refuses an unregistered, unreachable, full, or ineligible target and an unreachable worker before changing anything"
}

test_spawn_host_continuation_requires_its_record() {
  local out head
  make_case spawn
  head=$(git -C "$CASE/seed" rev-parse HEAD)
  git -C "$CASE/seed" push --quiet origin "HEAD:refs/heads/fm/old-sp"
  make_brief old-sp --mode direct-PR
  bash -c '. "$1/bin/fm-continuation-lib.sh"; fm_continuation_write "$2" new-sp old-sp ship origin fm/old-sp "$3" local' \
    _ "$ROOT" "$PARENT/data" "$head" || fail "could not write the record"
  primary "$ROOT/bin/fm-brief.sh" new-sp sample --mode direct-PR --continue-from old-sp >/dev/null || fail "brief failed"
  printf 'handoff\n' > "$PARENT/data/new-sp/handoff.md"
  tasks-axi add new-sp "continuation" --kind ship --file "$PARENT/data/backlog.md" >/dev/null
  out=$(primary "$ROOT/bin/fm-spawn.sh" new-sp sample --host mbp --mode direct-PR --yolo off --harness claude --continue-from old-sp)
  expect_code 1 $? "a record for a local continuation must not be placed"
  assert_contains "$out" "continues on 'local', not worker host mbp" "the target mismatch was not named"
  out=$(primary "$ROOT/bin/fm-spawn.sh" new-sp sample --host mbp --mode direct-PR --yolo off --harness claude)
  expect_code 1 $? "a continuation brief must not be placed without --continue-from"
  assert_contains "$out" "has no --continue-from" "the missing flag was not named"
  assert_absent "$PARENT/state/new-sp.meta" "a refused placement left a record"
  assert_absent "$MBP/data/new-sp/handoff.md" "a refused placement staged on the host"
  pass "fm-spawn --host --continue-from requires a record that targets that host"
}

fm_test_run \
  test_local_ship_moves_to_a_host \
  test_placed_ship_moves_back_to_the_supervisor \
  test_placed_ship_moves_to_another_host \
  test_local_scout_moves_to_a_host \
  test_refusals_change_nothing \
  test_spawn_host_continuation_requires_its_record
