#!/usr/bin/env bash
# Worker-host status mirror adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-remote-worker.sh arm <worker-host-id>
#   fm-procevent-remote-worker.sh source <worker-host-id>
#   fm-procevent-remote-worker.sh ingest <worker-host-id> <result-file>
#   fm-procevent-remote-worker.sh handle <worker-host-id> <sequence> <result-file>
#   fm-procevent-remote-worker.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-remote-worker.sh members <worker-host-id>
#   fm-procevent-remote-worker.sh retire-task <worker-host-id> <task-id>
#   fm-procevent-remote-worker.sh retire <worker-host-id>
#   fm-procevent-remote-worker.sh classify <result-file>
#   fm-procevent-remote-worker.sh terminal <result-file>
#   fm-procevent-remote-worker.sh self-announcing
#   fm-procevent-remote-worker.sh relisten
#   fm-procevent-remote-worker.sh source-id <worker-host-id>
#
# A ship or scout placed on a worker host (docs/remote-workers.md) appends its
# status lines to its own state/<id>.status in the HOST's home. This adapter
# mirrors them into this primary's state/<id>.status, so every consumer here -
# the watcher's signal scan, the open-decision fold, crew-state, and the PR
# gates - reads one stream exactly as for a local worker.
#
# The members of a host are this home's task records whose meta names it with
# remote_worker_host=<id> and whose kind is ship or scout. One registered
# source per host (remote-worker-<id>) runs bin/fm-remote-worker-events.sh on
# the host with every member's cursor, because the remote job worker serves one
# lane per home and N long polls on one host would fight every steer and state
# read for that lane. That reader is preemptible, so steers are never queued
# behind its window. Each task keeps its own cursor (offset plus prefix digest)
# under state/remote-workers/<id>/, and a captured bundle is split by task id
# and ingested per task:
#   - a delta must continue that task's cursor; a delta already behind the
#     cursor is a replay and is skipped
#   - content-bearing lines are mirrored once per normalized source line, with
#     transport normalization of control bytes and no blank separators, the
#     same contract bin/fm-procevent-remote-reply.sh applies to second mates
#   - before a `done` line is mirrored, the task's journal - and a scout's
#     report - are fetched through bin/fm-remote-worker-control.sh `file` into
#     this home's data/<id>/, so a done line never arrives ahead of its report.
#     A refused scout report fails open with one unkeyed note; a missing
#     journal is silent; an unconfirmed transport (exit 255) leaves the whole
#     capture unhandled for the runner's retry
#   - a continuity break appends one keyed blocked line for that task and
#     parks only that task (state/remote-workers/<id>/<task>.broken), so the
#     host's other tasks keep flowing; removing the marker or the task's
#     cursor after inspection resumes it
# A record for a task that is no longer a member is ignored.
#
# The source answers `relisten` and never reports a capture terminal, so one
# runner keeps polling across empty windows and captures; it is
# `self-announcing`, because every applied line lands in a status stream the
# watcher's signal scan already announces. With no members, `source` waits out
# one window locally and reports it empty instead of calling the host.
# `retire-task` drops one task's cursor and mirror records and retires the
# host's source once it has no members left; task cleanup calls it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CURSOR_ROOT="$STATE/remote-workers"
WAIT_SECONDS=${FM_REMOTE_WORKER_WAIT_SECONDS:-55}
SSH_UNAVAILABLE=255
WINDOW_CLOSED_EMPTY=75
JOB_PREEMPTED=76

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

WORK_TMP=''
cleanup_temp_paths() { rm -rf -- ${WORK_TMP:+"$WORK_TMP"}; }
trap cleanup_temp_paths EXIT

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "no SHA-256 tool is available"
  fi
}
empty_hash() { sha256_file /dev/null; }

validate_host() { case "$1" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid worker host id: $1" ;; esac; }
validate_task() { case "$1" in ''|-*|.*|*[!A-Za-z0-9._-]*) die "invalid task id: $1" ;; esac; }
source_id() { validate_host "$1"; printf 'remote-worker-%s\n' "$1"; }
host_dir() { printf '%s/%s\n' "$CURSOR_ROOT" "$1"; }
cursor_path() { printf '%s/%s.cursor\n' "$(host_dir "$1")" "$2"; }
broken_path() { printf '%s/%s.broken\n' "$(host_dir "$1")" "$2"; }
receipt_path() { printf '%s/.%s.ingested\n' "$(host_dir "$1")" "$2"; }
mirrored_path() { printf '%s/.remote-worker-mirrored-%s\n' "$STATE" "$1"; }
lifecycle_lock() { printf '%s/.remote-worker-lifecycle-%s.lock\n' "$STATE" "$1"; }

