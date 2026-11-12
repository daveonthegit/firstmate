#!/usr/bin/env bash
# Behavior tests for the private rescue remote (bin/fm-rescue.sh): creating the
# per-project bare repository and the fm-rescue remote on demand, ordinary
# cleanup accepting work pushed only there, a hand-off carried through it, and
# pruning its refs once the continuation lands or the work is abandoned.
#
# The end-to-end cases drive the real spawn, steer, cleanup, and backlog paths
# against a real tasks-axi backlog, a real git origin, and a fake terminal; a
# "worker" is simulated by committing in its copy and pushing.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

unset TASKS_AXI_BACKEND FM_TASK_INBOX FM_GH_ACCOUNT || :

RESCUE="$ROOT/bin/fm-rescue.sh"
HANDOFF="$ROOT/bin/fm-handoff.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-rescue)
cd "$TMP_ROOT" || exit 1

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

GIT_ID=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')

# A home with a real backlog, a project with an origin, and two pooled copies.
make_case() {  # <name>
  local case_dir=$TMP_ROOT/$1 home fakebin
  home=$case_dir/home
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$case_dir/user-home"
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

row_state() {  # <case-dir> <id>
  backlog "$1" show "$2" 2>/dev/null | sed -n 's/^  state: *//p' | head -n 1
}

rescue_repo() {  # <case-dir>
  printf '%s\n' "$1/user-home/fm-rescue/project.git"
}

start_ship() {  # <case-dir> <id> <pane>
  local case_dir=$1 id=$2 home=$1/home out
  mkdir -p "$home/data/$id"
  printf '%s\n' '# Task' "## Captain's intent" "Ship the widget for $id." '' '## Firstmate spec' 'Touch only widget.txt.' '' \
    '# Setup' 'You are in a disposable git worktree of project, at a detached HEAD on a clean default branch.' '' \
    '# Definition of done' 'Delivery contract: mode=direct-PR' > "$home/data/$id/brief.md"
  backlog "$case_dir" add "$id" "widget work" --kind ship --repo project >/dev/null
  out=$(in_case "$case_dir" "$3" "$ROOT/bin/fm-spawn.sh" "$id" "$case_dir/project" --mode direct-PR --yolo off) ||
    fail "could not spawn $id"$'\n'"$out"
}

commit_work() {  # <copy> <branch> <text>
  git -C "$1" checkout --quiet -B "$2"
  printf '%s\n' "$3" >> "$1/widget.txt"
  git -C "$1" add -A
  git -C "$1" "${GIT_ID[@]}" commit -qm "$3"
  git -C "$1" rev-parse HEAD
}

test_ensure_creates_a_private_repository_and_remote() {
  local case_dir home out repo
  case_dir=$(make_case ensure)
  home=$case_dir/home
  printf '%s\n' "project=$case_dir/project" "worktree=$case_dir/wt1" > "$home/state/e1.meta"
  repo=$(rescue_repo "$case_dir")

  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" ensure e1)
  expect_code 0 $? "ensure should create the rescue repository"$'\n'"$out"
  assert_contains "$out" "created: rescue repository $repo" "the creation was not reported"
  [ "$(git -C "$repo" rev-parse --is-bare-repository)" = true ] || fail "the rescue repository is not bare"
  [ "$(stat -f %Lp "$(dirname "$repo")" 2>/dev/null || stat -c %a "$(dirname "$repo")")" = 700 ] ||
    fail "the rescue directory is not private"
  [ "$(git -C "$case_dir/wt1" remote get-url fm-rescue)" = "$repo" ] || fail "the copy has no fm-rescue remote"
  [ "$(git -C "$case_dir/wt2" remote get-url fm-rescue)" = "$repo" ] || fail "another copy of the project does not see the remote"

  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" ensure e1)
  expect_code 0 $? "ensure should be idempotent"$'\n'"$out"
  assert_not_contains "$out" "created:" "a repeated ensure created the repository again"

  git -C "$case_dir/project" remote set-url fm-rescue "$case_dir/elsewhere.git"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" ensure e1)
  expect_code 1 $? "ensure must refuse a conflicting fm-rescue remote"
  assert_contains "$out" "already has a remote 'fm-rescue'" "the conflicting remote was not named"
  [ "$(git -C "$case_dir/wt1" remote get-url fm-rescue)" = "$case_dir/elsewhere.git" ] || fail "ensure replaced a conflicting remote"

  git -C "$case_dir/project" remote remove fm-rescue
  rm -rf "$repo"
  mkdir -p "$repo"
  printf 'not a repository\n' > "$repo/notes.txt"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" ensure e1)
  expect_code 1 $? "ensure must refuse a path that is not a bare repository"
  assert_contains "$out" "is not a bare git repository" "the unusable path was not named"
  if git -C "$case_dir/wt1" remote get-url fm-rescue >/dev/null 2>&1; then
    fail "a refused ensure added the remote"
  fi
  pass "fm-rescue ensure creates a private bare repository and a shared fm-rescue remote, and refuses conflicts"
}

test_cleanup_accepts_rescued_work_without_force() {
  local case_dir home out head
  [ "$HAVE_TASKS_AXI" -eq 1 ] || { pass "skipped: tasks-axi is not installed"; return; }
  case_dir=$(make_case teardown)
  home=$case_dir/home
  start_ship "$case_dir" old-t1 "$case_dir/wt1"
  head=$(commit_work "$case_dir/wt1" fm/old-t1 'rescued work')

  if out=$(in_case "$case_dir" "$case_dir/wt1" "$TEARDOWN" old-t1); then
    fail "cleanup accepted work that is on no remote"
  fi
  assert_contains "$out" "not on any remote" "the unlanded work was not named"
  [ -f "$home/state/old-t1.meta" ] || fail "a refused cleanup removed the task record"

  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" ensure old-t1) || fail "ensure failed: $out"
  git -C "$case_dir/wt1" push --quiet fm-rescue fm/old-t1 || fail "could not push to the rescue remote"
  [ "$(git -C "$case_dir/project" rev-parse refs/remotes/fm-rescue/fm/old-t1)" = "$head" ] ||
    fail "the push did not leave a remote-tracking ref"

  out=$(in_case "$case_dir" "$case_dir/wt1" "$TEARDOWN" old-t1)
  expect_code 0 $? "ordinary cleanup should accept work pushed to the rescue remote"$'\n'"$out"
  [ ! -e "$home/state/old-t1.meta" ] || fail "cleanup kept the task record"
  [ "$(git -C "$(rescue_repo "$case_dir")" rev-parse refs/heads/fm/old-t1)" = "$head" ] ||
    fail "the rescued work is not in the rescue repository"
  if git -C "$case_dir/origin.git" rev-parse --verify --quiet refs/heads/fm/old-t1 >/dev/null; then
    fail "the rescued branch reached origin"
  fi
  pass "ordinary cleanup accepts work pushed only to the rescue remote, with no --force"
}

test_handoff_through_rescue_then_prune_on_landing() {
  local case_dir home out head msg repo mode base pr_head old_base
  [ "$HAVE_TASKS_AXI" -eq 1 ] || { pass "skipped: tasks-axi is not installed"; return; }
  for mode in unchanged pushed merged squash squash-open squash-wrong squash-down; do
  case_dir=$(make_case "handoff-$mode")
  base=$(git -C "$case_dir/project" symbolic-ref --short HEAD)
  home=$case_dir/home
  repo=$(rescue_repo "$case_dir")
  start_ship "$case_dir" old-h1 "$case_dir/wt1"

  out=$(in_case "$case_dir" "$case_dir/wt1" "$HANDOFF" old-h1 --to local --remote fm-rescue)
  expect_code 0 $? "a hand-off through fm-rescue should be requested without preparing the remote first"$'\n'"$out"
  [ "$(git -C "$case_dir/wt1" remote get-url fm-rescue)" = "$repo" ] || fail "the request did not add the rescue remote"
  msg=$(find "$home/state/old-h1.inbox" -maxdepth 1 -name '*.msg' | head -n 1)
  assert_grep "push fm-rescue fm/old-h1" "$msg" "the steer does not push to the rescue remote"

  head=$(commit_work "$case_dir/wt1" fm/old-h1 'first half')
  git -C "$case_dir/wt1" push --quiet fm-rescue fm/old-h1
  printf 'Done: first half.\n' > "$home/data/old-h1/handoff-notes.md"
  printf 'paused [at=%s]: handoff ready fm/old-h1 %s\n' "$(date +%s)" "$head" >> "$home/state/old-h1.status"

  out=$(in_case "$case_dir" "$case_dir/wt2" "$HANDOFF" old-h1 --to local --remote fm-rescue)
  expect_code 0 $? "the hand-off should finish through ordinary cleanup"$'\n'"$out"
  [ ! -e "$home/state/old-h1.meta" ] || fail "the old task was not cleaned up"
  [ "$(git -C "$case_dir/wt2" rev-parse HEAD)" = "$head" ] || fail "the continuation did not start at the rescued commit"
  if git -C "$case_dir/origin.git" rev-parse --verify --quiet refs/heads/fm/old-h1 >/dev/null; then
    fail "the carried branch reached origin"
  fi

  out=$(in_case "$case_dir" "$case_dir/wt2" "$RESCUE" prune old-h1 "$case_dir/project")
  expect_code 1 $? "prune must refuse while the continuation is live"
  assert_contains "$out" "old-h1-c2, the last continuation of old-h1, still has a task record" "the live continuation was not named"
  [ "$(git -C "$repo" rev-parse refs/heads/fm/old-h1)" = "$head" ] || fail "a refused prune deleted the rescued work"

  if [ "$mode" != unchanged ]; then
    commit_work "$case_dir/wt2" fm/old-h1-c2 'second half' >/dev/null
    git -C "$case_dir/wt2" push --quiet origin fm/old-h1-c2
  fi
  if [ "$mode" = merged ]; then
    git -C "$case_dir/wt2" push --quiet origin "HEAD:refs/heads/$base"
  fi
  case "$mode" in squash*)
    pr_head=$(git -C "$case_dir/wt2" rev-parse HEAD)
    old_base=$(git -C "$case_dir/project" rev-parse HEAD)
    git -C "$case_dir/project" merge --quiet --squash fm/old-h1-c2 >/dev/null || fail "fixture: squash merge failed"
    git -C "$case_dir/project" "${GIT_ID[@]}" commit -qm 'squashed continuation'
    git -C "$case_dir/project" push --quiet origin "$base"
    git -C "$case_dir/project" push --quiet origin --delete fm/old-h1-c2
    if git -C "$case_dir/project" merge-base --is-ancestor "$head" "origin/$base"; then
      fail "fixture: the squash preserved the original ancestry"
    fi
    printf 'pr=https://github.com/example/repo/pull/7\n' >> "$home/state/old-h1-c2.meta"
    printf '%s\n' MERGED > "$case_dir/pr-state"
    printf '%s\n' "$pr_head" > "$case_dir/pr-head"
    case "$mode" in
      squash-open) printf '%s\n' OPEN > "$case_dir/pr-state" ;;
      squash-wrong) printf '%s\n' "$old_base" > "$case_dir/pr-head" ;;
      squash-down) printf '%s\n' unavailable > "$case_dir/pr-state" ;;
    esac
    cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'pr view')
    fixture=$(dirname "$(dirname "$0")")
    state=$(cat "$fixture/pr-state")
    [ "$state" != unavailable ] || exit 1
    printf '%s\t%s\t%s\n' "$state" "$(cat "$fixture/pr-head")" https://github.com/example/repo/pull/7
    exit 0 ;;
