#!/usr/bin/env bash
# Behavior tests for continuing a task in a fresh thread on the same machine:
# bin/fm-handoff.sh --to local, bin/fm-brief.sh --continue-from, and
# bin/fm-spawn.sh --continue-from, with the continuation record
# bin/fm-continuation-lib.sh owns between them.
#
# The end-to-end cases drive the real spawn, steer, cleanup, and backlog paths
# against a real tasks-axi backlog, a real git origin, and a fake terminal; a
# "worker" is simulated by committing in the old copy, pushing, and appending
# the ready line the steer asks for.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

unset TASKS_AXI_BACKEND FM_TASK_INBOX FM_GH_ACCOUNT || :

HANDOFF="$ROOT/bin/fm-handoff.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff)
cd "$TMP_ROOT" || exit 1

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

GIT_ID=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')

# A home with a real backlog, a project with an origin, and two pooled copies:
# wt1 for the task being handed off and wt2 for its continuation.
make_case() {  # <name>
  local case_dir=$TMP_ROOT/$1 home fakebin
  home=$case_dir/home
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects" "$case_dir/user-home"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$home/.tasks.toml"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
window_file="$(dirname "$0")/.spawn-window"
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file"; exit 0 ;;
  new-window)
    name=; previous=
    for arg in "$@"; do [ "$previous" = -n ] && name=$arg; previous=$arg; done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    exit 0 ;;
  kill-window)
    target=; previous=
    for arg in "$@"; do [ "$previous" = -t ] && target=$arg; previous=$arg; done
    target=${target##*:}; target=${target#=}
    grep -Fvx -- "$target" "$window_file" 2>/dev/null > "$window_file.tmp" || true
    mv "$window_file.tmp" "$window_file"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes
  fm_test_fake_sleep_noop "$fakebin"
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/origin.git"
  git -C "$case_dir/project" fetch --quiet origin
  git -C "$case_dir/project" worktree add --quiet --detach "$case_dir/wt1" HEAD
  git -C "$case_dir/project" worktree add --quiet --detach "$case_dir/wt2" HEAD
  printf '%s\n' "$case_dir"
}

write_brief() {  # <case-dir> <id> <kind>
  local home=$1/home id=$2
  mkdir -p "$home/data/$id"
  {
    printf '%s\n' '# Task' "## Captain's intent" "Ship the widget for $id." 'Keep it small.' ''
    printf '%s\n' '## Firstmate spec' 'Touch only widget.txt.' ''
    if [ "$3" = ship ]; then
      printf '%s\n' '# Setup' 'You are in a disposable git worktree of project, at a detached HEAD on a clean default branch.' ''
      printf '%s\n' '# Definition of done' 'Delivery contract: mode=direct-PR'
    fi
  } > "$home/data/$id/brief.md"
}

in_case() {  # <case-dir> <pane-path> <command> [args...]
  local case_dir=$1 pane=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" HOME="$case_dir/user-home" \
    CLAUDE_CONFIG_DIR='' FM_GH_ACCOUNT=none FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$case_dir/fakebin:$PATH" "$@" 2>&1
}

backlog() {  # <case-dir> <tasks-axi args...>
  local case_dir=$1
  shift
  (cd "$case_dir/home" && tasks-axi "$@" --file data/backlog.md)
}

row_field() {  # <case-dir> <id> <field>
  backlog "$1" show "$2" 2>/dev/null | sed -n "s/^  $3: *//p" | head -n 1
}

