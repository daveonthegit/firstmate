#!/usr/bin/env bash
# Move a T3 Code Claude thread whose last run ended on its seat's usage limit
# to another configured seat, keeping the same thread, transcript, and
# worktree, then steer it once to continue.
# Usage: fm-t3-seat-failover.sh <task-id>
#
# A seat is a provider instance config/t3code-instances names for claude
# (docs/t3code-backend.md "Provider instances and models"). The task must be
# recorded in this home with backend=t3code and harness=claude, and the file
# must name more than one claude seat; anything else is a silent no-op.
#
# One call:
#   1. asks bin/fm-t3-mcp.mjs limit-check whether the thread's latest run ended
#      on a usage limit (that verb owns the evidence rules); a run that did not
#      is a no-op;
#   2. marks the run's seat exhausted (fm_backend_t3code_mark_exhausted), so
#      new launches and later moves pass over it;
#   3. picks the next seat with fm_backend_t3code_instance_choose, excluding
#      that seat, and moves the idle thread there with fm-t3-mcp.mjs configure,
#      which proves the move by reading it back;
#   4. records t3_instance=, t3_failover_result=, t3_failover_run=, and
#      t3_failover_sent= in the task record, then sends one continuation steer
#      through bin/fm-send.sh (a durable steering-inbox record plus doorbell).
#      A failed thread also needs an explicit recovery turn accepted by T3
#      before t3_failover_sent=1; retries reuse the turn's request id.
# Each limited run is moved once. An exhausted verdict is rechecked on later
# calls without renewing that run's exhaustion mark; after a recorded move,
# later calls only finish a continuation not yet recorded as sent.
# The task's lifecycle control lock serializes the check through continuation.
#
# Stdout is one line, `seat-failover: <task> <word> <detail>`, and the exit
# status follows the word:
#   0  none     no usage limit, one seat, not a T3 Claude task, or this run was
#               already handled
#   10 moved    moved to another seat and the continuation recorded as sent
#   3  exhausted every other seat is exhausted, so the thread stays where it
#               is; later checks re-evaluate the alternatives
#   1  failed   the check, the move, or the continuation failed; the next call
#               retries, retaining any recorded move
#   2  usage
# The watcher (bin/fm-watch.sh) and secondmate recovery
# (bin/fm-secondmate-liveness-lib.sh) call this; firstmate may run it by hand.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

