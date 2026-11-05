#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB="$ROOT/.l"
EVIDENCE=~/.no-mistakes/evidence/01M6N9YDAX193H1GCDWVDY5BN0
SOCKET="$LAB/t/tmux-$(id -u)/fm-lab"
on_host() {
 env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" CLAUDE_CONFIG_DIR="$ROOT/.worker-validation/claude" DISABLE_AUTOUPDATER=1 TREEHOUSE_ROOT="$LAB/pool" TMUX="$SOCKET,0,0" TMPDIR="$ROOT/.worker-validation/tmp" "$ROOT/bin/fm-remote-worker-control.sh" "$@"
}
expect_refusal() {
 local label=$1; shift
 echo "=== $label ==="
 set +e
 "$@"
 local rc=$?
 set -e
 echo "exit=$rc (expected nonzero)"
 [ "$rc" -ne 0 ]
}
echo '=== Real tmux ship launch and host-local route ==='
printf '## Captain intent\nValidate isolated worker host. Do not change files, credentials or login. Wait for a steer.\n' | on_host spawn live-ship2 sample --mode local-only --yolo off --harness claude --backend tmux --journal
WT=$(on_host route live-ship2 | awk -F= '$1=="worktree" {print substr($0,10)}')
case "$WT" in "$LAB/pool/"*) ;; *) echo "Unsafe worktree $WT"; exit 1 ;; esac
on_host file live-ship2 brief > "$EVIDENCE/host-rendered-brief.md"
echo '=== Duplicate spawn must reuse route without another window ==='
BEFORE=$(tmux -S "$SOCKET" list-windows -t host -F '#{window_id}')
printf 'Same launch retry\n' | on_host spawn live-ship2 sample --mode local-only --yolo off --harness claude
AFTER=$(tmux -S "$SOCKET" list-windows -t host -F '#{window_id}')
[ "$BEFORE" = "$AFTER" ]
on_host state live-ship2
sleep 2
on_host capture live-ship2 40 > "$EVIDENCE/host-real-cli-capture.txt"
echo '=== Capacity-one host defers a second launch without a claim/brief ==='
set +e
printf 'Second task\n' | on_host spawn live-full sample --mode local-only --yolo off --harness claude
RC=$?
set -e
echo "capacity exit=$RC"
[ "$RC" = 75 ]
[ ! -e "$LAB/state/live-full.remote-worker" ] && [ ! -e "$LAB/data/live-full/brief.md" ]
echo '=== Send retry identity at the real persisted inbox interface ==='
on_host send live-ship2 request-A continue
printf continue | on_host send-stdin live-ship2 request-A
[ "$(find "$LAB/state/live-ship2.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ]
echo 'First steer and its immediate retry: one pending message'
# Consume the persisted inbox contract as an external client, without claiming
# that a real model acknowledged it.
mv "$LAB/state/live-ship2.inbox/"*.msg "$LAB/state/live-ship2.inbox/handled/"
on_host send live-ship2 request-A continue
[ "$(find "$LAB/state/live-ship2.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 0 ]
printf continue | on_host send-stdin live-ship2 request-B
on_host send live-ship2 request-C continue
printf 'line one\nline two\n' | on_host send-stdin live-ship2 request-D
[ "$(find "$LAB/state/live-ship2.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 3 ]
echo 'Acknowledged retry: zero new messages; three new request IDs: three pending messages'
for msg in "$LAB/state/live-ship2.inbox/"*.msg "$LAB/state/live-ship2.inbox/handled/"*.msg; do
 echo "--- $(basename "$msg")"; cat "$msg"
done
expect_refusal 'Removed secondmate-only send mode' on_host send live-ship2 --fire-and-forget old-id continue
expect_refusal 'Unclaimed local task cannot be read or steered' on_host state unclaimed
expect_refusal 'Only report/journal/brief may be retrieved' on_host file live-ship2 ../secrets
expect_refusal 'Primary-only relaunch stays refused' on_host control live-ship2 relaunch
printf 'Synthetic local journal\n' > "$LAB/data/live-ship2/journal.md"
on_host file live-ship2 journal
echo '=== Dirty host worktree must survive ordinary teardown ==='
printf 'unlanded validation data\n' > "$WT/unlanded.txt"
expect_refusal 'Refuse discarding uncommitted changes' on_host teardown live-ship2
[ -f "$WT/unlanded.txt" ] && [ -f "$LAB/state/live-ship2.meta" ] && [ -f "$LAB/state/live-ship2.remote-worker" ]
rm "$WT/unlanded.txt"
echo '=== Real terminal output is bounded and endpoint failures propagate ==='
# The controller reads a real tmux pane. Put synthetic output in a separate
# shell pane and point this fixture task at that actual endpoint.
tmux -S "$SOCKET" new-window -d -t host -n capture-proof -c "$LAB" 'bash --noprofile --norc'
cp "$LAB/state/live-ship2.meta" "$LAB/state/live-ship2.meta.saved"
python3 - "$LAB/state/live-ship2.meta" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read(); s='\n'.join('window=host:capture-proof' if x.startswith('window=') else x for x in s.splitlines())+'\n'
open(p,'w').write(s)
PY
tmux -S "$SOCKET" resize-window -t host:capture-proof -x 2000 -y 100
tmux -S "$SOCKET" send-keys -t host:capture-proof "perl -e 'print qq(X)x1900,qq(\\n) for 1..100'" Enter
sleep 2
on_host capture live-ship2 100 > "$EVIDENCE/host-bounded-capture.txt"
SIZE=$(wc -c < "$EVIDENCE/host-bounded-capture.txt" | tr -d ' ')
echo "capture bytes=$SIZE; contract maximum=65536"
[ "$SIZE" = 65536 ]
tmux -S "$SOCKET" kill-window -t host:capture-proof
expect_refusal 'Missing real tmux endpoint propagates capture failure' on_host capture live-ship2 40
mv "$LAB/state/live-ship2.meta.saved" "$LAB/state/live-ship2.meta"
echo '=== Cleanup and scout launch ==='
on_host teardown live-ship2 --force
[ ! -e "$LAB/state/live-ship2.meta" ] && [ ! -e "$LAB/state/live-ship2.remote-worker" ]
expect_refusal 'Route disappears after teardown' on_host route live-ship2
printf 'Inspect the isolated sample only. Do not change files or credentials.\n' | on_host spawn live-scout sample --scout --journal --harness claude --backend tmux
on_host file live-scout brief > "$EVIDENCE/host-scout-brief.md"
on_host route live-scout
on_host teardown live-scout --force
[ ! -e "$LAB/state/live-scout.remote-worker" ]
echo '=== Prepared-home guards ==='
mv "$LAB/.fm-worker-host" "$LAB/.fm-worker-host.saved"
expect_refusal 'Missing host marker' on_host route nonexistent
mv "$LAB/.fm-worker-host.saved" "$LAB/.fm-worker-host"
printf 'markdown\n' > "$LAB/config/backlog-backend"
expect_refusal 'Host must not own an automatic backlog' on_host route nonexistent
printf 'manual\n' > "$LAB/config/backlog-backend"
echo 'ALL LOCAL HOST-LEG SCENARIOS COMPLETED'