meta_value() { # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Every task record in this home placed on <host>, one id per line.
members() { # <host>
  local host=$1 meta id kind
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(meta_value "$meta" remote_worker_host)" = "$host" ] || continue
    kind=$(meta_value "$meta" kind)
    case "${kind:-ship}" in ship|scout) ;; *) continue ;; esac
    id=${meta##*/}
    printf '%s\n' "${id%.meta}"
  done
}

is_member() { # <host> <task>
  members "$1" | grep -Fqx -- "$2"
}

read_cursor() { # <host> <task>; sets CURSOR_OFFSET and CURSOR_HASH
  local path offset hash schema
  path=$(cursor_path "$1" "$2")
  CURSOR_OFFSET=0
  CURSOR_HASH=$(empty_hash)
  [ -e "$path" ] || [ -L "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "worker status cursor is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path")
  offset=$(sed -n 's/^offset=//p' "$path")
  hash=$(sed -n 's/^prefix_sha256=//p' "$path")
  [ "$schema" = fm-remote-worker-cursor.v1 ] || die "worker status cursor has an incompatible schema: $path"
  case "$offset" in ''|*[!0-9]*) die "worker status cursor has an invalid offset: $path" ;; esac
  case "$hash" in ''|*[!a-f0-9]*) die "worker status cursor has an invalid hash: $path" ;; esac
  [ "${#hash}" -eq 64 ] || die "worker status cursor has an invalid hash length: $path"
  CURSOR_OFFSET=$offset
  CURSOR_HASH=$hash
}

write_cursor() { # <host> <task> <offset> <hash>
  local dir path tmp
  dir=$(host_dir "$1")
  mkdir -p "$dir" || return 1
  path=$(cursor_path "$1" "$2")
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.cursor.XXXXXX") || return 1
  printf 'schema=fm-remote-worker-cursor.v1\noffset=%s\nprefix_sha256=%s\n' "$3" "$4" > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

header_field() { # <record-file> <field>: exactly one occurrence before the blank line
  LC_ALL=C awk -v prefix="$2=" '
    $0 == "" { exit }
    index($0, prefix) == 1 { count++; value = substr($0, length(prefix) + 1) }
    END { if (count != 1) exit 1; print value }
  ' "$1"
}

classify_result() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'malformed\n'; return 0; }
  if [ "$(header_field "$file" schema 2>/dev/null || true)" = fm-remote-worker-events.v1 ]; then
    printf 'events\n'
  else
    printf 'malformed\n'
  fi
}

# Split a bundle into one file per record under <dir> (rec.1 .. rec.N), each a
# complete fm-remote-delta.v1 record with its task tag. Refuses a bundle whose
# framing or declared sizes do not hold.
split_bundle() { # <bundle> <dir>
  perl -e '
    my ($bundle, $dir) = @ARGV;
    open(my $in, "<:raw", $bundle) or exit 1;
    local $/; my $data = <$in>; close $in;
    $data =~ s/\A(schema=fm-remote-worker-events\.v1\nrecords=(\d+)\n\n)// or exit 2;
    my $n = $2;
    for my $i (1 .. $n) {
      my $end = index($data, "\n\n");
      exit 3 if $end < 0;
      my $header = substr($data, 0, $end + 2);
      $header =~ /^payload_bytes=(\d+)$/m or exit 4;
      my $bytes = $1;
      exit 5 if length($data) < $end + 2 + $bytes;
      my $record = substr($data, 0, $end + 2 + $bytes);
      $data = substr($data, $end + 2 + $bytes);
      open(my $out, ">:raw", "$dir/rec.$i") or exit 6;
      print {$out} $record or exit 6;
      close $out or exit 6;
    }
    exit 7 if length($data);
    print "$n\n";
  ' "$1" "$2"
}

normalize_payload() { # <source> <destination>
  LC_ALL=C tr '\000-\010\013-\037\177' '?' < "$1" > "$2"
}

append_once() { # <status-file> <line>: 0 appended, 1 present, 2 failed
  if status_event_recorded "$1" "$2"; then return 1; fi
  printf '%s\n' "$(status_stamp_line "$2")" >> "$1" || return 2
  return 0
}

