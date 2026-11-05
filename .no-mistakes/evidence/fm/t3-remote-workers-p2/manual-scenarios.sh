set -e
show() { printf '\n--- %s ---\n' "$1"; shift; "$@"; }
place t1 ship
place s1 scout
fm_write_meta "$PARENT/state/local.meta" 'kind=ship'
printf 'working [at=1793861000]: compile\n\nnote: control byte \001 normalized\n' > "$HOST/state/t1.status"
printf 'working [at=1793861001]: investigate\nincomplete' > "$HOST/state/s1.status"
capture
show 'Host capture: multiplexed complete lines (synthetic worker logs, real local job worker)' cat "$RESULT"
show 'Primary ingest' primary "$ADAPTER" ingest mbp "$RESULT"
show 'Primary ship stream' cat "$PARENT/state/t1.status"
show 'Primary scout stream (partial line withheld)' cat "$PARENT/state/s1.status"
assert_not_contains "$(cat "$PARENT/state/s1.status")" incomplete 'partial line leaked'
assert_contains "$(cat "$PARENT/state/t1.status")" 'note: control byte ? normalized' 'control normalization failed'
assert_absent "$PARENT/state/local.status" 'local task was touched'
before=$(cat "$PARENT/state/t1.status")
show 'Replay same bundle' primary "$ADAPTER" ingest mbp "$RESULT"
assert_equals "$before" "$(cat "$PARENT/state/t1.status")" 'replay duplicated status'
show 'Primary ship stream after replay (unchanged)' cat "$PARENT/state/t1.status"

mkdir -p "$HOST/data/s1"
printf '# Synthetic scout report\nFinding: use both machines.\n' > "$HOST/data/s1/report.md"
printf '# Synthetic journal\nInvestigation complete.\n' > "$HOST/data/s1/journal.md"
printf ' now complete\ndone [at=1793861002]: findings ready\n' >> "$HOST/state/s1.status"
capture
# Inject an external-boundary transport outage only during document fetching.
cp "$PARENT/state/remote-workers/mbp/s1.cursor" "$TMP_ROOT/before.cursor"
rc=0
FM_FAKE_SSH_DOWN=1 primary "$ADAPTER" ingest mbp "$RESULT" > "$TMP_ROOT/doc-retry.out" 2> "$TMP_ROOT/doc-retry.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'document transport outage was acknowledged'
show "Document transport outage: ingest exit=$rc" cat "$TMP_ROOT/doc-retry.err"
cmp "$TMP_ROOT/before.cursor" "$PARENT/state/remote-workers/mbp/s1.cursor" || fail 'outage advanced cursor'
assert_not_contains "$(cat "$PARENT/state/s1.status")" 'done ' 'done arrived without documents'
show 'Stream during outage: completion withheld' cat "$PARENT/state/s1.status"
show 'Retry same capture after transport restored' primary "$ADAPTER" ingest mbp "$RESULT"
show 'Transferred report' cat "$PARENT/data/s1/report.md"
show 'Transferred journal' cat "$PARENT/data/s1/journal.md"
show 'Completion now visible' cat "$PARENT/state/s1.status"
assert_contains "$(cat "$PARENT/state/s1.status")" 'done [at=1793861002]' 'retry lost completion'
assert_equals "$(cat "$HOST/data/s1/report.md")" "$(cat "$PARENT/data/s1/report.md")" 'report corrupted'

place no-report scout
printf 'done [at=1793861003]: completed without report\n' > "$HOST/state/no-report.status"
capture
show 'Explicit missing-report refusal fails open' primary "$ADAPTER" ingest mbp "$RESULT"
show 'Missing-report stream: completion and unkeyed note' cat "$PARENT/state/no-report.status"
assert_contains "$(cat "$PARENT/state/no-report.status")" 'note: the scout report for no-report did not transfer' 'refusal lacked note'
assert_not_contains "$(cat "$PARENT/state/no-report.status")" '[key=' 'refusal blocked unnecessarily'

printf 'rewritten history\n' > "$HOST/state/t1.status"
printf 'working [at=1793861004]: sibling still active\n' >> "$HOST/state/s1.status"
capture
show 'Continuity failure plus healthy sibling' primary "$ADAPTER" ingest mbp "$RESULT"
show 'Broken task escalation and recovery instructions' cat "$PARENT/state/t1.status"
show 'Healthy sibling still flows' cat "$PARENT/state/s1.status"
assert_present "$PARENT/state/remote-workers/mbp/t1.broken" 'broken task not parked'
assert_contains "$(cat "$PARENT/state/s1.status")" 'sibling still active' 'sibling parked'
# Park remains effective while a sibling changes.
printf 'working [at=1793861005]: next sibling update\n' >> "$HOST/state/s1.status"
capture
primary "$ADAPTER" ingest mbp "$RESULT"
assert_equals 1 "$(grep -c 'key=remote-worker-continuity-t1' "$PARENT/state/t1.status")" 'duplicate continuity escalation'
printf 'working [at=1793861000]: compile\nworking [at=1793861006]: recovered after inspection\n' > "$HOST/state/t1.status"
rm "$PARENT/state/remote-workers/mbp/t1.broken" "$PARENT/state/remote-workers/mbp/t1.cursor"
capture
show 'Recover after removing both marker and cursor' primary "$ADAPTER" ingest mbp "$RESULT"
show 'Recovered stream: original line not duplicated' cat "$PARENT/state/t1.status"
assert_equals 1 "$(grep -c 'working \[at=1793861000\]' "$PARENT/state/t1.status")" 'recovery duplicated old event'
assert_contains "$(cat "$PARENT/state/t1.status")" 'recovered after inspection' 'did not recover'

