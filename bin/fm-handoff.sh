#!/usr/bin/env bash
# Hand a running ship or scout off to a fresh thread, on this machine or on
# another: the old worker commits and pushes its work and writes notes, the
# old task is cleaned up through ordinary bin/fm-teardown.sh, and a new task
# continues it from the carried commit through bin/fm-spawn.sh --continue-from.
# Useful for a thread whose context is exhausted, one stuck behind a usage
# limit on one seat, a worker launched on the wrong model, or work that should
# move between the supervisor and a worker host. Firstmate never commits
# inside a project copy, so a worker that cannot answer is a stuck worker to
# recover first.
# Usage: fm-handoff.sh <task-id> --to <local|worker-host-id> --remote <name> [--reason <text>]
#          [--harness <name>] [--model <name>] [--effort <level>] [--account <entry>] [--backend <name>]
#        fm-handoff.sh <task-id> --to <local|worker-host-id> --cancel
#   Run it once to REQUEST the hand-off, then run the same command again after
#   the worker's `paused: handoff ready` line wakes firstmate, to FINISH it.
#   Every run is idempotent: the request lives in data/<task-id>/handoff-request
#   (data/<id>/ outlives cleanup), and a finish that stops part-way resumes on
#   the next run from whichever step has not landed.
#   --to names where the continuation runs: local (this supervisor) or a
#   worker host registered in data/worker-hosts.md. The old task may run here
#   or be placed on a worker host (bin/fm-spawn.sh --host), so a task moves
#   here to a host, from a host back here, between two hosts, or to a fresh
#   thread on the host it is on; the target is recorded with the request and a
#   later run must name the same one. Cross-machine work moves only through a
#   remote both machines reach (Cross-machine hand-offs below).
#   The continuation id uses a -c<n> suffix (`x` -> `x-c2`, `x-c2` -> `x-c3`).
#   --remote must name the preservation remote explicitly on every non-cancel run.
#   Choose origin only for a personal repository at its owner's choice, or
#   fm-rescue for the project's private rescue repository on this machine,
#   which a ship's request creates and adds to its copy on demand
#   (bin/fm-rescue.sh owns that repository and the pruning of its refs).
#   --reason is one line recorded in the request and the handoff document.
#   The launch flags are passed through to bin/fm-spawn.sh unchanged, so the
#   continuation runs on the profile firstmate resolved at this intake (for
#   example another model or seat); flags given at request time are remembered
#   and a later run's flags replace them. --account is refused with a worker
#   host target, whose own home configures accounts.
# Every action, including resumed FINISH and --cancel, refuses before mutation
# when this home is a worker host or has stood down from the supervisor lease.
# REQUEST, which changes nothing but the request record, the worker's inbox,
# and an on-demand fm-rescue remote, refuses when: the task has no record or is
# a second mate; a ship has a recorded PR or a
# Gerrit or external-review forge (H1 limits), no recorded branch, or no such
# remote in its copy (other than fm-rescue; a placed copy's other remote is
# proven at FINISH instead); the task has an open
# decision (answer it first); its brief lacks both `# Task` subsections; the
# continuation id is taken; or the target fails its preflight. A target on the
# machine the task already runs on is not checked for capacity: the old
# worker's place is released by its cleanup before the continuation takes one.
# Another machine must take it now: a worker host target must be registered,
# reachable, have the project cloned, have the continuation id free, and admit
# it (the host leg's `admit`, bin/fm-remote-worker-control.sh, with its own
# bin/fm-capacity.sh --admit); a local target for a placed task needs the
# project cloned in this home's projects/ and this home's own --admit. A target
# that does not admit the task now exits 75 with nothing requested. It then steers the
# worker through bin/fm-send.sh to commit everything (untracked files included)
# as a work-in-progress commit, write data/<task-id>/handoff-notes.md, push its
# branch to the remote, and append `paused: handoff ready <branch> <head>`. A
# scout instead writes its interim report and passes its brief's completion
# gate, because its copy is scratch and cleanup requires both, and appends
# `paused: handoff ready`. Exits 0 once the steer is recorded; a worker that
# cannot be steered (its host unreachable included) is never requested.
# A placed worker is steered through its host (bin/fm-send.sh) and told to
# write its notes, and a scout its report, in its own home on that host.
# FINISH, once that line is in the status log after the request, requires
# nonempty worker notes for ships and scouts, and verifies a ship's copy is clean at <head> on its recorded branch and that <remote> has
# the branch at <head> with its remote-tracking ref containing it (the commits
# then exist outside the copy, which is what lets cleanup accept them), then:
#   1. writes data/<new-id>/continuation (bin/fm-continuation-lib.sh) and
#      data/<new-id>/handoff.md, composed by bin/fm-handoff-compose.sh;
#   2. scaffolds data/<new-id>/brief.md with bin/fm-brief.sh --continue-from,
#      carrying the delivery mode, forge, PR-text owner, branch prefix, base
#      branch, upstream consent, Herdr contract, and journal section;
#   3. files the continuation backlog item, queued, with the old item's title,
#      kind, and repo;
#   4. cleans up the old task with bin/fm-teardown.sh, which closes its item;
#   5. notes "continued as <new-id> on <target>" on that closed item;
#   6. spawns <new-id> with --continue-from and the old task's mode, yolo
#      posture, branch prefix, base branch, and upstream consent.
#   The backlog therefore holds two items in sequence, never two in flight.
#   This deviates from the multi-machine plan's hand-off design, which keeps
#   one item: the backlog's record pairing (bin/fm-backlog-transition-lib.sh)
#   ties every task record to an item of the same id, and that invariant is
#   kept unchanged. A spawn that exits 75 (capacity) leaves the continuation
#   queued with its brief ready, and a later run spawns it.
# Cross-machine hand-offs. The carried branch must be reachable from both
# machines. --remote origin is one such remote; --remote fm-rescue is the
# supervisor's private rescue repository (bin/fm-rescue.sh), which a worker
# host reaches over SSH through config/rescue-ssh: REQUEST adds it to a placed
# copy through the host leg (`rescue`), which also proves the host reaches it,
# and a worker host target gets it with the continuation's spawn. FINISH, for a
# placed task, fetches its notes (and a scout's report) from the host before
# the checks above, verifies the carried work through the host leg
# (`carried`), and for fm-rescue also in the supervisor's own repository
# (`fm-rescue.sh holds`); the document is composed on the host (the leg's
# `handoff` verb), where the old task's copy and T3 thread are; its cleanup is
# the ordinary two-leg one. A continuation that runs here from a placed task
# starts in projects/<project> of this home, which ensure-project gives the
# fm-rescue remote; a continuation on a worker host is placed with
# bin/fm-spawn.sh --host <target> --continue-from.
# --cancel withdraws a request while the old task has not been cleaned up yet
# and tells its worker to resume; it names anything a partial finish left for
# the continuation id.
# Exit codes: 0 requested, handed off, or cancelled; 75 waiting for the worker's ready line,
# or the continuation is deferred by capacity; 1 refused or failed (nothing is
# discarded, and a re-run resumes); 2 usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-continuation-lib.sh
. "$SCRIPT_DIR/fm-continuation-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-task-route-lib.sh
. "$SCRIPT_DIR/fm-task-route-lib.sh"
# shellcheck source=bin/fm-worker-host-lib.sh
. "$SCRIPT_DIR/fm-worker-host-lib.sh"

PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
REQUEST_SCHEMA=fm-handoff-request.v1

die() { echo "error: $*" >&2; exit 1; }

ID=
TO=
NEW_ID=
REMOTE=
REASON=
REASON_SET=0
LAUNCH_KEYS="harness model effort account backend"
LAUNCH_HARNESS=''
LAUNCH_MODEL=''
LAUNCH_EFFORT=''
LAUNCH_ACCOUNT=''
LAUNCH_BACKEND=''
CANCEL=0
launch_value() {  # <key>
  case "$1" in
    harness) printf '%s' "$LAUNCH_HARNESS" ;;
    model) printf '%s' "$LAUNCH_MODEL" ;;
    effort) printf '%s' "$LAUNCH_EFFORT" ;;
    account) printf '%s' "$LAUNCH_ACCOUNT" ;;
    backend) printf '%s' "$LAUNCH_BACKEND" ;;
  esac
}
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$a" in --*) echo "error: --$want requires a value" >&2; exit 2 ;; esac
    case "$want" in
      to) TO=$a ;;
      remote) REMOTE=$a ;;
      reason) REASON=$a; REASON_SET=1 ;;
      harness) LAUNCH_HARNESS=$a ;;
      model) LAUNCH_MODEL=$a ;;
      effort) LAUNCH_EFFORT=$a ;;
      account) LAUNCH_ACCOUNT=$a ;;
      backend) LAUNCH_BACKEND=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --to|--remote|--reason|--harness|--model|--effort|--account|--backend) want=${a#--} ;;
    --cancel) CANCEL=1 ;;
    --*) echo "error: unknown option $a" >&2; exit 2 ;;
    *)
      [ -z "$ID" ] || { echo "error: one task id only" >&2; exit 2; }
      ID=$a
      ;;
  esac
done
[ -z "$want" ] || { echo "error: --$want requires a value" >&2; exit 2; }
[ -n "$ID" ] || { usage >&2; exit 2; }
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id '$ID'" >&2; exit 2; }
case "$TO" in
  '') echo "error: --to <local|worker-host-id> is required" >&2; exit 2 ;;
esac
fm_continuation_target_valid "$TO" || { echo "error: --to $TO is not local or a worker host id" >&2; exit 2; }
REASON=$(printf '%s' "$REASON" | tr '\n\r' '  ')