# Fetch one of a task's documents from the host into this home's data/<task>/.
# 0 stored, 1 refused by the host, 2 local storage failed, 255 transport unknown.
FETCH_REASON=''
fetch_doc() { # <host> <task> <report|journal>
  local host=$1 task=$2 which=$3 dir tmp err rc=0
  FETCH_REASON=''
  dir="$DATA/$task"
  mkdir -p "$dir" && [ ! -L "$dir" ] || return 2
  tmp=$(umask 077; mktemp "$dir/.remote-$which.XXXXXX") || return 2
  err=$(mktemp "${TMPDIR:-/tmp}/fm-remote-worker-doc.XXXXXX") || { rm -f -- "$tmp"; return 2; }
  "$SCRIPT_DIR/fm-on.sh" "$host" fm-remote-worker-control.sh file "$task" "$which" \
    < /dev/null > "$tmp" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    FETCH_REASON=$(LC_ALL=C tr '\000-\037\177' ' ' < "$err" | sed 's/^ *//; s/^error: //' | cut -c1-160)
    [ -n "$FETCH_REASON" ] || FETCH_REASON='the host gave no reason'
    rm -f -- "$tmp" "$err"
    [ "$rc" -eq "$SSH_UNAVAILABLE" ] && return "$SSH_UNAVAILABLE"
    return 1
  fi
  rm -f -- "$err"
  [ ! -L "$dir/$which.md" ] || { rm -f -- "$tmp"; return 2; }
  mv -f -- "$tmp" "$dir/$which.md" || { rm -f -- "$tmp"; return 2; }
}

# Ingest one record for <task>. Returns 0 applied or skipped, 3 continuity
# break escalated, and dies on anything that must leave the capture unhandled.
ingest_record() { # <host> <task> <record>
  local host=$1 task=$2 record=$3 rec_status path from to from_hash to_hash payload_hash payload_bytes reason
  local blank payload normalized additions status_file mirrored line kind rc meta
  rec_status=$(header_field "$record" status) || die "record status is ambiguous for $task"
  path=$(header_field "$record" path) || die "record path is ambiguous for $task"
  [ "$path" = "state/$task.status" ] || die "record for $task names the wrong log: $path"
  from=$(header_field "$record" from_offset) || die "record start is ambiguous for $task"
  to=$(header_field "$record" to_offset) || die "record end is ambiguous for $task"
  from_hash=$(header_field "$record" from_prefix_sha256) || die "record start hash is ambiguous for $task"
  to_hash=$(header_field "$record" to_prefix_sha256) || die "record end hash is ambiguous for $task"
  payload_hash=$(header_field "$record" payload_sha256) || die "record payload hash is ambiguous for $task"
  payload_bytes=$(header_field "$record" payload_bytes) || die "record payload size is ambiguous for $task"
  reason=$(header_field "$record" reason) || die "record reason is ambiguous for $task"
  case "$from$to$payload_bytes" in *[!0-9]*) die "record for $task carries a nonnumeric size or offset" ;; esac
  status_file="$STATE/$task.status"
  [ ! -L "$status_file" ] || die "status log for $task is a symlink"
  [ -e "$status_file" ] || (umask 077; : > "$status_file") || die "cannot create the status log for $task"
  read_cursor "$host" "$task"
  if [ "$rec_status" = continuity-broken ]; then
    line="blocked [key=remote-worker-continuity-$task]: worker status continuity broke for $task on worker host $host ($reason) at offset $CURSOR_OFFSET prefix ${CURSOR_HASH:0:12}; mirroring for this task is parked until $(broken_path "$host" "$task") is removed"
    rc=0
    append_once "$status_file" "$line" || rc=$?
    [ "$rc" -ne 2 ] || die "cannot append the continuity escalation for $task"
    if ! mkdir -p "$(host_dir "$host")" || ! : > "$(broken_path "$host" "$task")"; then
      die "cannot park the broken status stream for $task"
    fi
    return 3
  fi
  [ "$rec_status" = delta ] && [ "$payload_bytes" -gt 0 ] || die "record for $task has no payload"
  if [ "$CURSOR_OFFSET" -eq "$to" ] && [ "$CURSOR_HASH" = "$to_hash" ]; then
    return 0
  fi
  if [ "$CURSOR_OFFSET" -gt "$to" ]; then
    return 0
  fi
  [ "$CURSOR_OFFSET" -eq "$from" ] && [ "$CURSOR_HASH" = "$from_hash" ] \
    || die "record does not continue the current cursor for $task"
  blank=$(LC_ALL=C awk '$0 == "" { print NR; exit }' "$record")
  payload="$WORK_TMP/$task.payload"
  tail -n "+$((blank + 1))" "$record" > "$payload"
  [ "$(LC_ALL=C wc -c < "$payload" | tr -d ' ')" -eq "$payload_bytes" ] \
    && [ "$(sha256_file "$payload")" = "$payload_hash" ] \
    || die "record payload for $task does not match its committed digest"
  normalized="$WORK_TMP/$task.normalized"
  normalize_payload "$payload" "$normalized" || die "cannot normalize the payload for $task"
  mirrored=$(mirrored_path "$task")
  [ ! -L "$mirrored" ] || die "mirror record for $task is unsafe"
  [ -e "$mirrored" ] || (umask 077; : > "$mirrored") || die "cannot create the mirror record for $task"
  additions="$WORK_TMP/$task.additions"
  LC_ALL=C awk -v record="$mirrored" -v status_file="$status_file" '
    BEGIN {
      while ((getline l < record) > 0) seen[l] = 1
      close(record)
      while ((getline l < status_file) > 0) present[l] = 1
      close(status_file)
    }
    $0 == "" || ($0 in seen) { next }
    { seen[$0] = 1; if (!($0 in present)) { present[$0] = 1; print } }
  ' "$normalized" > "$additions" || die "cannot stage mirrored lines for $task"
  if grep -Eq '^done([[:space:]:[]|$)' "$additions"; then
    meta="$STATE/$task.meta"
    kind=$(meta_value "$meta" kind)
    rc=0
    fetch_doc "$host" "$task" journal || rc=$?
    [ "$rc" -ne "$SSH_UNAVAILABLE" ] || die "transport to $host was unavailable while fetching the journal for $task"
    [ "$rc" -ne 2 ] || die "could not store the journal for $task"
    if [ "${kind:-ship}" = scout ]; then
      rc=0
      fetch_doc "$host" "$task" report || rc=$?
      [ "$rc" -ne "$SSH_UNAVAILABLE" ] || die "transport to $host was unavailable while fetching the report for $task"
      [ "$rc" -ne 2 ] || die "could not store the report for $task"
      if [ "$rc" -eq 1 ]; then
        printf 'note: the scout report for %s did not transfer from worker host %s - %s\n' \
          "$task" "$host" "$FETCH_REASON" >> "$additions" || die "cannot stage the report note for $task"
      fi
    fi
  fi
  cat "$additions" >> "$status_file" || die "cannot append mirrored lines for $task"
  LC_ALL=C awk '$0 != "" && !s[$0]++' "$normalized" >> "$mirrored" || die "cannot record mirrored lines for $task"
  write_cursor "$host" "$task" "$to" "$to_hash" || die "cannot commit the cursor for $task"
}

