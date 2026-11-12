#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
export FM_HOME="$ROOT/.l" HOME="$ROOT/.l/user" FM_GH_ACCOUNT=none
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p "$HOME" "$FM_HOME/gh"
export GH_CONFIG_DIR="$FM_HOME/gh" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
export TMUX_TMPDIR="$FM_HOME/t"
export TMUX="$(tmux -L fm-lab display-message -p -t primary '#{socket_path}'),0,0"
printf manual > "$FM_HOME/config/backlog-backend"
export TREEHOUSE_ROOT="$FM_HOME/pool"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME='Rescue Lab' GIT_AUTHOR_EMAIL='lab@example.invalid' GIT_COMMITTER_NAME='Rescue Lab' GIT_COMMITTER_EMAIL='lab@example.invalid'
P="$FM_HOME/projects/widget"
rm -rf "$P" "$FM_HOME/origin.git" "$FM_HOME/copy" "$FM_HOME/pool" "$HOME/fm-rescue" "$FM_HOME/data/a" "$FM_HOME/state/a.meta"
tmux -L fm-lab kill-window -t primary:fm-a 2>/dev/null || true
tmux -L fm-lab new-window -d -t primary -n fm-a -c "$ROOT" 'sleep 600'
git init -q -b main "$P"
printf 'base\n' > "$P/widget.txt"
git -C "$P" add .; git -C "$P" commit -qm base
git init -q --bare "$FM_HOME/origin.git"
git -C "$P" remote add origin "$FM_HOME/origin.git"
git -C "$P" push -q -u origin main
C=$(cd "$P" && treehouse get --lease --no-fetch)
cat > "$FM_HOME/state/a.meta" <<EOF
kind=ship
project=$P
worktree=$C
branch=fm/a
mode=direct-PR
backend=tmux
window=primary:fm-a
EOF
mkdir -p "$FM_HOME/data/a"
printf '# Task\n## Captain\x27s intent\nCarry widget.\n## Firstmate spec\nEdit widget.txt only.\n' > "$FM_HOME/data/a/brief.md"
echo '=== Handoff request creates rescue remote on demand ==='
"$ROOT/bin/fm-handoff.sh" a --to local --remote fm-rescue
R="$HOME/fm-rescue/widget.git"
test "$(git -C "$R" rev-parse --is-bare-repository)" = true
test "$(git -C "$C" remote get-url fm-rescue)" = "$R"
echo "bare=$(git -C "$R" rev-parse --is-bare-repository) permissions=$(stat -f %Lp "$HOME/fm-rescue")"
"$ROOT/bin/fm-rescue.sh" ensure a
# Cancel the request so ordinary cleanup can be tested independently.
"$ROOT/bin/fm-handoff.sh" a --to local --cancel

git -C "$C" checkout -qb fm/a
printf 'carried\n' >> "$C/widget.txt"
git -C "$C" commit -qam carried
H=$(git -C "$C" rev-parse HEAD)
echo '=== Cleanup refuses unpreserved work ==='
if "$ROOT/bin/fm-teardown.sh" a; then echo 'ERROR accepted unpreserved work'; exit 1; fi
test -f "$FM_HOME/state/a.meta"
echo '=== Push rescue, cleanup without force ==='
git -C "$C" push -q fm-rescue fm/a
"$ROOT/bin/fm-teardown.sh" a
test ! -e "$FM_HOME/state/a.meta"
test "$(git -C "$R" rev-parse refs/heads/fm/a)" = "$H"
test "$(git -C "$FM_HOME/origin.git" for-each-ref --format='%(refname)' refs/heads/)" = refs/heads/main
echo "Rescued commit $H survives outside returned copy; origin has only main."
printf '%s\n' "$H" > "$FM_HOME/carried-head"
printf '%s\n' "$P" > "$FM_HOME/project-path"
echo 'BASE-LIVE-PASS'