esac
exit 1
SH
    chmod +x "$case_dir/fakebin/gh"
    ;;
  esac
  out=$(in_case "$case_dir" "$case_dir/wt2" "$TEARDOWN" old-h1-c2)
  expect_code 0 $? "the preserved continuation should clean up"$'\n'"$out"
  if [ "$mode" != merged ] && [ "$mode" != squash ]; then
    assert_contains "$out" "retained: rescue refs" "cleanup did not report retained work"
    [ "$(git -C "$repo" rev-parse refs/heads/fm/old-h1)" = "$head" ] || fail "cleanup deleted unmerged rescued work"
    [ "$(git -C "$case_dir/project" rev-parse refs/remotes/fm-rescue/fm/old-h1)" = "$head" ] || fail "cleanup deleted the unmerged tracking ref"
    out=$(in_case "$case_dir" "$case_dir/wt2" "$RESCUE" prune old-h1 "$case_dir/project")
    expect_code 1 $? "a Done backlog item is not landing proof"
    case "$mode" in
      squash-*)
        printf '%s\n' MERGED > "$case_dir/pr-state"
        printf '%s\n' "$pr_head" > "$case_dir/pr-head"
        ;;
      *) git -C "$case_dir/project" push --quiet origin "$head:refs/heads/$base" ;;
    esac
    out=$(in_case "$case_dir" "$case_dir/wt2" "$RESCUE" prune old-h1 "$case_dir/project")
    expect_code 0 $? "merged work should prune"$'\n'"$out"
  fi
  assert_contains "$out" "pruned: fm/old-h1 at $head" "landing did not prune"
  if git -C "$repo" rev-parse --verify --quiet refs/heads/fm/old-h1 >/dev/null; then
    fail "the rescue repository still holds the carried branch"
  fi
  if git -C "$case_dir/project" rev-parse --verify --quiet refs/remotes/fm-rescue/fm/old-h1 >/dev/null; then
    fail "the project still holds the rescue remote-tracking ref"
  fi

  out=$(in_case "$case_dir" "$case_dir/wt2" "$RESCUE" prune old-h1 "$case_dir/project")
  expect_code 0 $? "a repeated prune should be a no-op"$'\n'"$out"
  assert_contains "$out" "already pruned: fm/old-h1" "the repeated prune was not reported"
  done
  pass "cleanup retains unchanged or pushed work until merged, and landing prunes rescue refs"
}