cmd_arm() { # <host>
  local host=$1 sid
  validate_host "$host"
  sid=$(source_id "$host")
  mkdir -p "$(host_dir "$host")" || die "cannot create the cursor directory for $host"
  "$SCRIPT_DIR/fm-procevent.sh" register remote-worker "$sid" -- \
    "$SCRIPT_DIR/fm-procevent-remote-worker.sh" source "$host" >/dev/null || return 1
  printf 'armed: %s\n' "$sid"
}

cmd_source() { # <host>
  local host=$1 task cursors output rc=0
  validate_host "$host"
  WORK_TMP=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-remote-worker-src.XXXXXX") || die "cannot stage the source read"
  cursors="$WORK_TMP/cursors"
  output="$WORK_TMP/output"
  : > "$cursors" || die "cannot stage cursors"
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    [ ! -e "$(broken_path "$host" "$task")" ] || continue
    read_cursor "$host" "$task"
    printf '%s %s %s\n' "$task" "$CURSOR_OFFSET" "$CURSOR_HASH" >> "$cursors"
  done < <(members "$host")
  if [ ! -s "$cursors" ]; then
    sleep "$WAIT_SECONDS"
    return "$WINDOW_CLOSED_EMPTY"
  fi
  "$SCRIPT_DIR/fm-on.sh" --stdin "$host" fm-remote-worker-events.sh "$WAIT_SECONDS" \
    < "$cursors" > "$output" || rc=$?
  case "$rc" in
    "$WINDOW_CLOSED_EMPTY"|"$JOB_PREEMPTED") return "$WINDOW_CLOSED_EMPTY" ;;
  esac
  # A failed or non-schema leg never reaches the runner as a capture.
  [ "$rc" -eq 0 ] || return "$rc"
  [ "$(classify_result "$output")" = events ] || return 1
  cat "$output"
}

