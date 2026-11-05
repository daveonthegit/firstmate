#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6N9YDAX193H1GCDWVDY5BN0
D="$ROOT/.live-worker"
mkdir -p "$D"
LAB="$D/host"
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
SOCK=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
cleanup() {
 TMUX_TMPDIR="$SOCK" tmux -L fm-lab kill-server 2>/dev/null || true
 "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" || true
 rm -rf "$D"
}
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export FM_HOME="$LAB" TMUX_TMPDIR="$SOCK" TREEHOUSE_ROOT="$D/pool"
export HOME="$D/user-home" SHELL=/bin/bash
mkdir -p "$HOME"
printf manual > "$LAB/config/backlog-backend"
printf claude > "$LAB/config/crew-harness"
printf tmux > "$LAB/config/backend"
touch "$LAB/.fm-worker-host"
printf '%s\n' $$ > "$LAB/state/.lock"
touch "$LAB/state/.last-watcher-beat"
P="$LAB/projects/sample"
git init -q -b main "$P"
git -C "$P" config user.name 'Live Lab'
git -C "$P" config user.email lab@example.invalid
printf 'disposable sample\n' > "$P/README.md"
git -C "$P" add README.md
git -C "$P" commit -qm initial
git init --bare -q "$D/origin.git"
git -C "$P" remote add origin "$D/origin.git"
git -C "$P" push -qu origin main
git -C "$D/origin.git" symbolic-ref HEAD refs/heads/main
git -C "$P" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
# Private shell session is solely a worker-host endpoint container, not a primary agent.
tmux -L fm-lab -f /dev/null new-session -d -s fm-lab-host -x 120 -y 35 -c "$ROOT" /bin/bash
export TMUX=$(tmux -L fm-lab display-message -p -t fm-lab-host '#{socket_path},#{pid},#{session_id}' | tr -d '$')
C="$ROOT/bin/fm-remote-worker-control.sh"
rm "$LAB/.fm-worker-host"
if "$C" route x; then exit 1; fi
touch "$LAB/.fm-worker-host"
printf markdown > "$LAB/config/backlog-backend"
if "$C" route x; then exit 1; fi
printf manual > "$LAB/config/backlog-backend"
printf '## Captain intent\nInspect this disposable sample only. Do not edit files. Wait for steering.\n' | "$C" spawn live1 sample --mode local-only --yolo off --harness claude > "$E/live-route.txt" 2> "$E/live-spawn.log"
cat "$E/live-route.txt"
"$C" route live1
cp "$LAB/data/live1/brief.md" "$E/live-ship-brief.md"
"$C" state live1
"$C" capture live1 100 > "$E/live-capture.txt"
printf '## Captain intent\nA retried placement\n' | "$C" spawn live1 sample --mode local-only --yolo off --harness claude > "$E/live-route-retry.txt"
test "$(tmux -L fm-lab list-windows -t fm-lab-host -F '#{window_name}' | grep -c fm-live1)" = 1
printf 'sample 1\n' > "$LAB/config/project-capacity"
set +e
printf 'capacity adversary\n' | "$C" spawn deferred sample --mode local-only --yolo off --harness claude
rc=$?
set -e
test "$rc" = 75
test ! -e "$LAB/state/deferred.remote-worker"
test ! -e "$LAB/data/deferred/brief.md"
printf '\nCAPACITY REFUSAL: exit=%s, no claim or brief\n' "$rc"
"$C" send live1 req1 continue
printf continue | "$C" send-stdin live1 req1
python3 - "$LAB" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])/'state/live1.inbox'
a=list(p.glob('*.msg')); assert len(a)==1, a
(p/'handled').mkdir(exist_ok=True)
a[0].rename(p/'handled'/a[0].name)
print('Pending retry: one inbox record; acknowledgement moved to handled/')
PY
"$C" send live1 req1 continue
printf continue | "$C" send-stdin live1 req2
python3 - "$LAB" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])/'state/live1.inbox'
a=list(p.glob('*.msg')); assert len(a)==1, a
b=list((p/'handled').glob('*.msg')); assert len(b)==1, b
print('Acknowledged req1 retry: no new record. New identical req2: one pending record.')
print(a[0].read_text()); print(b[0].read_text())
PY
printf 'live journal\n' > "$LAB/data/live1/journal.md"
"$C" file live1 journal
for args in 'file live1 ../secrets' 'control live1 relaunch' 'route unplaced' 'send live1 --fire-and-forget continue'; do
 set +e; "$C" $args; rc=$?; set -e; test "$rc" != 0
 printf 'REFUSED: %s (exit %s)\n' "$args" "$rc"
done
WT=$(awk -F= '$1=="worktree"{print substr($0,10)}' "$E/live-route.txt")
printf 'unlanded lab change\n' >> "$WT/README.md"
set +e
"$C" teardown live1
rc=$?
set -e
test "$rc" != 0
test -f "$LAB/state/live1.remote-worker"
test -f "$LAB/state/live1.meta"
printf 'UNLANDED WORK: ordinary teardown refused (exit %s), task and claim preserved\n' "$rc"
"$C" control live1 interrupt
# Prove capture propagates failure from a genuinely vanished tmux endpoint.
target=$(awk -F= '$1=="target"{print substr($0,8)}' "$E/live-route.txt")
tmux -L fm-lab kill-window -t "$target"
set +e
"$C" capture live1 100
rc=$?
set -e
test "$rc" != 0
printf 'VANISHED ENDPOINT: capture exit=%s\n' "$rc"
"$C" teardown live1 --force
test ! -e "$LAB/state/live1.meta"
test ! -e "$LAB/state/live1.remote-worker"
printf 'CLEANUP: task record and placement claim removed\n'
rm "$LAB/config/project-capacity"
printf '## Captain intent\nInspect sample only; report observations.\n' | "$C" spawn scout1 sample --scout --journal --harness claude > "$E/live-scout-route.txt" 2> "$E/live-scout-spawn.log"
cp "$LAB/data/scout1/brief.md" "$E/live-scout-brief.md"
cat "$E/live-scout-route.txt"
"$C" teardown scout1 --force
test ! -e "$LAB/state/scout1.remote-worker"
printf 'SCOUT CLEANUP: placement claim removed\n'