# Hand-written records: old-p1 handed off through fm-rescue to old-p1-c2, whose
# continuation was never spawned.
test_prune_refusals_and_abandon() {
  local case_dir home out repo head moved
  case_dir=$(make_case prune)
  home=$case_dir/home
  repo=$(rescue_repo "$case_dir")
  printf '%s\n' "project=$case_dir/project" "worktree=$case_dir/wt1" > "$home/state/old-p1.meta"
  in_case "$case_dir" "$case_dir/wt1" "$RESCUE" ensure old-p1 >/dev/null || fail "fixture: ensure failed"
  rm "$home/state/old-p1.meta"
  head=$(commit_work "$case_dir/wt1" fm/old-p1 'carried')
  git -C "$case_dir/wt1" push --quiet fm-rescue fm/old-p1
  bash -c '. "$1/bin/fm-continuation-lib.sh"; fm_continuation_write "$2" old-p1-c2 old-p1 ship fm-rescue fm/old-p1 "$3"' _ "$ROOT" "$home/data" "$head" ||
    fail "fixture: could not write the continuation record"

  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" prune old-p1 "$case_dir/project")
  expect_code 1 $? "prune must retain unmerged work"
  assert_contains "$out" "no proof of landing" "unmerged work was not reported"
  touch "$home/data/old-p1-c2/handoff-request"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" prune old-p1 "$case_dir/project" --abandoned)
  expect_code 1 $? "prune must refuse while the tip has a hand-off in progress"
  rm "$home/data/old-p1-c2/handoff-request"
  printf '%s\n' manual > "$home/config/backlog-backend"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" prune old-p1 "$case_dir/project")
  expect_code 1 $? "manual backlog mode must not bypass landing proof"
  assert_contains "$out" "no proof of landing" "unmerged work was not reported"
  rm "$home/config/backlog-backend"
  [ "$(git -C "$repo" rev-parse refs/heads/fm/old-p1)" = "$head" ] || fail "a refused prune deleted the rescued work"

  moved=$(commit_work "$case_dir/wt1" fm/old-p1 'more')
  git -C "$case_dir/wt1" push --quiet fm-rescue fm/old-p1
  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" prune old-p1 "$case_dir/project" --abandoned)
  expect_code 1 $? "prune must not delete a rescue branch that moved"
  assert_contains "$out" "not the carried $head; left in place" "the moved branch was not reported"
  [ "$(git -C "$repo" rev-parse refs/heads/fm/old-p1)" = "$moved" ] || fail "prune deleted a moved rescue branch"

  git -C "$case_dir/wt1" push --quiet --force fm-rescue "$head:refs/heads/fm/old-p1"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" prune old-p1-c2 "$case_dir/project" --abandoned)
  expect_code 0 $? "an abandoned chain should prune"$'\n'"$out"
  assert_contains "$out" "pruned: fm/old-p1 at $head" "the abandoned prune was not reported"
  if git -C "$repo" rev-parse --verify --quiet refs/heads/fm/old-p1 >/dev/null; then
    fail "the abandoned rescue branch was not pruned"
  fi
  if git -C "$case_dir/project" rev-parse --verify --quiet refs/remotes/fm-rescue/fm/old-p1 >/dev/null; then
    fail "the abandoned tracking ref was not pruned"
  fi
  pass "prune retains unmerged work and moved refs, and --abandoned prunes"
}

