#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
WORLD=$ROOT/.test-rescue-tmp/live
mkdir -p "$WORLD"
trap 'tmux -S .test-rescue-tmp/s kill-server 2>/dev/null || true' EXIT
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION REX_SESSION REX_BLOCK TMUX FM_TASK_ID
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME='Rescue Lab' GIT_AUTHOR_EMAIL='lab@example.invalid' GIT_COMMITTER_NAME='Rescue Lab' GIT_COMMITTER_EMAIL='lab@example.invalid'
export FM_BACKEND=tmux FM_GH_ACCOUNT=none
setup() {
  C=$WORLD/$1
  mkdir -p "$C/user" "$C/home"
  "$ROOT/bin/fm-lab-home.sh" create "$C/home"
  export HOME=$C/user FM_HOME=$C/home TREEHOUSE_ROOT=$C/pool
  mkdir -p "$C/project"
  git -C "$C/project" init -qb main
  printf 'base\n' > "$C/project/base.txt"
  git -C "$C/project" add .; git -C "$C/project" commit -qm base
  git init -q --bare "$C/origin.git"
  git -C "$C/project" remote add origin "$C/origin.git"
  git -C "$C/project" push -qu origin main
  git -C "$C/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$C/project" remote set-head origin main
  git -C "$C/project" worktree add -q -b fm/source "$C/copy" main
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$FM_HOME/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
  printf 'manual\n' > "$FM_HOME/config/backlog-backend"
  printf 'project=%s\nworktree=%s\nbranch=fm/source\nkind=ship\nmode=direct-PR\nbackend=tmux\nspawn_gen=rescue-live\n' "$C/project" "$C/copy" > "$FM_HOME/state/source.meta"
  mkdir -p "$FM_HOME/data/source"
  printf '# Task\n## Captain\x27s intent\nCarry the widget safely.\n## Firstmate spec\nEdit widget files.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n' > "$FM_HOME/data/source/brief.md"
}
commit() {
  printf '%s\n' "$2" > "$C/copy/$1"
  git -C "$C/copy" add .; git -C "$C/copy" commit -qm "$2"
}
refs_present() {
  test "$(git -C "$HOME/fm-rescue/project.git" rev-parse refs/heads/fm/source)" = "$HEAD"
  test "$(git -C "$C/project" rev-parse refs/remotes/fm-rescue/fm/source)" = "$HEAD"
  echo "durable rescue + tracking refs retain $HEAD"
}
refs_absent() {
  ! git -C "$HOME/fm-rescue/project.git" show-ref --verify --quiet refs/heads/fm/source
  ! git -C "$C/project" show-ref --verify --quiet refs/remotes/fm-rescue/fm/source
  echo 'rescue branch and tracking ref both absent'
}
expect_refusal() {
  local rc=0
  "$@" || rc=$?
  test "$rc" = 1
  echo "refusal exit=$rc"
}
carry() {
  "$ROOT/bin/fm-rescue.sh" ensure source
  commit widget.txt 'first carried feature'
  commit second.txt 'second carried feature'
  HEAD=$(git -C "$C/copy" rev-parse HEAD)
  git -C "$C/copy" push -q fm-rescue fm/source
  . "$ROOT/bin/fm-continuation-lib.sh"
  fm_continuation_write "$FM_HOME/data" source-c2 source ship fm-rescue fm/source "$HEAD"
  rm "$FM_HOME/state/source.meta"
}
forge() {
  mkdir -p "$C/forgebin"
  printf '%s\n' "$1" > "$C/pr-head"
  printf '%s\n' "${2:-MERGED}" > "$C/pr-state"
  printf 'pr=https://github.com/synthetic/local/pull/7\n' > "$FM_HOME/data/source-c2/rescue-pr"
  printf '#!/usr/bin/env bash\nset -eu\nC=%q\n[ "$1 $2" = "pr view" ] || exit 1\nstate=$(<"$C/pr-state")\n[ "$state" != unavailable ] || exit 1\nprintf "%%s\\t%%s\\thttps://github.com/synthetic/local/pull/7\\n" "$state" "$(<"$C/pr-head")"\n' "$C" > "$C/forgebin/gh"
  chmod +x "$C/forgebin/gh"
}
prune() { "$ROOT/bin/fm-rescue.sh" prune source "$C/project" "$@"; }