REQUEST="$DATA/$ID/handoff-request"
META="$STATE/$ID.meta"
STATUS_FILE="$STATE/$ID.status"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# Where the old task runs: local, or its worker host id (read_source).
SRC=local

# --- small readers ----------------------------------------------------------

meta_get() {  # <meta> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

request_get() {  # <key>
  sed -n "s/^$1=//p" "$REQUEST" | tail -n 1
}

default_new_id() {  # <id>
  local id=$1 n
  if printf '%s\n' "$id" | grep -Eq -- '-c[0-9]+$'; then
    n=${id##*-c}
    printf '%s-c%s\n' "${id%-c*}" "$((10#$n + 1))"
  else
    printf '%s-c2\n' "$id"
  fi
}

# Where the old task runs, from its record (SRC); refuses a second mate's route.
read_source() {
  fm_task_route "$META" || die "$FM_TASK_ROUTE_ERROR"
  case "$FM_TASK_ROUTE" in
    local) SRC=local ;;
    worker-host) SRC=$FM_TASK_ROUTE_HOST ;;
    *) die "task $ID is a second mate on another machine; only a ship or scout is handed off" ;;
  esac
}

# The project's clone directory name, from the record or, after cleanup, the request.
project_name() {
  local value
  value=$(meta_get "$META" project)
  [ -n "$value" ] || value=$(meta_get "$META" remote_project)
  if [ -z "$value" ] && [ -f "$REQUEST" ]; then
    value=$(request_get project)
    [ -n "$value" ] || value=$(request_get remote_project)
  fi
  value=${value%/}
  printf '%s\n' "${value##*/}"
}

machine_phrase() {  # <local|worker-host-id>
  if [ "$1" = local ]; then printf 'the supervisor'; else printf 'worker host %s' "$1"; fi
}

# Run one host-leg verb on <host>; output on stdout, exit status passed through.
host_leg() {  # <host> <verb> [args...]
  local host=$1
  shift
  "$SCRIPT_DIR/fm-on.sh" "$host" fm-remote-worker-control.sh "$@"
}

# The target can take the continuation now (header); 75 when it does not admit.
target_preflight() {
  local name rc=0 out
  [ -z "$LAUNCH_ACCOUNT" ] || [ "$TO" = local ] ||
    die "--account is not forwarded to a worker host; its own home configures accounts"
  [ "$TO" != "$SRC" ] || return 0
  name=$(project_name)
  [ -n "$name" ] || die "task $ID records no project"
  if [ "$TO" = local ]; then
    git -C "$PROJECTS/$name" rev-parse --git-dir >/dev/null 2>&1 ||
      die "project $name is not cloned at $PROJECTS/$name, so task $ID cannot continue on the supervisor"
    "$SCRIPT_DIR/fm-capacity.sh" --admit >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) return 0 ;;
      75) echo "not requested: the supervisor does not admit another task now; re-run this command when it has room" >&2; exit 75 ;;
      *) die "could not read the supervisor's admission (fm-capacity.sh --admit exit $rc)" ;;
    esac
  fi
  rc=0
  worker_host_lookup "$DATA" "$TO" || rc=$?
  [ "$rc" -ne 1 ] || die "no worker host '$TO' is registered in $(worker_host_registry_path "$DATA")"
  [ "$rc" -eq 0 ] || die "worker host $TO cannot be resolved: $WORKER_HOST_ERROR"
  rc=0
  out=$(host_leg "$TO" admit "$NEW_ID" "$name" 2>&1) || rc=$?
  case "$rc" in
    0) ;;
    75)
      [ -z "$out" ] || printf '%s\n' "$out" >&2
      echo "not requested: worker host $TO does not admit another task now; re-run this command when it has room" >&2
      exit 75
      ;;
    255) die "worker host $TO is unreachable; nothing was requested" ;;
    *)
      [ -z "$out" ] || printf '%s\n' "$out" >&2
      die "worker host $TO cannot take $NEW_ID on project $name (exit $rc)"
      ;;
  esac
  if [ "$REMOTE" = fm-rescue ] && [ "$(meta_get "$META" kind)" != scout ]; then
    "$SCRIPT_DIR/fm-rescue.sh" host-url "$name" >/dev/null ||
      die "worker host $TO cannot be given the rescue repository; nothing was requested"
  fi
}

# --- request ----------------------------------------------------------------

