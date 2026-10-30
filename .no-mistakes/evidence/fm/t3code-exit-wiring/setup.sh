#!/bin/bash
set -eu
ROOT=$PWD
LAB=$ROOT/.test-t3-live
export FM_HOME=$LAB/home TREEHOUSE_ROOT=$LAB/pool HOME=$LAB/user-home CLAUDE_CONFIG_DIR=$LAB/user-home/.claude
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR"
git init -q --bare "$LAB/origin.git"
git init -q -b main "$FM_HOME/projects/scratch"
git -C "$FM_HOME/projects/scratch" config user.name Test
git -C "$FM_HOME/projects/scratch" config user.email test@example.invalid
printf 'Disposable validation project\n' > "$FM_HOME/projects/scratch/README.md"
git -C "$FM_HOME/projects/scratch" add README.md
git -C "$FM_HOME/projects/scratch" commit -qm initial
git -C "$FM_HOME/projects/scratch" remote add origin "$LAB/origin.git"
git -C "$FM_HOME/projects/scratch" push -qu origin main
git --git-dir="$LAB/origin.git" symbolic-ref HEAD refs/heads/main
"$ROOT/bin/fm-brief.sh" t3live scratch --mode local-only --project "$FM_HOME/projects/scratch"
python3 - <<'PY'
import os
p=os.environ['FM_HOME']+'/data/t3live/brief.md'
s=open(p).read().replace('{TASK}','This is an isolated live stop validation. Do not modify files, run git, or access anything outside this scratch directory. Run sleep 180 in the shell and then reply READY.').replace('{FIRSTMATE_SPEC}','Only execute the sleep requested above; do not implement or deliver any changes. The supervisor will stop this session during the sleep.')
open(p,'w').write(s)
PY
"$ROOT/bin/fm-spawn.sh" t3live "$FM_HOME/projects/scratch" --mode local-only --yolo off --backend t3code --harness claude --model claude-haiku-5-5 --effort default