printf '\nSCENARIO 1: On-demand handoff request creates private rescue storage; conflicts stay untouched\n'
setup request
tmux -S .test-rescue-tmp/s new-session -d -s fm-lab-rescue -n fm-source -c "$C/copy" -x 100 -y 30 'sleep 600'
export TMUX=".test-rescue-tmp/s,$(tmux -S .test-rescue-tmp/s display-message -p '#{pid}'),0"
printf 'window=fm-lab-rescue:fm-source\n' >> "$FM_HOME/state/source.meta"
touch "$FM_HOME/state/.last-watcher-beat"
"$ROOT/bin/fm-handoff.sh" source --to local --remote fm-rescue
repo=$HOME/fm-rescue/project.git
test "$(git -C "$repo" rev-parse --is-bare-repository)" = true
test "$(git -C "$C/copy" remote get-url fm-rescue)" = "$repo"
"$ROOT/bin/fm-rescue.sh" ensure source
ls -ld "$HOME/fm-rescue" "$repo"
test -s "$FM_HOME/data/source/handoff-request"
ls "$FM_HOME/state/source.inbox"
git -C "$C/project" remote set-url fm-rescue "$C/unrelated.git"
expect_refusal "$ROOT/bin/fm-rescue.sh" ensure source
test "$(git -C "$C/project" remote get-url fm-rescue)" = "$C/unrelated.git"
echo 'PASS 1: request persisted; steer delivered; repeat ensure works; conflicting URL unchanged'
tmux -S .test-rescue-tmp/s kill-server
unset TMUX

printf '\nSCENARIO 2: Real teardown rejects unpreserved work, then accepts rescue-only work without --force\n'
setup cleanup
# Use a real Treehouse lease instead of an ad-hoc worktree.
git -C "$C/project" worktree remove "$C/copy"
git -C "$C/project" branch -D fm/source
COPY=$(cd "$C/project" && treehouse get --lease -b fm/source)
CLEAN_COPY=$COPY
# Helpers use C/copy: this case commits directly in the actual leased slot.
printf 'project=%s\nworktree=%s\nbranch=fm/source\nkind=ship\nmode=direct-PR\nbackend=tmux\nspawn_gen=rescue-live\n' "$C/project" "$COPY" > "$FM_HOME/state/source.meta"
tmux -S .test-rescue-tmp/s new-session -d -s fm-lab-rescue -n fm-source -c "$COPY" -x 100 -y 30 'sleep 600'
export TMUX=".test-rescue-tmp/s,$(tmux -S .test-rescue-tmp/s display-message -p '#{pid}'),0"
printf 'window=fm-lab-rescue:fm-source\n' >> "$FM_HOME/state/source.meta"
printf 'rescued feature\n' > "$COPY/widget.txt"
git -C "$COPY" add .; git -C "$COPY" commit -qm 'rescued feature'
HEAD=$(git -C "$COPY" rev-parse HEAD)
expect_refusal "$ROOT/bin/fm-teardown.sh" source
test -f "$FM_HOME/state/source.meta"
"$ROOT/bin/fm-rescue.sh" ensure source
git -C "$COPY" push -q fm-rescue fm/source
"$ROOT/bin/fm-teardown.sh" source
test ! -f "$FM_HOME/state/source.meta"
refs_present
! git -C "$C/origin.git" show-ref --verify --quiet refs/heads/fm/source
echo 'PASS 2: cleanup removed task record, returned real Treehouse slot, retained external rescue; origin untouched'
tmux -S .test-rescue-tmp/s kill-server 2>/dev/null || true
unset TMUX