# Apply one captured bundle: split it and ingest every member's record.
cmd_ingest_locked() { # <host> <result>
  local host=$1 result=$2 count i task record rc broken=0
  validate_host "$host"
  [ "$(classify_result "$result")" = events ] || die "worker status result is malformed"
  WORK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-worker-ingest.XXXXXX") || die "cannot stage ingest"
  mkdir -p "$WORK_TMP/records" || die "cannot stage ingest"
  count=$(split_bundle "$result" "$WORK_TMP/records") || die "worker status bundle framing is invalid"
  i=1
  while [ "$i" -le "$count" ]; do
    record="$WORK_TMP/records/rec.$i"
    i=$((i + 1))
    [ "$(header_field "$record" schema 2>/dev/null)" = fm-remote-delta.v1 ] || die "a bundled record has the wrong schema"
    task=$(header_field "$record" task) || die "a bundled record has no task"
    validate_task "$task"
    is_member "$host" "$task" || continue
    rc=0
    ingest_record "$host" "$task" "$record" || rc=$?
    [ "$rc" -ne 3 ] || broken=$((broken + 1))
  done
  printf 'ingested: %s records=%s broken=%s\n' "$host" "$count" "$broken"
}

# The runner's handling: ingest once per captured generation, then acknowledge.
cmd_handle_locked() { # <host> <seq> <result>
  local host=$1 seq=$2 result=$3 sid receipt hash
  validate_host "$host"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  sid=$(source_id "$host")
  receipt=$(receipt_path "$host" "$seq")
  hash=$(sha256_file "$result")
  if [ -f "$receipt" ] && [ "$(cat "$receipt")" = "$hash" ]; then
    printf 'ingested: %s (already)\n' "$host"
  else
    cmd_ingest_locked "$host" "$result" || return 1
    if ! mkdir -p "$(host_dir "$host")" || ! printf '%s\n' "$hash" > "$receipt"; then
      die "cannot commit the ingest receipt"
    fi
  fi
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null || return 1
}

with_lifecycle_lock() { # <host> <function> <args...>
  local host=$1 lock
  shift
  lock=$(lifecycle_lock "$host")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock the worker status mirror for $host"
    LOCK=$lock
    trap 'cleanup_temp_paths; fm_lock_release "$LOCK"' EXIT
    "$@"
  )
}

cmd_autohandle() { # <source-id> <seq> <result>
  local sid=$1 host
  case "$sid" in remote-worker-?*) host=${sid#remote-worker-} ;; *) die "not a worker host source: $sid" ;; esac
  validate_host "$host"
  with_lifecycle_lock "$host" cmd_handle_locked "$host" "$2" "$3"
}

cmd_retire_task_locked() { # <host> <task>
  local host=$1 task=$2
  rm -f -- "$(cursor_path "$host" "$task")" "$(broken_path "$host" "$task")" "$(mirrored_path "$task")"
  if [ -z "$(members "$host" | grep -vxF -- "$task" || true)" ]; then
    "$SCRIPT_DIR/fm-procevent.sh" retire "$(source_id "$host")" >/dev/null 2>&1 || true
    printf 'retired: %s (no tasks left)\n' "$(source_id "$host")"
  fi
  printf 'released: %s from %s\n' "$task" "$host"
}

case "${1:-}" in
  arm) shift; [ "$#" -eq 1 ] || usage; with_lifecycle_lock "$1" cmd_arm "$1" ;;
  source) shift; [ "$#" -eq 1 ] || usage; cmd_source "$1" ;;
  ingest) shift; [ "$#" -eq 2 ] || usage; validate_host "$1"; with_lifecycle_lock "$1" cmd_ingest_locked "$@" ;;
  handle) shift; [ "$#" -eq 3 ] || usage; validate_host "$1"; with_lifecycle_lock "$1" cmd_handle_locked "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  members) shift; [ "$#" -eq 1 ] || usage; validate_host "$1"; members "$1" ;;
  retire-task) shift; [ "$#" -eq 2 ] || usage; validate_host "$1"; validate_task "$2"; with_lifecycle_lock "$1" cmd_retire_task_locked "$1" "$2" ;;
  retire) shift; [ "$#" -eq 1 ] || usage; "$SCRIPT_DIR/fm-procevent.sh" retire "$(source_id "$1")" ;;
  classify) shift; [ "$#" -eq 1 ] || usage; classify_result "$1" ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; exit 1 ;;
  self-announcing) shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  relisten) shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  source-id) shift; [ "$#" -eq 1 ] || usage; source_id "$1" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
