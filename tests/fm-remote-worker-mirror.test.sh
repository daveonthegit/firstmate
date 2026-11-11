#!/usr/bin/env bash
# tests/fm-remote-worker-mirror.test.sh - the per-host status mirror for
# workers placed on a worker host (docs/remote-workers.md). The primary's
# adapter (bin/fm-procevent-remote-worker.sh) reads every placed task's status
# log on the host in one call through fm-on, the real fixed entrypoint, the
# real remote job worker, and bin/fm-remote-worker-events.sh, then splits the
# bundle into each task's own status stream on the primary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-worker-mirror)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
HOST="$TMP_ROOT/host"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
ADAPTER="$ROOT/bin/fm-procevent-remote-worker.sh"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$HOST/state" "$HOST/data" "$HOST/config" "$CLAIMS"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/worker-hosts.md" <<EOF
- mbp - spare MacBook worker host (host: remote-mac; root: $ROOT; home: $HOST; added 2026-11-05)
EOF
: > "$HOST/.fm-worker-host"
printf 'manual\n' > "$HOST/config/backlog-backend"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "${FM_FAKE_SSH_DOWN:-}" != 1 ] || exit 255
[ "$1" = remote-mac ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

primary() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_WORKER_WAIT_SECONDS="${FM_REMOTE_WORKER_WAIT_SECONDS:-3}" \
  "$@"
}

place() { # <task> <kind>: a placed task on both sides
  : > "$HOST/state/$1.remote-worker"
  fm_write_meta "$PARENT/state/$1.meta" "kind=$2" "remote_worker_host=mbp" \
    "remote_root=$ROOT" "remote_home=$HOST"
}

SEQ=0
capture() { # -> sets RESULT; returns the source's exit status
  local rc=0
  SEQ=$((SEQ + 1))
  RESULT="$TMP_ROOT/result.$SEQ"
  primary "$ADAPTER" source mbp > "$RESULT" 2>"$TMP_ROOT/source.err" || rc=$?
  return "$rc"
}

fm_remote_job_command_preemptible fm-remote-worker-events.sh \
  || fail "the host status read is not in the job worker's preemptible long-poll class"
! fm_remote_job_command_preemptible fm-remote-worker-control.sh \
  || fail "the host control leg must never be preempted"
pass "the host status read yields its lane to steers, state reads, and cleanup"

place t1 ship
place s1 scout
fm_write_meta "$PARENT/state/local.meta" "kind=ship"
fm_write_meta "$PARENT/state/contradictory.meta" "kind=ship" "remote_worker_host=mbp" "remote_host=other"
fm_write_meta "$PARENT/state/unsafe.meta" "kind=scout" "remote_worker_host=../mbp"
out=$(primary "$ADAPTER" members mbp | sort | tr '\n' ' ')
assert_equals "s1 t1 " "$out" "members are the task records placed on that host"
pass "a host's members are this home's ship and scout records that name it"

out=$(primary "$ADAPTER" arm mbp) || fail "arm failed: $out"
assert_contains "$out" "armed: remote-worker-mbp" "arm did not register the host source"

printf 'working [at=1793860000]: setup done\n' >> "$HOST/state/t1.status"
printf 'working [at=1793860001]: scouting\npartial line' >> "$HOST/state/s1.status"
capture || fail "the first status read failed: $(cat "$TMP_ROOT/source.err")"
assert_equals events "$(primary "$ADAPTER" classify "$RESULT")" "the bundle was not classified as events"
out=$(primary "$ADAPTER" ingest mbp "$RESULT") || fail "handle failed: $out"
assert_contains "$(cat "$PARENT/state/t1.status")" "working [at=1793860000]: setup done" "t1's line was not mirrored"
assert_contains "$(cat "$PARENT/state/s1.status")" "working [at=1793860001]: scouting" "s1's line was not mirrored"
assert_not_contains "$(cat "$PARENT/state/s1.status")" "partial line" "an incomplete line was mirrored"
assert_absent "$PARENT/state/local.status" "a local task received mirrored lines"
pass "one host read mirrors each placed task's complete lines into its own status stream"

before=$(cat "$PARENT/state/t1.status")
out=$(primary "$ADAPTER" ingest mbp "$RESULT") || fail "a repeated handle failed: $out"
assert_equals "$before" "$(cat "$PARENT/state/t1.status")" "a repeated handle appended again"
pass "ingesting the same capture twice appends nothing"