printf '\nSCENARIO 3: Live and pending continuations, feature pushes and wrong bases cannot prune; actual base landing can\n'
setup base
carry
printf 'kind=ship\n' > "$FM_HOME/state/source-c2.meta"
expect_refusal prune --abandoned
rm "$FM_HOME/state/source-c2.meta"
touch "$FM_HOME/data/source-c2/handoff-request"
expect_refusal prune --abandoned
rm "$FM_HOME/data/source-c2/handoff-request"
printf 'base_branch=release/next\n' > "$FM_HOME/data/source/handoff-request"
git -C "$C/copy" push -q origin fm/source HEAD:main
git -C "$C/project" update-ref refs/remotes/no-mistakes/release/next "$HEAD"
git -C "$C/project" update-ref refs/remotes/fm-rescue/release/next "$HEAD"
expect_refusal prune
refs_present
git -C "$C/copy" push -q origin HEAD:refs/heads/release/next
prune
refs_absent
prune
echo 'PASS 3: guarded until recorded target landed; repeated prune harmless'

printf '\nSCENARIO 4: Rebase plus real squash merge prunes only with synthetic MERGED forge evidence\n'
setup rebase
carry
printf 'new base\n' > "$C/project/advance.txt"
git -C "$C/project" add .; git -C "$C/project" commit -qm 'advance main'
git -C "$C/project" push -q origin main
git -C "$C/copy" rebase origin/main
PR_HEAD=$(git -C "$C/copy" rev-parse HEAD)
! git -C "$C/project" merge-base --is-ancestor "$HEAD" "$PR_HEAD"
git -C "$C/project" merge --squash fm/source
git -C "$C/project" commit -qm 'squash merged continuation'
git -C "$C/project" push -q origin main
! git -C "$C/project" merge-base --is-ancestor "$HEAD" origin/main
test "$(<"$C/project/widget.txt")" = 'first carried feature'
test "$(<"$C/project/second.txt")" = 'second carried feature'
forge "$PR_HEAD" OPEN
expect_refusal env PATH="$C/forgebin:$PATH" "$ROOT/bin/fm-rescue.sh" prune source "$C/project"
printf 'unavailable\n' > "$C/pr-state"
expect_refusal env PATH="$C/forgebin:$PATH" "$ROOT/bin/fm-rescue.sh" prune source "$C/project"
refs_present
printf 'MERGED\n' > "$C/pr-state"
env PATH="$C/forgebin:$PATH" "$ROOT/bin/fm-rescue.sh" prune source "$C/project"
refs_absent
echo 'PASS 4: actual rewritten and squash-landed content pruned; open/unavailable responses retained refs (synthetic forge, not GitHub validation)'

printf '\nSCENARIO 5: A synthetically merged PR that drops all or some carried work retains both rescue refs\n'
for mode in dropped partial; do
  setup "$mode"
  carry
  FIRST=$(git -C "$C/copy" rev-parse HEAD~1)
  printf 'other feature\n' > "$C/project/other.txt"
  git -C "$C/project" add .; git -C "$C/project" commit -qm 'different feature'
  if [ "$mode" = partial ]; then git -C "$C/project" cherry-pick "$FIRST"; fi
  PR_HEAD=$(git -C "$C/project" rev-parse HEAD)
  git -C "$C/project" push -q origin main
  test ! -e "$C/project/second.txt"
  forge "$PR_HEAD"
  expect_refusal env PATH="$C/forgebin:$PATH" "$ROOT/bin/fm-rescue.sh" prune source "$C/project"
  refs_present
  echo "PASS 5/$mode: actual landed head omits carried content; no deletion despite synthetic MERGED state"
done

printf '\nSCENARIO 6: Abandonment deletes only unchanged refs; other remotes remain intact\n'
setup abandon
carry
commit extra.txt 'new work after handoff'
MOVED=$(git -C "$C/copy" rev-parse HEAD)
git -C "$C/copy" push -q fm-rescue fm/source
expect_refusal prune --abandoned
test "$(git -C "$HOME/fm-rescue/project.git" rev-parse refs/heads/fm/source)" = "$MOVED"
echo "moved rescue ref retained at $MOVED"
git -C "$C/copy" push -q --force fm-rescue "$HEAD:refs/heads/fm/source"
prune --abandoned
refs_absent
ORIGIN=$(git -C "$C/origin.git" rev-parse main)
echo "origin main unchanged: $ORIGIN"
echo 'PASS 6: explicit abandonment prunes; moved work remains protected'
printf '\nALL LIVE LOCAL SCENARIOS COMPLETED\n'