# Exercise runner capture/auto-ingest/receipt/ack against the real queue.
show 'Register the per-host listener' primary "$ADAPTER" arm mbp
printf 'working [at=1793861007]: autonomous runner update\n' >> "$HOST/state/s1.status"
primary "$ROOT/bin/fm-procevent.sh" start remote-worker-mbp > "$TMP_ROOT/runner.out" 2> "$TMP_ROOT/runner.err" &
RUNNER=$!
for _ in $(seq 1 200); do
  grep -q 'autonomous runner update' "$PARENT/state/s1.status" && break
  sleep 0.1
done
primary "$ROOT/bin/fm-procevent.sh" retire remote-worker-mbp
wait "$RUNNER" || true
assert_equals 1 "$(grep -c 'autonomous runner update' "$PARENT/state/s1.status")" 'runner lost or duplicated event'
show 'Primary stream populated by runner without manual ingest' cat "$PARENT/state/s1.status"
show 'Runner persisted receipt files' ls -a "$PARENT/state/remote-workers/mbp"

# Start a genuine 30s long poll, wait for its running job, then queue a read.
primary env FM_REMOTE_WORKER_WAIT_SECONDS=30 "$ADAPTER" source mbp > "$TMP_ROOT/poll.out" 2> "$TMP_ROOT/poll.err" &
POLL_PID=$!
running=0
for _ in $(seq 1 100); do
  for state in "$TMP_ROOT/remote-jobs/jobs"/*/state; do
    [ -f "$state" ] || continue
    if [ "$(cat "$state")" = running ]; then running=1; break; fi
  done
  [ "$running" -eq 0 ] || break
  sleep 0.1
done
[ "$running" -eq 1 ] || fail 'poll never ran'
started=$SECONDS
show 'Queued document read while status poll is running' primary "$ROOT/bin/fm-on.sh" mbp fm-remote-worker-control.sh file s1 journal
elapsed=$((SECONDS-started))
[ "$elapsed" -lt 15 ] || fail 'control waited behind 30s poll'
rc=0
wait "$POLL_PID" || rc=$?
expect_code 75 "$rc" 'preempted source not empty'
[ ! -s "$TMP_ROOT/poll.out" ] || fail 'preemption fabricated capture'
printf '\n30-second status poll preempted; queued read elapsed=%ss; source exit=%s; capture bytes=0\n' "$elapsed" "$rc"
rc=0
FM_REMOTE_WORKER_WAIT_SECONDS=1 capture || rc=$?
expect_code 75 "$rc" 'quiet window not empty'
printf 'Quiet window source exit=%s; capture bytes=%s\n' "$rc" "$(wc -c < "$RESULT" | tr -d ' ')"
rc=0
FM_FAKE_SSH_DOWN=1 capture || rc=$?
expect_code 255 "$rc" 'outage not exposed'
printf 'Injected transport loss source exit=%s; capture bytes=%s\n' "$rc" "$(wc -c < "$RESULT" | tr -d ' ')"

# A captured event must not change a task removed from primary membership.
printf 'working [at=1793861008]: orphan event\n' >> "$HOST/state/s1.status"
capture
rm "$PARENT/state/s1.meta"
show 'Ingest captured bundle after membership removed' primary "$ADAPTER" ingest mbp "$RESULT"
assert_not_contains "$(cat "$PARENT/state/s1.status")" 'orphan event' 'departed task modified'
show 'Departed task stream excludes orphan event' cat "$PARENT/state/s1.status"
show 'Release first task; other member keeps source' primary "$ADAPTER" retire-task mbp t1
rm "$PARENT/state/t1.meta" "$PARENT/state/no-report.meta"
show 'Release last member; listener retires' primary "$ADAPTER" retire-task mbp no-report
rc=0
FM_REMOTE_WORKER_WAIT_SECONDS=1 capture || rc=$?
expect_code 75 "$rc" 'empty host not quiet'
printf 'No members: source exit=%s; capture bytes=%s\n' "$rc" "$(wc -c < "$RESULT" | tr -d ' ')"
printf '\nCompleted local executable-interface scenarios. SSH itself was a local dispatch shim; no remote Mac or agent login was exercised.\n'