request_preflight() {
  local kind branch forge open copy
  [ -f "$META" ] || die "task $ID has no record at $META"
  kind=$(meta_get "$META" kind)
  case "${kind:-ship}" in
    ship|scout) ;;
    *) die "task $ID is a ${kind}; only a ship or scout is handed off" ;;
  esac
  read_source
  if [ "${kind:-ship}" = ship ]; then
    [ -z "$(meta_get "$META" pr)" ] ||
      die "task $ID already has a pull request ($(meta_get "$META" pr)); H1 only continues work that has not reached one"
    forge=$(sed -n 's/^Delivery contract: .* forge=\([^ ]*\).*$/\1/p' "$DATA/$ID/brief.md" 2>/dev/null | head -n 1)
    [ -z "$(meta_get "$META" forge)" ] || forge=$(meta_get "$META" forge)
    case "$forge" in
      gerrit|external) die "task $ID publishes through forge=$forge, whose push rules H1 does not handle" ;;
    esac
    branch=$(meta_get "$META" branch)
    [ -n "$branch" ] || die "task $ID records no branch to carry"
    if [ "$SRC" = local ]; then
      copy=$(meta_get "$META" worktree)
      [ "$REMOTE" = fm-rescue ] || git -C "$copy" remote get-url "$REMOTE" >/dev/null 2>&1 ||
        die "task $ID's copy $copy has no git remote '$REMOTE' to carry its branch through; pass --remote"
    fi
  fi
  open=$(status_open_decisions "$STATUS_FILE" "${kind:-ship}")
  [ -z "$open" ] || die "task $ID has an open decision or blocker ($(printf '%s' "$open" | tr '\n' ' ')); answer it before handing the task off"
  if ! fm_brief_task_heading_present "$DATA/$ID/brief.md" "## Captain's intent" ||
    ! fm_brief_task_heading_present "$DATA/$ID/brief.md" "## Firstmate spec"; then
    die "$DATA/$ID/brief.md has no # Task with both ## Captain's intent and ## Firstmate spec for the continuation to carry"
  fi
  new_id_free
  target_preflight
}

new_id_free() {
  [ ! -e "$STATE/$NEW_ID.meta" ] || die "continuation id $NEW_ID already has a task record"
  [ ! -e "$DATA/$NEW_ID/brief.md" ] || die "continuation id $NEW_ID already has a brief"
  [ ! -e "$(fm_continuation_path "$DATA" "$NEW_ID")" ] || die "continuation id $NEW_ID already has a continuation record"
  if fm_backlog_transition_applies "$CONFIG" "$DATA" ship; then
    if fm_backlog_row_probe "$DATA" "$NEW_ID"; then
      die "continuation id $NEW_ID already has a backlog item"
    fi
    [ "$FM_BACKLOG_ROW_RESULT" = not_found ] || die "could not read the backlog before the hand-off ($FM_BACKLOG_ROW_ERROR)"
  fi
  return 0
}