printf ' finished\n' >> "$HOST/state/s1.status"
mkdir -p "$HOST/data/s1" "$HOST/data/t1"
printf '# Scout findings\n' > "$HOST/data/s1/report.md"
printf 'journal for s1\n' > "$HOST/data/s1/journal.md"
printf 'done [at=1793860002]: report written\n' >> "$HOST/state/s1.status"
capture || fail "the second status read failed: $(cat "$TMP_ROOT/source.err")"
out=$(primary "$ADAPTER" ingest mbp "$RESULT") || fail "handle of the done line failed: $out"
assert_contains "$(cat "$PARENT/state/s1.status")" "partial line finished" "the completed line was not mirrored"
assert_contains "$(cat "$PARENT/state/s1.status")" "done [at=1793860002]: report written" "the done line was not mirrored"
assert_equals "# Scout findings" "$(cat "$PARENT/data/s1/report.md")" "the scout report was not fetched"
assert_equals "journal for s1" "$(cat "$PARENT/data/s1/journal.md")" "the journal was not fetched"
assert_equals 1 "$(grep -c 'working \[at=1793860000\]' "$PARENT/state/t1.status")" "an unchanged task was mirrored again"
pass "a done line arrives with the task's report and journal fetched first"

printf 'done [at=1793860003]: PR https://example.invalid/pull/1 checks green\n' >> "$HOST/state/t1.status"
capture || fail "the third status read failed: $(cat "$TMP_ROOT/source.err")"
out=$(primary "$ADAPTER" ingest mbp "$RESULT") || fail "handle of a ship done without a journal failed: $out"
assert_contains "$(cat "$PARENT/state/t1.status")" "checks green" "the ship done line was not mirrored"
assert_absent "$PARENT/data/t1/journal.md" "a missing journal produced a local file"
assert_not_contains "$(cat "$PARENT/state/t1.status")" "note:" "a missing ship journal produced a note"
pass "a ship done line without a journal mirrors quietly"

# The process-event runner itself captures, autohandles, and acknowledges.
printf 'working [at=1793860010]: runner line\n' >> "$HOST/state/s1.status"
primary "$ROOT/bin/fm-procevent.sh" start remote-worker-mbp >/dev/null 2>&1 &
RUNNER=$!
for _ in $(seq 1 300); do
  grep -q 'runner line' "$PARENT/state/s1.status" 2>/dev/null && break
  sleep 0.1
done
primary "$ROOT/bin/fm-procevent.sh" retire remote-worker-mbp >/dev/null 2>&1 || true
wait "$RUNNER" 2>/dev/null || true
assert_contains "$(cat "$PARENT/state/s1.status")" "runner line" "the runner did not mirror the line"
assert_equals 1 "$(grep -c 'runner line' "$PARENT/state/s1.status")" "the runner mirrored a line twice"
[ -n "$(find "$PARENT/state/remote-workers/mbp" -name '.*.ingested' 2>/dev/null)" ] \
  || fail "the runner's capture left no ingest receipt"
pass "the process-event runner captures, applies, and acknowledges a host bundle"

rc=0
FM_REMOTE_WORKER_WAIT_SECONDS=1 capture || rc=$?
expect_code 75 "$rc" "a quiet window must report an empty read"
assert_equals "" "$(cat "$RESULT")" "an empty window printed a capture"
pass "a quiet host window is an empty read, not a capture"

# A real queued host operation must preempt an already-running status poll,
# not merely be classified as eligible for preemption.
primary env FM_REMOTE_WORKER_WAIT_SECONDS=30 "$ADAPTER" source mbp \
  > "$TMP_ROOT/preempt.result" 2> "$TMP_ROOT/preempt.err" &
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
[ "$running" -eq 1 ] || fail "the long status poll never started"
started=$SECONDS
out=$(primary "$ROOT/bin/fm-on.sh" mbp fm-remote-worker-control.sh file s1 journal) \
  || fail "the queued document read failed: $out"
assert_equals "journal for s1" "$out" "the queued read returned the wrong document"
[ $((SECONDS - started)) -lt 15 ] || fail "the queued operation waited behind the 30-second poll"
rc=0
wait "$POLL_PID" || rc=$?
expect_code 75 "$rc" "the preempted source must become an empty window"
assert_equals "" "$(cat "$TMP_ROOT/preempt.result")" "a preempted poll produced a capture"
pass "a queued host operation preempts a running status poll without waiting out its window"