# Spawn the task to be handed off into wt1, as firstmate would have.
start_task() {  # <case-dir> <id> <kind>
  local case_dir=$1 id=$2 kind=$3 out
  write_brief "$case_dir" "$id" "$kind"
  backlog "$case_dir" add "$id" "widget work" --kind "$kind" --repo project >/dev/null
  if [ "$kind" = ship ]; then
    out=$(in_case "$case_dir" "$case_dir/wt1" "$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --mode direct-PR --yolo off)
  else
    out=$(in_case "$case_dir" "$case_dir/wt1" "$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --scout)
  fi || fail "could not spawn the task to hand off"$'\n'"$out"
}

status_append() {  # <case-dir> <id> <line>
  printf '%s\n' "$3" >> "$1/home/state/$2.status"
}

# The worker's side of the steer for a ship: commit, notes, push, ready line.
worker_ships_ready() {  # <case-dir> <id> [push]
  local case_dir=$1 id=$2 wt=$1/wt1 head
  git -C "$wt" checkout --quiet -b "fm/$id"
  printf 'first half\n' > "$wt/widget.txt"
  git -C "$wt" add widget.txt
  git -C "$wt" "${GIT_ID[@]}" commit -qm 'first half of the widget'
  printf 'scratch\n' > "$wt/untracked-wip.txt"
  git -C "$wt" add -A
  git -C "$wt" "${GIT_ID[@]}" commit -qm 'wip: hand-off'
  printf 'Done: first half. Left: second half.\n' > "$case_dir/home/data/$id/handoff-notes.md"
  [ "${3:-push}" != push ] || git -C "$wt" push --quiet origin "fm/$id"
  head=$(git -C "$wt" rev-parse HEAD)
  status_append "$case_dir" "$id" "paused [at=$(date +%s)]: handoff ready fm/$id $head"
  printf '%s\n' "$head"
}

test_brief_continue_from_copies_the_task_and_records_the_source() {
  local case_dir home out brief head
  case_dir=$TMP_ROOT/brief
  home=$case_dir/home
  mkdir -p "$home/data" "$home/state" "$home/config"
  write_brief "$case_dir" old-b1 ship
  head=0123456789abcdef0123456789abcdef01234567

  out=$(FM_HOME="$home" "$BRIEF" new-b1 project --mode no-mistakes --continue-from old-b1 2>&1)
  [ $? -ne 0 ] || fail "a continuation brief scaffolded without a continuation record"
  assert_contains "$out" "no continuation record" "the missing record was not named"

  out=$(FM_HOME="$home" bash -c '. "$1/bin/fm-continuation-lib.sh"; fm_continuation_write "$2" new-b1 old-b1 ship origin fm/old-b1 "$3" || { echo "$FM_CONT_ERROR"; exit 1; }' _ "$ROOT" "$home/data" "$head") ||
    fail "could not write a continuation record: $out"
  out=$(FM_HOME="$home" "$BRIEF" new-b1 project --scout --continue-from old-b1 2>&1)
  [ $? -ne 0 ] || fail "a scout brief accepted a ship continuation record"
  assert_contains "$out" "is for a ship" "the kind mismatch was not named"

  out=$(FM_HOME="$home" "$BRIEF" new-b1 project --mode no-mistakes --base-branch release --continue-from old-b1 2>&1) ||
    fail "the continuation brief did not scaffold: $out"
  brief=$home/data/new-b1/brief.md
  [ "$(bash -c '. "$1/bin/fm-brief-heading-lib.sh"; fm_brief_task_heading_body "$2" "## Captain'"'"'s intent"' _ "$ROOT" "$brief")" = \
    "$(bash -c '. "$1/bin/fm-brief-heading-lib.sh"; fm_brief_task_heading_body "$2" "## Captain'"'"'s intent"' _ "$ROOT" "$home/data/old-b1/brief.md")" ] ||
    fail "the captain's intent was not carried over verbatim"
  assert_grep 'Touch only widget.txt.' "$brief" "the firstmate spec was not carried over"
  assert_no_grep '{TASK}' "$brief" "the continuation brief left a placeholder"
  assert_grep 'Continued from: old-b1' "$brief" "Setup does not record the source task"
  assert_grep "at commit \`$head\`" "$brief" "Setup does not name the carried commit"
  assert_grep "$home/data/new-b1/handoff.md" "$brief" "the brief does not point at the handoff document"
  assert_grep 'git checkout -b fm/new-b1 --' "$brief" "the continuation does not create its own branch"
  [ "$(bash -c '. "$1/bin/fm-dod-lib.sh"; fm_brief_base_branches "$2"' _ "$ROOT" "$brief")" = release ] ||
    fail "the base branch line is not read after the continuation Setup sentence"
  [ "$(bash -c '. "$1/bin/fm-continuation-lib.sh"; fm_brief_continued_from "$2"' _ "$ROOT" "$brief")" = old-b1 ] ||
    fail "fm_brief_continued_from did not read the source task"
  pass "fm-brief --continue-from carries the Task verbatim and records the source and carried commit"
}

test_spawn_continue_from_starts_at_the_carried_commit() {
  local case_dir home out head id=new-s1 status
  case_dir=$(make_case spawn)
  home=$case_dir/home
  git -C "$case_dir/wt1" checkout --quiet -b fm/old-s1
  printf 'carried\n' > "$case_dir/wt1/widget.txt"
  git -C "$case_dir/wt1" add widget.txt
  git -C "$case_dir/wt1" "${GIT_ID[@]}" commit -qm carried
  git -C "$case_dir/wt1" push --quiet origin fm/old-s1
  head=$(git -C "$case_dir/wt1" rev-parse HEAD)
  write_brief "$case_dir" old-s1 ship
  bash -c '. "$1/bin/fm-continuation-lib.sh"; fm_continuation_write "$2" new-s1 old-s1 ship origin fm/old-s1 "$3"' _ "$ROOT" "$home/data" "$head" ||
    fail "could not write the continuation record"
  FM_HOME="$home" "$BRIEF" "$id" project --mode direct-PR --continue-from old-s1 >/dev/null || fail "could not scaffold the continuation brief"
  [ "$HAVE_TASKS_AXI" -eq 0 ] || backlog "$case_dir" add "$id" "continuation" --kind ship >/dev/null

  out=$(in_case "$case_dir" "$case_dir/wt2" "$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a continuation brief spawned without --continue-from"
  assert_contains "$out" "has no --continue-from" "the missing flag was not named"

  out=$(in_case "$case_dir" "$case_dir/wt2" "$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --mode direct-PR --yolo off --continue-from old-s1 --host m1)
  [ $? -ne 0 ] || fail "--continue-from was accepted with --host"

  git -C "$case_dir/project" "${GIT_ID[@]}" commit -q --allow-empty -m moved
  git -C "$case_dir/project" push --quiet origin HEAD:refs/heads/fm/old-s1 --force
  out=$(in_case "$case_dir" "$case_dir/wt2" "$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --mode direct-PR --yolo off --continue-from old-s1)
  [ $? -ne 0 ] || fail "spawn continued from a carried branch that no longer points at the carried commit"
  assert_contains "$out" "not the carried commit" "the moved branch was not named"
  [ ! -e "$home/state/$id.meta" ] || fail "a refused continuation published a task record"

  git -C "$case_dir/wt1" push --quiet --force origin fm/old-s1
  # The refused launch above left its terminal window behind, as any refused
  # copy preparation does; close it so the retry is a fresh spawn.
  : > "$case_dir/fakebin/.spawn-window"
  out=$(in_case "$case_dir" "$case_dir/wt2" "$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --mode direct-PR --yolo off --continue-from old-s1)
  expect_code 0 $? "the continuation should spawn from the carried commit"$'\n'"$out"
  [ "$(git -C "$case_dir/wt2" rev-parse HEAD)" = "$head" ] || fail "the continuation copy is not at the carried commit"
  [ "$(cat "$case_dir/wt2/widget.txt")" = carried ] || fail "the continuation copy does not hold the carried work"
  assert_grep 'continued_from=old-s1' "$home/state/$id.meta" "the task record does not name the continued task"
  pass "fm-spawn --continue-from plants the copy at the carried commit and refuses a moved branch"
}

test_handoff_refuses_what_it_cannot_carry() {
  local case_dir home out
  [ "$HAVE_TASKS_AXI" -eq 1 ] || { pass "skipped: tasks-axi is not installed"; return; }
  case_dir=$(make_case refuse)
  home=$case_dir/home
  start_task "$case_dir" old-r1 ship

  out=$(in_case "$case_dir" "$case_dir/wt1" "$HANDOFF" old-r1 --to m1)
  expect_code 2 $? "a cross-machine target should be a usage refusal"
  assert_contains "$out" "only a local hand-off exists" "the cross-machine refusal was not explained"

  status_append "$case_dir" old-r1 "needs-decision [at=$(date +%s)] [key=pick]: which colour"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$HANDOFF" old-r1 --to local)
  [ $? -eq 1 ] || fail "a task with an open decision was handed off"
  assert_contains "$out" "open decision" "the open decision was not named"
  status_append "$case_dir" old-r1 "resolved [at=$(date +%s)] [key=pick]: blue"

  printf 'pr=https://github.com/o/r/pull/7\n' >> "$home/state/old-r1.meta"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$HANDOFF" old-r1 --to local)
  [ $? -eq 1 ] || fail "a task with a pull request was handed off"
  assert_contains "$out" "already has a pull request" "the recorded PR was not named"
  sed -i.bak '/^pr=/d' "$home/state/old-r1.meta"

  out=$(in_case "$case_dir" "$case_dir/wt1" "$HANDOFF" old-r1 --to local --remote nowhere)
  [ $? -eq 1 ] || fail "a hand-off through a missing remote was requested"
  assert_contains "$out" "no git remote 'nowhere'" "the missing remote was not named"

  [ ! -e "$home/data/old-r1/handoff-request" ] || fail "a refused hand-off left a request behind"
  [ ! -d "$home/state/old-r1.inbox" ] || [ -z "$(find "$home/state/old-r1.inbox" -maxdepth 1 -name '*.msg')" ] ||
    fail "a refused hand-off steered the worker"
  pass "fm-handoff refuses a remote target, an open decision, a recorded PR, and a missing remote before steering"
}

test_ship_handoff_end_to_end() {
  local case_dir home out status head msg
  [ "$HAVE_TASKS_AXI" -eq 1 ] || { pass "skipped: tasks-axi is not installed"; return; }
  case_dir=$(make_case ship)
  home=$case_dir/home
  start_task "$case_dir" old-e1 ship
  [ "$(row_field "$case_dir" old-e1 state)" = in_flight ] || fail "fixture: the task is not in flight"

  out=$(in_case "$case_dir" "$case_dir/wt1" "$HANDOFF" old-e1 --to local --reason "context exhausted")
  expect_code 0 $? "the hand-off request should succeed"$'\n'"$out"
  assert_contains "$out" "requested: old-e1" "the request was not reported"
  msg=$(find "$home/state/old-e1.inbox" -maxdepth 1 -name '*.msg' | head -n 1)
  [ -n "$msg" ] || fail "the worker was not steered"
  assert_grep "push origin fm/old-e1" "$msg" "the steer does not ask for the push"
  assert_grep "paused [at=<epoch>]: handoff ready fm/old-e1" "$msg" "the steer does not name the ready line"
  assert_grep "$home/data/old-e1/handoff-notes.md" "$msg" "the steer does not ask for notes"

  out=$(in_case "$case_dir" "$case_dir/wt2" "$HANDOFF" old-e1 --to local)
  expect_code 75 $? "finishing before the ready line should wait"
  assert_contains "$out" "waiting: old-e1" "the wait was not reported"

  head=$(worker_ships_ready "$case_dir" old-e1 nopush)
  out=$(in_case "$case_dir" "$case_dir/wt2" "$HANDOFF" old-e1 --to local)
  [ $? -eq 1 ] || fail "a hand-off finished before the branch was pushed"
  assert_contains "$out" "ask the worker to push" "the unpushed branch was not named"
  [ -f "$home/state/old-e1.meta" ] || fail "a refused finish cleaned up the old task"

  git -C "$case_dir/wt1" push --quiet origin fm/old-e1
  out=$(in_case "$case_dir" "$case_dir/wt2" "$HANDOFF" old-e1 --to local --harness claude)
  status=$?
  expect_code 0 "$status" "the hand-off should finish"$'\n'"$out"
  assert_contains "$out" "handed-off: old-e1 -> old-e1-c2 on local" "the hand-off was not reported"
  [ ! -e "$home/state/old-e1.meta" ] || fail "the old task was not cleaned up"
  [ "$(row_field "$case_dir" old-e1 state)" = done ] || fail "the old backlog item is not closed"
  backlog "$case_dir" show old-e1 --full | grep -F 'continued as old-e1-c2 on local' >/dev/null ||
    fail "the old backlog item does not say what it continued as"
  [ "$(row_field "$case_dir" old-e1-c2 state)" = in_flight ] || fail "the continuation's backlog item is not in flight"
  [ "$(row_field "$case_dir" old-e1-c2 title)" = 'widget work' ] || fail "the continuation did not keep the item's title"
  assert_grep 'continued_from=old-e1' "$home/state/old-e1-c2.meta" "the continuation record does not name the old task"
  assert_grep 'mode=direct-PR' "$home/state/old-e1-c2.meta" "the continuation did not keep the delivery mode"
  [ "$(git -C "$case_dir/wt2" rev-parse HEAD)" = "$head" ] || fail "the continuation copy is not at the carried commit"
  [ -f "$case_dir/wt2/untracked-wip.txt" ] || fail "the work-in-progress commit was not carried"
  assert_grep 'Continued from: old-e1' "$home/data/old-e1-c2/brief.md" "the continuation brief does not name the old task"
  assert_grep 'Ship the widget for old-e1.' "$home/data/old-e1-c2/brief.md" "the continuation brief lost the captain's intent"
  assert_grep 'Done: first half. Left: second half.' "$home/data/old-e1-c2/handoff.md" "the handoff document lost the worker's notes"
  assert_grep 'context exhausted' "$home/data/old-e1-c2/handoff.md" "the handoff document lost the reason"

  out=$(in_case "$case_dir" "$case_dir/wt2" "$HANDOFF" old-e1 --to local)
  expect_code 0 $? "a repeated finish should be a no-op"
  assert_contains "$out" "already done" "the repeated finish was not reported as done"
  pass "a ship hand-off carries its pushed work into a fresh task with one live backlog item at a time"
}

test_scout_handoff_end_to_end() {
  local case_dir home out
  [ "$HAVE_TASKS_AXI" -eq 1 ] || { pass "skipped: tasks-axi is not installed"; return; }
  case_dir=$(make_case scout)
  home=$case_dir/home
  start_task "$case_dir" old-sc1 scout

  out=$(in_case "$case_dir" "$case_dir/wt1" "$HANDOFF" old-sc1 --to local --as next-sc1)
  expect_code 0 $? "the scout hand-off request should succeed"$'\n'"$out"
  assert_grep "interim report" "$(find "$home/state/old-sc1.inbox" -maxdepth 1 -name '*.msg' | head -n 1)" \
    "the scout steer does not ask for an interim report"

  printf '# Interim\nFindings so far.\n' > "$home/data/old-sc1/report.md"
  printf 'Left: check the second source.\n' > "$home/data/old-sc1/handoff-notes.md"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$ROOT/bin/fm-captain-hold.sh" complete old-sc1 --none) ||
    fail "fixture: the scout could not pass its completion gate"$'\n'"$out"
  status_append "$case_dir" old-sc1 "paused [at=$(date +%s)]: handoff ready"

  out=$(in_case "$case_dir" "$case_dir/wt2" "$HANDOFF" old-sc1 --to local)
  expect_code 0 $? "the scout hand-off should finish"$'\n'"$out"
  [ ! -e "$home/state/old-sc1.meta" ] || fail "the old scout was not cleaned up"
  assert_grep 'kind=scout' "$home/state/next-sc1.meta" "the continuation is not a scout"
  assert_grep 'continued_from=old-sc1' "$home/state/next-sc1.meta" "the continuation does not name the old scout"
  assert_grep "$home/data/old-sc1/report.md" "$home/data/next-sc1/brief.md" "the brief does not point at the interim report"
  [ "$(row_field "$case_dir" next-sc1 state)" = in_flight ] || fail "the continuation's backlog item is not in flight"
  pass "a scout hand-off carries its interim report and notes into a fresh scout"
}

test_cancel_withdraws_a_request() {
  local case_dir home out
  [ "$HAVE_TASKS_AXI" -eq 1 ] || { pass "skipped: tasks-axi is not installed"; return; }
  case_dir=$(make_case cancel)
  home=$case_dir/home
  start_task "$case_dir" old-x1 ship
  in_case "$case_dir" "$case_dir/wt1" "$HANDOFF" old-x1 --to local >/dev/null || fail "fixture: the request failed"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$HANDOFF" old-x1 --to local --cancel)
  expect_code 0 $? "cancel should succeed"$'\n'"$out"
  [ ! -e "$home/data/old-x1/handoff-request" ] || fail "cancel left the request"
  [ -f "$home/state/old-x1.meta" ] || fail "cancel touched the task record"
  [ "$(find "$home/state/old-x1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 2 ] ||
    fail "cancel did not tell the worker to resume"
  pass "fm-handoff --cancel withdraws a request and tells the worker to resume"
}

fm_test_run \
  test_brief_continue_from_copies_the_task_and_records_the_source \
  test_spawn_continue_from_starts_at_the_carried_commit \
  test_handoff_refuses_what_it_cannot_carry \
  test_ship_handoff_end_to_end \
  test_scout_handoff_end_to_end \
  test_cancel_withdraws_a_request