test_prune_requires_the_recorded_base() {
  local case_dir home out repo head base
  case_dir=$(make_case named-base)
  home=$case_dir/home
  repo=$(rescue_repo "$case_dir")
  base=$(git -C "$case_dir/project" symbolic-ref --short HEAD)
  printf '%s\n' "project=$case_dir/project" "worktree=$case_dir/wt1" > "$home/state/old-b1.meta"
  in_case "$case_dir" "$case_dir/wt1" "$RESCUE" ensure old-b1 >/dev/null || fail "fixture: ensure failed"
  rm "$home/state/old-b1.meta"
  head=$(commit_work "$case_dir/wt1" fm/old-b1 'carried to release')
  git -C "$case_dir/wt1" push --quiet fm-rescue fm/old-b1
  bash -c '. "$1/bin/fm-continuation-lib.sh"; fm_continuation_write "$2" old-b1-c2 old-b1 ship fm-rescue fm/old-b1 "$3"' _ "$ROOT" "$home/data" "$head" ||
    fail "fixture: could not write the continuation record"
  mkdir -p "$home/data/old-b1"
  printf '%s\n' 'base_branch=release/next' > "$home/data/old-b1/handoff-request"
  git -C "$case_dir/wt1" push --quiet origin "HEAD:refs/heads/$base" fm/old-b1
  git -C "$case_dir/project" update-ref refs/remotes/no-mistakes/release/next "$head"
  git -C "$case_dir/project" update-ref refs/remotes/fm-rescue/release/next "$head"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" prune old-b1 "$case_dir/project")
  expect_code 1 $? "only the recorded remote base may prove landing"
  [ "$(git -C "$repo" rev-parse refs/heads/fm/old-b1)" = "$head" ] || fail "a non-target branch caused rescue deletion"
  [ "$(git -C "$case_dir/project" rev-parse refs/remotes/fm-rescue/fm/old-b1)" = "$head" ] || fail "a non-target branch caused tracking deletion"
  git -C "$case_dir/wt1" push --quiet origin HEAD:refs/heads/release/next
  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" prune old-b1-c2 "$case_dir/project")
  expect_code 0 $? "landing on the recorded base should prune"$'\n'"$out"
  if git -C "$repo" rev-parse --verify --quiet refs/heads/fm/old-b1 >/dev/null; then
    fail "landing on the recorded base did not prune"
  fi
  pass "prune requires the recorded base, excluding feature branches and local mirrors"
}