rc=0
FM_FAKE_SSH_DOWN=1 capture || rc=$?
expect_code 255 "$rc" "an unreachable host must pass its transport status through"
assert_equals "" "$(cat "$RESULT")" "an unreachable host produced a capture"
pass "an unreachable host produces no capture"

# A rewritten host log breaks only that task's continuity.
printf 'rewritten history\n' > "$HOST/state/t1.status"
printf 'working [at=1793860004]: still going\n' >> "$HOST/state/s1.status"
capture || fail "the continuity read failed: $(cat "$TMP_ROOT/source.err")"
out=$(primary "$ADAPTER" ingest mbp "$RESULT") || fail "handle of a break failed: $out"
assert_contains "$(cat "$PARENT/state/t1.status")" "blocked [key=" "the break was not escalated"
assert_contains "$(cat "$PARENT/state/t1.status")" "key=remote-worker-continuity-t1" "the break escalation is not keyed"
assert_contains "$(cat "$PARENT/state/s1.status")" "still going" "a sibling task stopped flowing after a break"
assert_present "$PARENT/state/remote-workers/mbp/t1.broken" "the broken task was not parked"
printf 'working [at=1793860005]: more\n' >> "$HOST/state/s1.status"
capture || fail "the post-break read failed: $(cat "$TMP_ROOT/source.err")"
out=$(primary "$ADAPTER" ingest mbp "$RESULT") || fail "handle after a break failed: $out"
assert_equals 1 "$(grep -c 'remote-worker-continuity-t1' "$PARENT/state/t1.status")" "a parked task escalated again"
pass "a broken log escalates once and parks only that task"

# Follow the operator recovery contract emitted by the adapter: remove BOTH
# the parked marker and cursor. Retained mirror records prevent duplicates
# when the host's inspected history is read again from zero.
printf 'working [at=1793860000]: setup done\nworking [at=1793860020]: recovered\n' > "$HOST/state/t1.status"
rm -f "$PARENT/state/remote-workers/mbp/t1.broken" "$PARENT/state/remote-workers/mbp/t1.cursor"
capture || fail "the recovery read failed: $(cat "$TMP_ROOT/source.err")"
out=$(primary "$ADAPTER" ingest mbp "$RESULT") || fail "recovery ingest failed: $out"
assert_contains "$(cat "$PARENT/state/t1.status")" "recovered" "the reset task did not resume mirroring"
assert_equals 1 "$(grep -c 'working \[at=1793860000\]' "$PARENT/state/t1.status")" "recovery duplicated a previously mirrored line"
assert_absent "$PARENT/state/remote-workers/mbp/t1.broken" "the recovered task is still parked"
assert_present "$PARENT/state/remote-workers/mbp/t1.cursor" "recovery did not commit a new cursor"
pass "removing the broken marker and cursor resumes mirroring without duplicate lines"

# A record for a task this home no longer holds is ignored.
rm -f "$PARENT/state/s1.meta"
printf 'working [at=1793860006]: orphan line\n' >> "$HOST/state/s1.status"
fm_write_meta "$PARENT/state/s1.meta" "kind=scout" "remote_worker_host=mbp"
capture || fail "the membership read failed: $(cat "$TMP_ROOT/source.err")"
rm -f "$PARENT/state/s1.meta"
out=$(primary "$ADAPTER" ingest mbp "$RESULT") || fail "handle with a departed member failed: $out"
assert_not_contains "$(cat "$PARENT/state/s1.status")" "orphan line" "a departed task's record was mirrored"
pass "a record for a task no longer placed from this home is ignored"

fm_write_meta "$PARENT/state/s1.meta" "kind=scout" "remote_worker_host=mbp"
out=$(primary "$ADAPTER" retire-task mbp t1) || fail "retire-task failed: $out"
assert_absent "$PARENT/state/remote-workers/mbp/t1.cursor" "retire-task left the cursor"
assert_not_contains "$out" "no tasks left" "the source was retired while a member remained"
rm -f "$PARENT/state/t1.meta"
rm -f "$PARENT/state/s1.meta"
out=$(primary "$ADAPTER" retire-task mbp s1) || fail "the last retire-task failed: $out"
assert_contains "$out" "retired: remote-worker-mbp" "the host source outlived its last member"
pass "releasing tasks keeps the host source until its last member leaves"

rc=0
FM_REMOTE_WORKER_WAIT_SECONDS=1 capture || rc=$?
expect_code 75 "$rc" "a host with no members must report an empty read"
pass "a host with no members waits locally and reports an empty read"

echo "all fm-remote-worker-mirror tests passed"
