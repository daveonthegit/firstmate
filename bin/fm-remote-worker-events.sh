#!/usr/bin/env bash
# Blocking, non-destructive status read across every worker a primary placed on
# this worker host (docs/remote-workers.md).
#
# Usage (reached through bin/fm-on.sh --stdin <worker-host-id> on the primary):
#   fm-remote-worker-events.sh [wait-seconds]   # cursors on stdin
#
# stdin carries one cursor per line: `<task-id> <offset> <prefix-sha256>`, the
# primary's committed position in that task's state/<id>.status here. Each
# poll reads every listed task that still holds its state/<id>.remote-worker
# placement claim through the ordinary single-log reader,
# bin/fm-remote-delta-read.sh, with a zero wait, so continuity (offset plus
# prefix digest), whole-line framing, and per-record size bounds keep their
# one owner. A task whose claim is gone is skipped: its record here is retired
# or never existed, and the primary stops listing it at cleanup.
#
# One worker host is one remote home, and the remote job worker serves one
# lane per home, so a single blocking read covers every task on the host
# instead of one long poll per task fighting every steer for that lane. This
# command is in the job worker's preemptible long-poll class
# (bin/fm-remote-job-lib.sh), so a steer, state read, or cleanup queued for
# this home preempts it rather than waiting out the window.
#
# It returns as soon as any listed task has a complete new line or a broken
# continuity, and exits 75 when the window closes with nothing to report.
# Output is one bundle:
#   schema=fm-remote-worker-events.v1
#   records=<n>
#   <blank line>
# followed by <n> fm-remote-delta.v1 records, each exactly as
# fm-remote-delta-read.sh prints it with one `task=<id>` line added after its
# schema line. A record's header ends at its blank line and its payload is
# exactly payload_bytes long. Records stop being added once their payloads
# total FM_REMOTE_WORKER_EVENTS_MAX_BYTES (default 524288), so one bundle stays
# well inside the job transport's 1 MiB stdout bound; a task left out is read
# again on the next call from its unchanged cursor.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME is required}
STATE="$FM_HOME/state"
POLL_SECONDS=${FM_REMOTE_WORKER_EVENTS_POLL_SECONDS:-1}
MAX_TOTAL=${FM_REMOTE_WORKER_EVENTS_MAX_BYTES:-524288}
MAX_TASKS=256

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -le 1 ] || usage
case "${1:-}" in -h|--help) usage ;; esac
WAIT=${1:-55}
case "$WAIT" in ''|*[!0-9]*) die "wait-seconds must be a nonnegative integer" ;; esac
[ "$WAIT" -le 300 ] || die "wait-seconds exceeds the 300-second safety bound"
case "$MAX_TOTAL" in ''|*[!0-9]*|0) die "FM_REMOTE_WORKER_EVENTS_MAX_BYTES must be a positive integer" ;; esac
[ "$MAX_TOTAL" -le 786432 ] || die "FM_REMOTE_WORKER_EVENTS_MAX_BYTES exceeds the safety bound"
[ -f "$FM_HOME/.fm-worker-host" ] && [ ! -L "$FM_HOME/.fm-worker-host" ] \
  || die "$FM_HOME is not a worker host home: it has no .fm-worker-host marker"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-worker-events.XXXXXX") || die "cannot create staging directory"
trap 'rm -rf -- "$TMP"' EXIT
trap 'exit 75' TERM

TASKS=()
OFFSETS=()
HASHES=()
while IFS=' ' read -r task offset hash extra || [ -n "${task:-}" ]; do
  [ -n "${task:-}" ] || continue
  [ -z "${extra:-}" ] || die "a cursor line has extra fields: $task"
  case "$task" in -*|.*|*[!A-Za-z0-9._-]*) die "invalid task id in cursor: $task" ;; esac
  case "${offset:-}" in ''|*[!0-9]*) die "invalid offset for $task" ;; esac
  case "${hash:-}" in ''|*[!A-Fa-f0-9]*) die "invalid prefix digest for $task" ;; esac
  [ "${#hash}" -eq 64 ] || die "invalid prefix digest length for $task"
  TASKS+=("$task")
  OFFSETS+=("$offset")
  HASHES+=("$hash")
  [ "${#TASKS[@]}" -le "$MAX_TASKS" ] || die "more than $MAX_TASKS cursors in one read"
done

START=$SECONDS
while :; do
  count=0
  total=0
  : > "$TMP/records"
  i=0
  while [ "$i" -lt "${#TASKS[@]}" ]; do
    task=${TASKS[$i]}
    claim="$STATE/$task.remote-worker"
    if [ -f "$claim" ] && [ ! -L "$claim" ]; then
      rc=0
      FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-remote-delta-read.sh" "state/$task.status" \
        "${OFFSETS[$i]}" "${HASHES[$i]}" 0 > "$TMP/one" 2> "$TMP/one.err" || rc=$?
      if [ "$rc" -eq 0 ] && [ -s "$TMP/one" ]; then
        bytes=$(sed -n 's/^payload_bytes=//p' "$TMP/one" | head -1)
        case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
        if [ "$count" -gt 0 ] && [ $((total + bytes)) -gt "$MAX_TOTAL" ]; then
          break
        fi
        # Insert the task tag after the schema line; the payload is untouched.
        { head -n 1 "$TMP/one"; printf 'task=%s\n' "$task"; tail -n +2 "$TMP/one"; } >> "$TMP/records"
        count=$((count + 1))
        total=$((total + bytes))
      elif [ "$rc" -ne 75 ]; then
        cat "$TMP/one.err" >&2
        die "status read for $task failed"
      fi
    fi
    i=$((i + 1))
  done
  if [ "$count" -gt 0 ]; then
    printf 'schema=fm-remote-worker-events.v1\nrecords=%s\n\n' "$count"
    cat "$TMP/records"
    exit 0
  fi
  [ $((SECONDS - START)) -lt "$WAIT" ] || exit 75
  sleep "$POLL_SECONDS"
done