steer_text() {  # <kind>
  local kind=$1 branch copy why='' where data
  [ -z "$REASON" ] || why=" ($REASON)"
  if [ "$TO" = "$SRC" ]; then
    where="a fresh thread on this machine"
  else
    where="a fresh thread on another machine ($(machine_phrase "$TO"))"
  fi
  # A placed worker writes in its own home on its host.
  data=$DATA
  [ "$SRC" = local ] || data="$(meta_get "$META" remote_home)/data"
  if [ "$kind" = scout ]; then
    cat <<EOF
Firstmate is handing this task off to $where$why. Stop your current step at the next safe point and do only this:
1. Write what you have so far to \`$data/$ID/report.md\` as an interim report; say at its top that it is interim and what is left.
2. Pass the completion gate your Definition of done describes for that report exactly as it says, including asking firstmate when a captain call remains.
3. Write \`$data/$ID/handoff-notes.md\` for the next worker: what is done, what is left, what you tried that failed, and how to verify.
4. Append \`$PAUSED_VERB [at=<epoch>]: handoff ready\` to your status file, then stop; firstmate takes it from here.
EOF
    return
  fi
  branch=$(meta_get "$META" branch)
  copy=$(meta_get "$META" worktree)
  [ "$SRC" = local ] || copy=$(meta_get "$META" remote_worktree)
  cat <<EOF
Firstmate is handing this task off to $where$why. Stop your current step at the next safe point and do only this:
1. If a no-mistakes validation run is active for your branch, leave it alone: append \`blocked [at=<epoch>]: handoff refused, validation run active\` and stop.
2. Commit everything in your copy, untracked files included, to your branch \`$branch\` as one work-in-progress commit; skip this when the copy is already clean.
3. Write \`$data/$ID/handoff-notes.md\` for the next worker: what is done, what is left, what you tried that failed, and how to verify.
4. Push your branch: \`git -C $(printf '%q' "$copy") push $REMOTE $branch\`. This one push of your own task branch is authorized for the hand-off; never push the default branch.
5. Append \`$PAUSED_VERB [at=<epoch>]: handoff ready $branch <the full 40-character commit id of your branch head>\` to your status file, then stop; firstmate takes it from here.
EOF
}

write_request() {
  local kind=$1 offset tmp key
  offset=0
  [ ! -f "$STATUS_FILE" ] || offset=$(wc -c < "$STATUS_FILE" | tr -d ' ')
  mkdir -p "$DATA/$ID"
  tmp="$REQUEST.tmp.$$"
  {
    echo "schema=$REQUEST_SCHEMA"
    echo "to=$TO"
    echo "source=$SRC"
    echo "kind=$kind"
    echo "new_id=$NEW_ID"
    echo "remote=$REMOTE"
    echo "reason=$REASON"
    echo "status_offset=$offset"
    echo "requested_at=$(date +%s)"
    for key in $LAUNCH_KEYS; do
      [ -z "$(launch_value "$key")" ] || echo "launch_$key=$(launch_value "$key")"
    done
  } > "$tmp"
  mv -f "$tmp" "$REQUEST"
}

do_request() {
  local kind out
  NEW_ID=$(default_new_id "$ID")
  fm_task_id_creation_valid "$NEW_ID" || die "invalid continuation id '$NEW_ID'"
  [ "$NEW_ID" != "$ID" ] || die "the continuation needs its own task id"
  request_preflight
  kind=$(meta_get "$META" kind)
  kind=${kind:-ship}
  if [ "$kind" = ship ] && [ "$REMOTE" = fm-rescue ]; then
    "$SCRIPT_DIR/fm-rescue.sh" ensure "$ID" || die "could not prepare the rescue remote for $ID; nothing was requested"
  fi
  write_request "$kind"
  if ! out=$("$SCRIPT_DIR/fm-send.sh" "$ID" "$(steer_text "$kind")" 2>&1); then
    rm -f "$REQUEST"
    printf '%s\n' "$out" >&2
    die "could not steer task $ID; nothing was requested"
  fi
  echo "requested: $ID asked to commit, push, and write its notes for continuation as $NEW_ID; re-run this command after its '$PAUSED_VERB: handoff ready' line"
  echo "if the worker cannot answer (stopped, out of context, or out of usage), recover it as a stuck worker first; firstmate never commits inside a project copy"
}

# --- finish -----------------------------------------------------------------

READY_BRANCH=
READY_HEAD=
# Find the worker's last ready line after the request; 1 when there is none yet.
# A ship's line carries "<branch> <head>"; a scout's carries nothing more.
find_ready_line() {
  local offset line verb note found=1
  offset=$(request_get status_offset)
  [ -f "$STATUS_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" verb
    [ "$verb" = "$PAUSED_VERB" ] || continue
    note=$(status_line_note "$line")
    case "$note" in
      'handoff ready'|'handoff ready '*) ;;
      *) continue ;;
    esac
    # shellcheck disable=SC2086 # Deliberate word split of the note's fields.
    set -- $note
    READY_BRANCH=${3:-}
    READY_HEAD=${4:-}
    found=0
  done < <(tail -c +"$((${offset:-0} + 1))" "$STATUS_FILE")
  return "$found"
}

latest_line_after_request() {
  local offset
  offset=$(request_get status_offset)
  [ -f "$STATUS_FILE" ] || return 0
  tail -c +"$((${offset:-0} + 1))" "$STATUS_FILE" | grep . | tail -n 1 || true
}

verify_carried_work() {
  local branch out rc=0
  branch=$(meta_get "$META" branch)
  [ "$READY_BRANCH" = "$branch" ] || die "the ready line names branch '$READY_BRANCH', but task $ID records '$branch'"
  printf '%s\n' "$READY_HEAD" | grep -Eqx '[0-9a-f]{40}' || die "the ready line's head '$READY_HEAD' is not a full commit id; ask the worker to append the line again"
  if [ "$SRC" = local ]; then
    fm_continuation_verify_copy "$(meta_get "$META" worktree)" "$REMOTE" "$branch" "$READY_HEAD" ||
      die "task $ID's copy: $FM_CONT_ERROR"
    return 0
  fi
  out=$(host_leg "$SRC" carried "$ID" "$REMOTE" "$branch" "$READY_HEAD" 2>&1) || rc=$?
  case "$rc" in
    0) ;;
    255) die "worker host $SRC is unreachable, so $ID's carried work cannot be verified; nothing was changed - re-run this command" ;;
    *) printf '%s\n' "$out" >&2; die "worker host $SRC could not verify $ID's carried work (exit $rc)" ;;
  esac
  if [ "$REMOTE" = fm-rescue ]; then
    "$SCRIPT_DIR/fm-rescue.sh" holds "$(project_name)" "$branch" "$READY_HEAD" >/dev/null ||
      die "this supervisor's rescue repository does not hold $ID's carried work; ask the worker to push it"
  fi
}

# Bring a placed task's notes, and a scout's report, into data/<id>/ here.
fetch_from_host() {
  local which rc
  for which in handoff-notes report; do
    [ "$which" = handoff-notes ] || [ "$KIND" = scout ] || continue
    rc=0
    "$SCRIPT_DIR/fm-procevent-remote-worker.sh" fetch "$SRC" "$ID" "$which" || rc=$?
    case "$rc" in
      0|1) ;;
      255) die "worker host $SRC was unreachable while fetching $ID's $which; nothing was changed - re-run this command" ;;
      *) die "$ID's $which from worker host $SRC could not be stored in $DATA/$ID" ;;
    esac
  done
}

write_handoff_doc() {
  local doc="$DATA/$NEW_ID/handoff.md" tmp rc=0
  local -a carried
  [ ! -e "$doc" ] || return 0
  mkdir -p "$DATA/$NEW_ID"
  tmp="$doc.tmp.$$"
  if [ "$SRC" = local ]; then
    "$SCRIPT_DIR/fm-handoff-compose.sh" "$ID" "$NEW_ID" --reason "$REASON" > "$tmp" || rc=$?
  else
    # Composed on the host, where the old copy and thread are (header).
    carried=()
    [ "$FM_CONT_KIND" != ship ] || carried=(--carried "$FM_CONT_REMOTE" "$FM_CONT_BRANCH" "$FM_CONT_HEAD")
    host_leg "$SRC" handoff "$ID" "$NEW_ID" "$TO" "$SRC" --reason "$REASON" \
      "${carried[@]+"${carried[@]}"}" > "$tmp" || rc=$?
    [ "$rc" -ne 255 ] || { rm -f "$tmp"; die "worker host $SRC was unreachable while composing the handoff document; nothing was changed - re-run this command"; }
  fi
  [ "$rc" -eq 0 ] && [ -s "$tmp" ] || { rm -f "$tmp"; die "could not compose the handoff document for $NEW_ID"; }
  mv -f "$tmp" "$doc"
}

scaffold_brief() {
  local brief="$DATA/$NEW_ID/brief.md" old_brief="$DATA/$ID/brief.md" project repo branch prefix mode forge pr consent base
  local -a args
  if [ -e "$brief" ]; then
    fm_brief_continued_from "$brief" | grep -qxF -- "$ID" ||
      die "$brief exists but does not continue $ID"
    return 0
  fi
  repo=$(project_name)
  # The publication gate's lineage check needs a clone on this machine.
  project=$(meta_get "$META" project)
  [ -n "$project" ] || project="$PROJECTS/$repo"
  args=("$NEW_ID" "$repo")
  base=$(meta_get "$META" base_branch)
  if [ "$KIND" = scout ]; then
    args+=(--scout)
  else
    mode=$(meta_get "$META" mode)
    branch=$(meta_get "$META" branch)
    prefix=$(fm_ship_branch_prefix "$branch" "$ID")
    [ "$prefix$ID" = "$branch" ] || die "task $ID's branch $branch does not end in its id, so the continuation's branch prefix is unknown"
    forge=$(sed -n 's/^Delivery contract: .* forge=\([^ ]*\).*$/\1/p' "$old_brief" | head -n 1)
    pr=$(sed -n 's/^Delivery contract: .* pr=\([^ ]*\).*$/\1/p' "$old_brief" | head -n 1)
    consent=$(meta_get "$META" upstream_consent)
    args+=(--mode "$mode" --branch-prefix "$prefix")
    [ ! -d "$project" ] || args+=(--project "$project")
    [ -z "$forge" ] || args+=(--forge "$forge")
    [ -z "$pr" ] || args+=(--pr "$pr")
    [ -z "$consent" ] || args+=(--upstream-consent "$consent")
  fi
  [ -z "$base" ] || args+=(--base-branch "$base")
  ! grep -Fq '# Herdr isolation - HARD SAFETY CONTRACT' "$old_brief" || args+=(--herdr-lab)
  ! fm_brief_heading_present "$old_brief" "# Work journal" || args+=(--journal)
  args+=(--continue-from "$ID")
  "$SCRIPT_DIR/fm-brief.sh" "${args[@]}" >/dev/null || die "could not scaffold the continuation brief"
}

# The continuation's own backlog item, filed before cleanup closes the old one
# (header: two items in sequence).
file_backlog_item() {
  local data out title repo kind body
  fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND" || {
    [ "$?" -ne 2 ] || die "the backlog cannot be read ($FM_BACKLOG_TRANSITION_ERROR)"
    echo "note: this home's backlog is kept by hand; file $NEW_ID as continuing $ID, and note on $ID that it continued as $NEW_ID on $TO"
    return 0
  }
  if fm_backlog_row_probe "$DATA" "$NEW_ID"; then
    fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE" ||
      die "the continuation's backlog item $NEW_ID is not dispatchable ($FM_BACKLOG_ROW_STATE)"
    return 0
  fi
  [ "$FM_BACKLOG_ROW_RESULT" = not_found ] || die "could not read backlog item $NEW_ID ($FM_BACKLOG_ROW_ERROR)"
  title="continues $ID"
  kind=$KIND
  repo=
  data=$(fm_backlog_data_absolute "$DATA") || die "could not resolve the backlog data directory"
  if out=$(fm_backlog_row_show "$data" "$ID"); then
    title=$(printf '%s\n' "$out" | sed -n 's/^  title: *//p' | head -n 1)
    case "$title" in
      \"*\") title=${title#\"}; title=${title%\"}; title=${title//\\\"/\"}; title=${title//\\\\/\\} ;;
    esac
    repo=$(printf '%s\n' "$out" | sed -n 's/^  repo: *//p' | head -n 1)
    case "$repo" in \"-\"|-) repo= ;; esac
    kind=$(printf '%s\n' "$out" | sed -n 's/^  kind: *//p' | head -n 1)
    case "$kind" in \"-\"|-|'') kind=$KIND ;; esac
    [ -n "$title" ] || title="continues $ID"
  fi
  body="Continues $ID in a fresh thread on $TO (bin/fm-handoff.sh). Brief: data/$NEW_ID/brief.md; hand-off: data/$NEW_ID/handoff.md."
  if [ -n "$repo" ]; then
    fm_backlog_mutate "$DATA" add "$NEW_ID" "$title" --kind "$kind" --repo "$repo" --body "$body" --queue
  else
    fm_backlog_mutate "$DATA" add "$NEW_ID" "$title" --kind "$kind" --body "$body" --queue
  fi || die "could not file the continuation's backlog item $NEW_ID ($FM_BACKLOG_TRANSITION_ERROR)"
}

note_old_item() {
  fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND" || return 0
  fm_backlog_row_probe "$DATA" "$ID" || return 0
  case "$FM_BACKLOG_ROW_STATE" in
    done\ *)
      fm_backlog_done "$DATA" "$ID" --note "continued as $NEW_ID on $TO" ||
        echo "warning: could not note on backlog item $ID that it continued as $NEW_ID ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      ;;
    *) echo "note: backlog item $ID is $FM_BACKLOG_ROW_STATE after cleanup, so it was not noted as continued" >&2 ;;
  esac
}

spawn_continuation() {
  local project mode yolo branch prefix base consent key value rc=0 out
  local -a args
  project=$(request_get project)
  if [ "$TO" != local ]; then
    project=$(project_name)
  elif [ "$SRC" != local ]; then
    # A placed task's work continues in this home's own clone (header).
    project="$PROJECTS/$(project_name)"
    if [ "$KIND" = ship ] && [ "$REMOTE" = fm-rescue ]; then
      "$SCRIPT_DIR/fm-rescue.sh" ensure-project "$project" >/dev/null ||
        die "could not give $project the rescue remote; re-run this command"
    fi
  fi
  args=("$NEW_ID" "$project")
  [ "$TO" = local ] || args+=(--host "$TO")
  if [ "$KIND" = scout ]; then
    args+=(--scout)
  else
    mode=$(request_get mode)
    yolo=$(request_get yolo)
    branch=$(request_get branch)
    prefix=$(fm_ship_branch_prefix "$branch" "$ID")
    args+=(--mode "$mode" --yolo "$yolo" --branch-prefix "$prefix")
    consent=$(request_get upstream_consent)
    [ -z "$consent" ] || args+=(--upstream-consent "$consent")
  fi
  base=$(request_get base_branch)
  [ -z "$base" ] || args+=(--base-branch "$base")
  args+=(--continue-from "$ID")
  for key in $LAUNCH_KEYS; do
    value=$(launch_value "$key")
    [ -n "$value" ] || value=$(request_get "launch_$key")
    [ -z "$value" ] || args+=("--$key" "$value")
  done
  [ "$TO" = local ] || [ -z "$(launch_value account)$(request_get launch_account)" ] ||
    die "--account is not forwarded to a worker host; drop it and re-run this command"
  out=$("$SCRIPT_DIR/fm-spawn.sh" "${args[@]}" 2>&1) || rc=$?
  printf '%s\n' "$out"
  case "$rc" in
    0) echo "handed-off: $ID -> $NEW_ID on $TO" ;;
    75)
      echo "deferred: $NEW_ID stays queued with its brief ready; re-run this command to spawn it"
      exit 75
      ;;
    255) die "worker host $TO was unreachable while spawning $NEW_ID; its brief and backlog item are ready - re-run this command, which the host answers with any worker it already launched" ;;
    *) die "spawning $NEW_ID failed; its brief and backlog item are ready, so fix the cause and re-run this command" ;;
  esac
}

# Copy the old task's delivery record into the request before cleanup removes it.
remember_task_record() {
  local key value
  for key in project remote_project mode yolo branch base_branch upstream_consent; do
    grep -q "^$key=" "$REQUEST" && continue
    value=$(meta_get "$META" "$key")
    [ -z "$value" ] || printf '%s=%s\n' "$key" "$value" >> "$REQUEST"
  done
}

do_finish() {
  local recorded key out rc=0
  [ "$(request_get schema)" = "$REQUEST_SCHEMA" ] || die "$REQUEST is not a hand-off request"
  recorded=$(request_get to)
  [ "$TO" = "${recorded:-local}" ] || die "the hand-off of $ID was requested to ${recorded:-local}, not $TO"
  SRC=$(request_get source)
  SRC=${SRC:-local}
  KIND=$(request_get kind)
  recorded=$(request_get new_id)
  NEW_ID=$recorded
  recorded=$(request_get remote)
  [ "$REMOTE" = "$recorded" ] || die "the hand-off of $ID was requested through remote $recorded, not $REMOTE"
  REMOTE=$recorded
  [ "$REASON_SET" -eq 1 ] || REASON=$(request_get reason)
  for key in $LAUNCH_KEYS; do
    [ -n "$(launch_value "$key")" ] || continue
    sed -i.bak "/^launch_$key=/d" "$REQUEST" && rm -f "$REQUEST.bak"
    printf 'launch_%s=%s\n' "$key" "$(launch_value "$key")" >> "$REQUEST"
  done

  if [ -e "$STATE/$NEW_ID.meta" ]; then
    echo "handed-off: $ID -> $NEW_ID on $TO (already done)"
    return 0
  fi
  if [ -f "$META" ]; then
    read_source
    [ "$SRC" = "$(request_get source)" ] || [ -z "$(request_get source)" ] ||
      die "task $ID now runs on $SRC, not where its hand-off was requested; cancel and request again"
    if ! find_ready_line; then
      echo "waiting: $ID has not reported '$PAUSED_VERB: handoff ready' since the request"
      out=$(latest_line_after_request)
      [ -z "$out" ] || echo "latest from $ID: $out"
      exit 75
    fi
    [ "$SRC" = local ] || fetch_from_host
    [ -s "$DATA/$ID/handoff-notes.md" ] || die "task $ID reported ready but wrote no nonempty notes at $DATA/$ID/handoff-notes.md"
    remember_task_record
    if [ "$KIND" = ship ]; then
      verify_carried_work
      fm_continuation_write "$DATA" "$NEW_ID" "$ID" ship "$REMOTE" "$READY_BRANCH" "$READY_HEAD" "$TO" || die "$FM_CONT_ERROR"
    else
      [ -s "$DATA/$ID/report.md" ] || die "scout $ID reported ready but wrote no interim report at $DATA/$ID/report.md"
      fm_continuation_write "$DATA" "$NEW_ID" "$ID" scout '' '' '' "$TO" || die "$FM_CONT_ERROR"
    fi
  fi
  fm_continuation_read "$DATA" "$NEW_ID" "$ID" || die "$FM_CONT_ERROR"
  write_handoff_doc
  if [ -f "$META" ]; then
    scaffold_brief
    file_backlog_item
    out=$("$SCRIPT_DIR/fm-teardown.sh" "$ID" 2>&1) || rc=$?
    printf '%s\n' "$out"
    case "$rc" in
      0|4) ;;
      *) die "cleanup of $ID refused or failed; nothing was discarded, so resolve the cause and re-run this command" ;;
    esac
  fi
  note_old_item
  spawn_continuation
}

# --cancel (header): withdraw a request whose old task has not been cleaned up.
do_cancel() {
  local new_id leftovers=''
  [ -f "$REQUEST" ] || die "task $ID has no hand-off request to cancel"
  [ -f "$META" ] || die "task $ID was already cleaned up for its continuation; finish the hand-off by re-running it without --cancel"
  new_id=$(request_get new_id)
  rm -f "$REQUEST"
  "$SCRIPT_DIR/fm-send.sh" "$ID" "Firstmate cancelled the hand-off of this task. Resume your task where you left it." >/dev/null 2>&1 ||
    echo "warning: could not tell $ID the hand-off is cancelled; steer it yourself" >&2
  [ ! -e "$(fm_continuation_path "$DATA" "$new_id")" ] || leftovers+=" $(fm_continuation_path "$DATA" "$new_id")"
  [ ! -e "$DATA/$new_id/brief.md" ] || leftovers+=" $DATA/$new_id/brief.md"
  echo "cancelled: the hand-off of $ID as $new_id"
  [ -z "$leftovers" ] || echo "note: a partial finish left$leftovers and possibly a queued backlog item $new_id; a new request needs their removal"
}

[ ! -e "$FM_HOME/.fm-worker-host" ] || die "this home is a worker host; only the supervisor hands tasks off"
[ ! -e "$STATE/.supervisor-lease-lost" ] || die "this home has stood down from the supervisor lease ($(head -n 1 "$STATE/.supervisor-lease-lost" 2>/dev/null)); hand-offs need the supervisor"
if [ "$CANCEL" -ne 1 ]; then
  [ -n "$REMOTE" ] || die "--remote is required; explicitly choose the preservation destination"
  fm_continuation_remote_valid "$REMOTE" || die "--remote '$REMOTE' is not a git remote name"
fi

if [ "$CANCEL" -eq 1 ]; then
  do_cancel
elif [ -f "$REQUEST" ]; then
  do_finish
else
  do_request
fi
