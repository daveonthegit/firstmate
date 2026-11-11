#!/usr/bin/env bash
set -eu
export FM_HOME="$PWD/.live-handoff/home" FM_GH_ACCOUNT=none TREEHOUSE_ROOT="$PWD/.live-handoff/pool"
H="$PWD/bin/fm-handoff.sh"
M="$FM_HOME/state/scout-h1.meta"
cp "$M" .live-handoff/scout-meta.saved
trap 'cp .live-handoff/scout-meta.saved "$M"' EXIT
WT=$(awk -F= '$1=="worktree"{print substr($0,10)}' "$M")
git -C "$WT" checkout -qb fm/scout-h1
git -C "$WT" -c user.name=Lab -c user.email=lab@example.invalid commit --allow-empty -qm 'synthetic carried work'
HEAD=$(git -C "$WT" rev-parse HEAD)
python3 - "$M" <<'PY'
import sys
p=sys.argv[1];s=open(p).read(); s='\n'.join(x for x in s.splitlines() if not x.startswith(('kind=','branch=','mode=','yolo=')))+'\nkind=ship\nbranch=fm/scout-h1\nmode=local-only\nyolo=off\n';open(p,'w').write(s)
PY
check() { local want=$1 needle=$2 out rc=0; shift 2; printf '\n$'; printf ' %q' "$@"; printf '\n'; out=$("$@" 2>&1) || rc=$?; printf '%s\nexit=%s\n' "$out" "$rc"; [ "$rc" = "$want" ] && [[ "$out" == *"$needle"* ]]; }
check 1 "no git remote 'absent'" "$H" scout-h1 --to local --remote absent
check 0 'requested:' "$H" scout-h1 --to local --remote origin
printf 'paused [at=%s]: handoff ready fm/scout-h1 %s\n' "$(date +%s)" "$HEAD" >> "$FM_HOME/state/scout-h1.status"
check 1 'no nonempty notes' "$H" scout-h1 --to local --remote origin
printf 'Synthetic notes: done = carried commit; left = second half; failed = none; verify = inspect commit.\n' > "$FM_HOME/data/scout-h1/handoff-notes.md"
printf 'untracked synthetic WIP\n' > "$WT/untracked-wip.txt"
check 1 'uncommitted changes' "$H" scout-h1 --to local --remote origin
rm "$WT/untracked-wip.txt"
check 1 'ask the worker to push' "$H" scout-h1 --to local --remote origin
[ -e "$M" ] && [ ! -e "$FM_HOME/data/scout-h1-c2/continuation" ]
printf '\nConfirmed: synthetic ship ready lines cannot bypass nonempty notes, untracked-work and preservation checks; the old task remains recorded and no continuation was created.\n'
check 0 'cancelled:' "$H" scout-h1 --to local --cancel