test_prune_ignores_hand_offs_through_other_remotes() {
  local case_dir home out head
  case_dir=$(make_case other)
  home=$case_dir/home
  head=$(commit_work "$case_dir/wt1" fm/old-o1 'carried')
  git -C "$case_dir/wt1" push --quiet origin fm/old-o1
  bash -c '. "$1/bin/fm-continuation-lib.sh"; fm_continuation_write "$2" old-o1-c2 old-o1 ship origin fm/old-o1 "$3"' _ "$ROOT" "$home/data" "$head" ||
    fail "fixture: could not write the continuation record"
  out=$(in_case "$case_dir" "$case_dir/wt1" "$RESCUE" prune old-o1-c2 "$case_dir/project")
  expect_code 0 $? "a chain carried through origin has nothing to prune"$'\n'"$out"
  assert_contains "$out" "nothing to prune" "the empty prune was not reported"
  [ "$(git -C "$case_dir/origin.git" rev-parse refs/heads/fm/old-o1)" = "$head" ] || fail "prune touched origin"
  pass "prune leaves hand-offs carried through other remotes alone"
}

fm_test_run \
  test_ensure_creates_a_private_repository_and_remote \
  test_cleanup_accepts_rescued_work_without_force \
  test_handoff_through_rescue_then_prune_on_landing \
  test_prune_refusals_and_abandon \
  test_prune_requires_the_recorded_base \
  test_prune_ignores_hand_offs_through_other_remotes
