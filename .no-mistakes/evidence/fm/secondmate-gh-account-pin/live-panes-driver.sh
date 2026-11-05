#!/usr/bin/env bash
set -u
R=$PWD; D="$R/.gate-lab"; E=~/.no-mistakes/evidence/01M6PKMN43MHXMXK8YNN8EX7Y3
REAL_TMUX=$(command -v tmux); REAL_CLAUDE=$(command -v claude)
mkdir -p "$D/wrap" "$D/socket"
# A transport-only wrapper keeps the real tmux socket path short without writing outside the worktree.
printf '#!/bin/bash\ncd %q || exit 1\nexec %q -S ./fm-lab "$@"\n' "$D/socket" "$REAL_TMUX" > "$D/wrap/tmux"
printf '#!/bin/bash\nprintf "GH_TOKEN=%%s FM_GH_ACCOUNT=%%s\\n" "${GH_TOKEN:-EMPTY}" "${FM_GH_ACCOUNT:-ABSENT}" >> "$FM_LIVE_ENV_LOG"\nexec %q "$@"\n' "$REAL_CLAUDE" > "$D/wrap/claude"
chmod +x "$D/wrap/tmux" "$D/wrap/claude"
export PATH="$D/wrap:$PATH"
cleanup() { tmux kill-server 2>/dev/null || :; }
trap cleanup EXIT
for shell in bash fish; do
  id="gh-live-pane-$shell"; home="$D/mate-$shell"; log="$E/pane-$shell-env.log"
  "$R/bin/fm-lab-home.sh" create "$home" || exit $?
  ln -s "$R/bin" "$home/bin"
  printf '# Disposable validation home\nDo not start supervision or run fleet lifecycle commands. Respond only READY.\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'Respond READY and do not run any commands.\n' > "$home/data/charter.md"
  git -C "$home" init -q -b lab
  git -C "$home" remote add origin https://github.com/daveonthegit/firstmate.git
  if [ "$shell" = fish ]; then shellpath="$D/fish/fish-4.9.3.app/Contents/Resources/base/usr/local/bin/fish"; else shellpath=/bin/bash; fi
  export FM_LIVE_ENV_LOG="$log"
  GH_TOKEN=old-launch-owner-token tmux new-session -d -s primary -x 120 -y 35 -c "$R" '/bin/bash --noprofile --norc'
  tmux set-option -g default-shell "$shellpath"
  tmux set-environment -g GH_TOKEN old-launch-owner-token
  tmux set-environment -g FM_LIVE_ENV_LOG "$log"
  export TMUX="./fm-lab,$$,0"
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$D/primary" FM_ROOT_OVERRIDE="$D/code" FM_SPAWN_NO_GUARD=1 "$D/code/bin/fm-spawn.sh" "$id" "$home" --harness claude --backend tmux --secondmate > "$E/pane-$shell-spawn.log" 2>&1
  rc=$?; echo "$shell fresh spawn=$rc"; [ "$rc" = 0 ] || { tail -20 "$E/pane-$shell-spawn.log"; exit 1; }
  sleep 3
  tmux capture-pane -p -t "primary:fm-$id" > "$E/pane-$shell-fresh.txt"
  # Reproduce an old launch: the endpoint is now agent-free but its interactive shell exports the previous owner's token.
  tmux respawn-pane -k -t "primary:fm-$id" -c "$home" "env GH_TOKEN=old-launch-owner-token FM_LIVE_ENV_LOG='$log' '$shellpath' -i"
  sleep 1
  printf 'gh_account=daveonthegit\n' >> "$D/primary/state/$id.meta"
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$D/primary" FM_ROOT_OVERRIDE="$D/code" FM_SPAWN_NO_GUARD=1 "$D/code/bin/fm-spawn.sh" "$id" --relaunch --harness claude > "$E/pane-$shell-relaunch.log" 2>&1
  rc=$?; echo "$shell relaunch=$rc"; [ "$rc" = 0 ] || { tail -20 "$E/pane-$shell-relaunch.log"; exit 1; }
  sleep 3
  tmux capture-pane -p -t "primary:fm-$id" > "$E/pane-$shell-relaunch.txt"
  python3 - "$log" "$D/primary/state/$id.meta" <<'PY'
import sys
lines=open(sys.argv[1]).read().splitlines()
print('\n'.join(lines))
assert len(lines)==2, lines
assert lines==['GH_TOKEN=EMPTY FM_GH_ACCOUNT=ABSENT']*2, lines
assert not any(l.startswith('gh_account=') for l in open(sys.argv[2]))
PY
  [ "$?" = 0 ] || exit 1
  cleanup
  unset TMUX
 done
