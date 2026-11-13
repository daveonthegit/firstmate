#!/usr/bin/env bash
set -u
E=~/.no-mistakes/evidence/01M7B0601XBFMBS0XPWMER9J4Q
LAB="$E/l"
mkdir -p "$LAB"
bin/fm-lab-home.sh create "$LAB" || exit 1
mkdir -p "$LAB/tmux"
touch "$LAB/config/supervision-host"
printf '9999999\n' > "$LAB/state/.lock"
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -S -300 -t primary > "$E/claude-primary-final.txt" 2>&1 || true
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" 'claude -p "In this disposable marked lab home, run bin/fm-lock.sh to acquire or reclaim the stale session lock, then run bin/fm-lock.sh status. Report both exact outputs. Do not spawn workers, access another home, or change credentials." --allowedTools "Bash(bin/fm-lock.sh *)" "Bash(bin/fm-lock.sh)" --output-format stream-json --verbose > "$FM_HOME/../claude-stream.jsonl" 2>&1; echo $? > "$FM_HOME/../claude-exit.txt"; sleep 60' || exit 1
sleep 5
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -S -100 -t primary > "$E/claude-primary-start.txt"
sleep 25
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -S -200 -t primary
printf '\nLab state files:\n'
ls -a "$LAB/state"
printf '\nPersisted lock:\n'
cp "$LAB/state/.lock" "$E/claude-lock.txt"
cat "$LAB/state/.lock"