[ "$#" -eq 1 ] || { sed -n '5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
ID=$1
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "error: '$ID' is not a task id" >&2; exit 2 ;; esac
META="$STATE/$ID.meta"

report() {  # <word> <detail> <status>
  printf 'seat-failover: %s %s %s\n' "$ID" "$1" "$2"
  exit "$3"
}

CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
META_TMP=
cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fm_lock_acquire_wait "$CONTROL_LOCK"
CONTROL_LOCK_HELD=1
[ -f "$META" ] || report none "no task record" 0
[ "$(fm_backend_of_meta "$META")" = t3code ] || report none "not a T3 Code task" 0
[ "$(fm_meta_get "$META" harness)" = claude ] || report none "not a Claude task" 0
THREAD=$(fm_backend_target_of_meta "$META")
[ -n "$THREAD" ] || report none "no T3 thread recorded" 0
fm_backend_source t3code || report failed "the T3 Code adapter could not be loaded" 1
POOL=$(fm_backend_t3code_instance_pool claude) || report failed "config/t3code-instances is invalid" 1
[ "$(printf '%s\n' "$POOL" | grep -c .)" -gt 1 ] || report none "one Claude seat configured" 0

# meta_put KEY=VALUE...: replace those keys in the task record, atomically
# under its lock.
meta_put() {
  local pair line key skip
  META_LOCK=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$META_LOCK"
  META_LOCK_HELD=1
  META_TMP=$(mktemp "$STATE/.fm-seat-meta.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    skip=0
    for pair in "$@"; do
      key=${pair%%=*}
      case "$line" in "$key="*) skip=1 ;; esac
    done
    [ "$skip" = 1 ] || printf '%s\n' "$line" >> "$META_TMP" || return 1
  done < "$META"
  printf '%s\n' "$@" >> "$META_TMP" || return 1
  { chmod 0600 "$META_TMP" && mv -f -- "$META_TMP" "$META"; } || return 1
  META_TMP=
  fm_lock_release "$META_LOCK"
  META_LOCK_HELD=0
}

continuation() {
  if [ "$(fm_meta_get "$META" kind)" = secondmate ]; then
    printf '%s' "Firstmate recovery: your previous T3 run ended on the usage limit of the Claude seat it ran on, so your thread now runs on seat $1 with the same conversation and home. Re-read your AGENTS.md and your home's config first, since either may have changed while the run was stopped. Then reconcile the work already recorded in your home, report anything your parent needs through your parent channel, then idle as your charter says."
  else
    printf '%s' "Firstmate: your previous turn ended on the usage limit of the Claude seat it ran on, so this thread now runs on seat $1 with the same conversation and worktree. Continue the task from where you stopped."
  fi
}

send_continuation() {  # <seat> <detail>
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$ID" "$(continuation "$1")" >/dev/null \
    || report failed "moved to $1 but the continuation steer was not recorded; the next check resends it" 1
  if [ "$RUN_STATUS" = failed ]; then
    FM_T3CODE_CLIENT_REQUEST_ID="fm-seat-failover-$ID-$RUN" fm_backend_t3code_turn_start "$THREAD" \
      "Firstmate recovery: your Claude seat has changed. Read and act on the pending instructions in your steering inbox before continuing." \
      || report failed "moved to $1 but the recovery turn was not accepted; the next check retries it" 1
  fi
  meta_put t3_failover_sent=1 || report failed "moved to $1 and steered, but the task record could not be updated" 1
  report moved "$2" 10
}

CHECK=$(fm_backend_t3code_mcp limit-check --thread "$THREAD" 2>/dev/null) \
  || report failed "could not read T3 thread $THREAD" 1
# shellcheck disable=SC2016  # ${...} belongs to the Node snippet.
FIELDS=$(printf '%s' "$CHECK" | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
const clean = (v) => String(v ?? "").replace(/[\t\n\r]/g, " ");
process.stdout.write([d.limited === true ? 1 : 0, clean(d.runId), clean(d.instanceId), clean(d.evidence), clean(d.model), clean(d.runStatus)].join("\t"));
') || report failed "unreadable limit check for T3 thread $THREAD" 1
IFS=$'\t' read -r LIMITED RUN FROM EVIDENCE MODEL RUN_STATUS <<< "$FIELDS"
[ "$LIMITED" = 1 ] || report none "latest run did not end on a usage limit" 0
[ -n "$FROM" ] || FROM=$(fm_meta_get "$META" t3_instance)

if [ "$RUN" = "$(fm_meta_get "$META" t3_failover_run)" ] && [ "$(fm_meta_get "$META" t3_failover_result)" != exhausted ]; then
  [ "$(fm_meta_get "$META" t3_failover_sent)" != 1 ] || report none "run $RUN already handled" 0
  send_continuation "$(fm_meta_get "$META" t3_instance)" "continuation resent for $RUN"
fi

if [ "$RUN" != "$(fm_meta_get "$META" t3_failover_run)" ]; then
  [ -z "$FROM" ] || fm_backend_t3code_mark_exhausted "$FROM" || true
fi
[ -n "$MODEL" ] || report failed "could not resolve the model of T3 thread $THREAD" 1
CHOICE=$(fm_backend_t3code_instance_choose claude "$MODEL" "$(fm_meta_get "$META" t3_project_id)" ${FROM:+"$FROM"}) \
  || report failed "could not choose an alternate Claude seat for run $RUN; the next check retries" 1
# shellcheck disable=SC2016  # ${...} belongs to the Node snippet.
CHOICE=$(printf '%s' "$CHOICE" | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
process.stdout.write([d.instance, d.allExhausted ? 1 : 0, d.notes.join("; ").replace(/[\t\n\r]/g, " ")].join("\t"));
') || report failed "unreadable seat choice" 1
IFS=$'\t' read -r TO ALL NOTES <<< "$CHOICE"
if [ "$ALL" = 1 ]; then
  meta_put "t3_failover_run=$RUN" t3_failover_result=exhausted t3_failover_sent=1 || report failed "could not record run $RUN as handled" 1
  report exhausted "run $RUN: every other Claude seat is exhausted too" 3
fi

MOVE=$(fm_backend_t3code_mcp configure --thread "$THREAD" --instance "$TO" 2>&1) \
  || report failed "could not move T3 thread $THREAD from $FROM to $TO: $(printf '%s' "$MOVE" | tail -1)" 1
meta_put "t3_instance=$TO" t3_failover_result=moved "t3_failover_run=$RUN" t3_failover_sent=0 \
  || report failed "moved T3 thread $THREAD to $TO but could not record it" 1
send_continuation "$TO" "from $FROM to $TO after a usage limit ($EVIDENCE); $NOTES"
