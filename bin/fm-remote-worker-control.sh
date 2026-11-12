#!/usr/bin/env bash
# Host-local leg for ship and scout workers a primary places on a worker host.
#
# Usage (reached through bin/fm-on.sh <worker-host-id> on the primary):
#   fm-remote-worker-control.sh spawn <task-id> <project> [--scout] [flags...]  # # Task body on stdin
#   fm-remote-worker-control.sh route <task-id>
#   fm-remote-worker-control.sh state <task-id>
#   fm-remote-worker-control.sh send <task-id> <delivery-id> <message>
#   fm-remote-worker-control.sh send-stdin <task-id> <delivery-id>  # message on stdin
#   fm-remote-worker-control.sh control <task-id> {interrupt|exit}
#   fm-remote-worker-control.sh answer <task-id> [<request-id> <answers-json>]
#   fm-remote-worker-control.sh capture <task-id> [lines]
#   fm-remote-worker-control.sh file <task-id> {report|journal|brief|handoff-notes}
#   fm-remote-worker-control.sh teardown <task-id> [--force]
#   fm-remote-worker-control.sh named-head <task-id> <done-line>
#   fm-remote-worker-control.sh admit <task-id> <project>
#   fm-remote-worker-control.sh rescue <task-id> <url>
#   fm-remote-worker-control.sh carried <task-id> <remote> <branch> <head>
#   fm-remote-worker-control.sh handoff <task-id> <new-id> <to> <ran-on> [--reason <text>] [--carried <remote> <branch> <head>]
#   fm-remote-worker-control.sh stage <new-id> <old-id> {handoff|report}  # content on stdin
#
# A worker host runs a headless Firstmate home: no firstmate or secondmate
# agent, only the workers a primary places there (docs/remote-workers.md). The
# primary keeps the task record, backlog, brief, and every decision; this home
# keeps an ordinary local task record for the same task id, so every verb here
# is the ORDINARY local script run against this home - fm-spawn, fm-crew-state,
# fm-send, fm-control, fm-t3-answer, fm-peek, fm-remote-file, fm-teardown - and
# none of them is reimplemented. The worker runs on whatever backend this
# home's own config/backend selects unless the primary passes --backend.
#
# The home must carry the .fm-worker-host marker at its root, must not also be
# a secondmate home, and must select config/backlog-backend=manual: the
# primary's backlog is the only backlog that owns these tasks, so the host's
# spawn and teardown make no backlog transition. Every per-task verb other
# than spawn also requires the task's state/<id>.remote-worker claim, so only
# tasks a primary placed here are addressable through this leg.
#
# spawn re-renders the brief HERE with this host's bin/fm-brief.sh, so every
# path a worker is told (status file, steering inbox, report, journal) is this
# home's, then replaces the scaffold's `# Task` section with the primary's
# `# Task` body read from stdin. Only that section crosses the machine
# boundary; the primary forwards the scaffold-shaping facts as flags:
#   --scout                      scout instead of ship
#   --mode <m> --yolo <on|off>   ship delivery contract (both required on a ship)
#   --branch-prefix <p>          ship branch prefix
#   --base-branch <b>            start and target branch
#   --upstream-consent <scope>   one-task upstream contribution consent
#   --forge <f> [--shape <s>] [--pr <auto|manual>]  the project's forge binding
#   --herdr-lab                  the Herdr isolation contract
#   --journal                    include the work-journal section
#   --harness <h> --model <m> --effort <e> --backend <b>  launch profile
#   --continue-from <old-id>     continue <old-id> (bin/fm-handoff.sh --to <host>)
#   --carried-remote <r> --carried-branch <b> --carried-head <sha>  a ship's carried work
#   --rescue-url <url>           the supervisor's rescue repository, as `fm-rescue`
# A continuation needs its hand-off document staged first (`stage ... handoff`
# below). Its spawn writes this home's own continuation record, naming `to`
# local (bin/fm-continuation-lib.sh), adds the rescue remote to the project
# clone when a URL is given (refusing another URL already named fm-rescue),
# and renders the brief with --continue-from, its Task taken from the
# primary's body (bin/fm-brief.sh --continue-source); this home's fm-spawn
# then plants the copy at the carried commit as for a local continuation.
# This host's fm-spawn then re-validates the brief against this home's own
# data/projects.md, capacity declarations, and backend, exactly as for a local
# spawn; its `deferred:` line and exit 75 pass through unchanged, and nothing
# is left behind. A spawn for a task this home already holds with a claim is
# idempotent: it prints the existing route instead of launching twice, which is
# what makes a re-run after an unconfirmed SSH spawn (exit 255) safe.
#
# spawn and route print one route block the primary records:
#   schema=fm-remote-worker-control.v1
#   task=<id> kind=<ship|scout> backend=<b> target=<t> worktree=<path>
#   project=<path> harness=<h> model=<m> effort=<e> mode=<m> yolo=<y>
#   branch=<b> base_branch=<b> (when recorded)
# one key=value per line.
#
# send and send-stdin require a primary-minted unique delivery id for each new
# steer, even when its text repeats. Reuse the id and exact message only for a
# retry of that immutable request after an ambiguous transport failure.
# FM_SEND_IDEMPOTENT=1 deduplicates the correlation-marked body against pending
# and acknowledged inbox records. teardown runs the full ordinary fm-teardown
# here - landed-work test,
# endpoint close, process reaper, worktree return - and removes the claim only
# once that task record is gone. A teardown for a task that has neither a
# claim nor a record here reports that no task record remains and succeeds,
# so the primary can re-run its cleanup after an unconfirmed answer (exit 255)
# without this home inventing work; a record without a claim still refuses.
#
# named-head runs bin/fm-dod-lib.sh's named-head gate (fm_dod_accept_ship_done)
# over this home's own record for the task - its kind, mode, worktree, project,
# and forge - against the single <done-line> the primary is asked to accept, so
# a head that exists only in this disposable copy is refused here exactly as a
# local one is. It prints `accepted: <id>` and exits 0, or prints
# `refused: <reason>` and exits 1, including for a task this home holds no
# claimed record for; every other answer is no verdict, and the
# primary's fm_dod_accept_placed_done owns treating it as cannot-verify-now.
#
# The hand-off verbs serve bin/fm-handoff.sh on the primary:
#   admit    preflight for a continuation placed here: the home is a worker
#            host home, <project> is cloned here, <task-id> is free, and this
#            home's bin/fm-capacity.sh --admit admits it (its exit 75 passes
#            through). It changes nothing.
#   rescue   adds <url>, the supervisor's rescue repository over SSH, to the
#            placed task's copy as the remote `fm-rescue` (refusing another
#            URL already under that name), then proves this host reaches it
#            with git ls-remote.
#   carried  verifies the placed ship's copy carries its work at <head>:
#            bin/fm-continuation-lib.sh's fm_continuation_verify_copy.
#   handoff  composes the hand-off document here with bin/fm-handoff-compose.sh,
#            reading this home's brief, status, notes, copy, and T3 thread, and
#            prints it; the primary stores it. <to> and <ran-on> name where the
#            continuation runs and this host's id, so the document says when
#            the work moved between machines.
#   stage    writes a continuation's hand-off document to data/<new-id>/handoff.md,
#            or a scout's interim report to data/<old-id>/report.md, from
#            stdin, before that continuation's spawn. It refuses an id this
#            home holds for its own work, and replacing a different report or,
#            once the continuation runs, a different document.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_HOME=${FM_HOME:?FM_HOME is required}
STATE="$TARGET_HOME/state"
DATA="$TARGET_HOME/data"
CONFIG="$TARGET_HOME/config"
SCHEMA=fm-remote-worker-control.v1
CAPTURE_MAX_LINES=100

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

validate_id() {
  case "$1" in ''|-*|.*|*[!A-Za-z0-9._-]*) die "invalid task id: $1" ;; esac
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-continuation-lib.sh
. "$SCRIPT_DIR/fm-continuation-lib.sh"

validate_home() {
  [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "worker host home is unavailable or unsafe: $TARGET_HOME"
  [ -f "$TARGET_HOME/.fm-worker-host" ] && [ ! -L "$TARGET_HOME/.fm-worker-host" ] \
    || die "$TARGET_HOME is not a worker host home: it has no .fm-worker-host marker (docs/remote-workers.md)"
  [ ! -e "$TARGET_HOME/.fm-secondmate-home" ] \
    || die "$TARGET_HOME is a secondmate home; a worker host home must be its own headless home"
  fm_backlog_backend_manual "$CONFIG" \
    || die "worker host home $TARGET_HOME must set config/backlog-backend to manual: the primary's backlog owns these tasks"
  mkdir -p "$STATE" "$DATA" || die "worker host home state or data directory is unavailable"
}

claim_path() { printf '%s/%s.remote-worker\n' "$STATE" "$1"; }
meta_path() { printf '%s/%s.meta\n' "$STATE" "$1"; }

require_claim() { # <id>
  local claim
  claim=$(claim_path "$1")
  [ -f "$claim" ] && [ ! -L "$claim" ] \
    || die "task $1 was not placed on this worker host by a primary (no $claim)"
}

require_task() { # <id>
  require_claim "$1"
  [ -f "$(meta_path "$1")" ] && [ ! -L "$(meta_path "$1")" ] \
    || die "task $1 has no task record on this worker host"
}

print_route() { # <id>
  local id=$1 meta key value
  meta=$(meta_path "$id")
  printf 'schema=%s\n' "$SCHEMA"
  printf 'task=%s\n' "$id"
  value=$(fm_meta_get "$meta" kind)
  printf 'kind=%s\n' "${value:-ship}"
  printf 'backend=%s\n' "$(fm_backend_of_meta "$meta")"
  printf 'target=%s\n' "$(fm_backend_target_of_meta "$meta")"
  for key in worktree project harness model effort mode yolo branch base_branch; do
    value=$(fm_meta_get "$meta" "$key")
    [ -n "$value" ] || continue
    printf '%s=%s\n' "$key" "$value"
  done
}

# Replace the scaffold's `# Task` section (its heading through the line before
# the next top-level heading) with `# Task` plus the supplied body.
replace_task_section() { # <brief> <body-file>
  local brief=$1 body=$2 tmp
  tmp=$(mktemp "$brief.task.XXXXXX") || return 1
  if ! perl -e '
    my ($brief, $body_path) = @ARGV;
    open(my $b, "<", $body_path) or exit 1;
    local $/; my $body = <$b>; close $b;
    $body =~ s/\n+\z//;
    open(my $f, "<", $brief) or exit 1;
    my @lines = split(/(?<=\n)/, <$f>); close $f;
    my ($out, $state) = ("", 0);
    for my $line (@lines) {
      if ($state == 0 && $line =~ /^# Task\s*$/) { $out .= "# Task\n$body\n\n"; $state = 1; next }
      if ($state == 1) { next unless $line =~ /^# \S/; $state = 2 }
      $out .= $line;
    }
    exit 2 if $state == 0;
    print $out;
  ' "$brief" "$body" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$brief"
}

cmd_spawn() {
  local id=$1 project=$2 kind=ship flag value proj_dir meta claim brief body out rc=0 lock
  local cont_from='' cont_remote='' cont_branch='' cont_head='' rescue_url='' source_brief=''
  local -a brief_args spawn_args
  shift 2
  validate_id "$id"
  case "$project" in ''|-*|.*|*[!A-Za-z0-9._-]*) die "invalid project name: $project" ;; esac
  brief_args=()
  spawn_args=()
  while [ "$#" -gt 0 ]; do
    flag=$1
    shift
    case "$flag" in
      --scout) kind=scout; brief_args+=(--scout); spawn_args+=(--scout); continue ;;
      --herdr-lab) brief_args+=(--herdr-lab); continue ;;
      --journal) brief_args+=(--journal); continue ;;
    esac
    [ "$#" -gt 0 ] || die "$flag requires a value"
    value=$1
    shift
    case "$flag" in
      --mode|--branch-prefix|--base-branch|--upstream-consent)
        brief_args+=("$flag" "$value"); spawn_args+=("$flag" "$value") ;;
      --forge|--shape|--pr) brief_args+=("$flag" "$value") ;;
      --yolo|--harness|--model|--effort|--backend) spawn_args+=("$flag" "$value") ;;
      --continue-from) validate_id "$value"; cont_from=$value ;;
      --carried-remote) cont_remote=$value ;;
      --carried-branch) cont_branch=$value ;;
      --carried-head) cont_head=$value ;;
      --rescue-url) validate_url "$value"; rescue_url=$value ;;
      *) die "unsupported remote worker spawn flag: $flag" ;;
    esac
  done
  validate_home
  proj_dir="$TARGET_HOME/projects/$project"
  if [ ! -d "$proj_dir" ] || [ -L "$proj_dir" ] || ! git -C "$proj_dir" rev-parse --git-dir >/dev/null 2>&1; then
    die "project $project is not cloned on this worker host at $proj_dir"
  fi
  case " ${brief_args[*]} " in
    *' --upstream-consent '*) brief_args+=(--project "$proj_dir") ;;
  esac
  if [ -n "$cont_from" ]; then
    [ "$cont_from" != "$id" ] || die "task $id cannot continue itself"
    fm_continuation_fields_valid "$kind" "$cont_remote" "$cont_branch" "$cont_head" \
      || die "continuation of $cont_from: $FM_CONT_ERROR"
    [ -s "$DATA/$id/handoff.md" ] && [ ! -L "$DATA/$id/handoff.md" ] \
      || die "continuation $id has no staged hand-off document; the primary stages it first"
  elif [ -n "$cont_remote$cont_branch$cont_head$rescue_url" ]; then
    die "--carried-* and --rescue-url apply only with --continue-from"
  fi

  meta=$(meta_path "$id")
  claim=$(claim_path "$id")
  brief="$DATA/$id/brief.md"
  lock="$STATE/.remote-worker-spawn-$id.lock"
  fm_lock_try_acquire "$lock" || die "another remote spawn for task $id is already running on this worker host"
  # shellcheck disable=SC2064 # the lock path is fixed for this invocation.
  trap "fm_lock_release '$lock' >/dev/null 2>&1 || true" EXIT
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    [ -f "$claim" ] && [ ! -L "$claim" ] \
      || die "task id $id is already used by a task this worker host did not receive from a primary"
    [ "$(fm_meta_get "$meta" kind)" = "$kind" ] \
      || die "task $id already runs here as a $(fm_meta_get "$meta" kind), not a $kind"
    [ "$(fm_meta_get "$meta" project)" = "$proj_dir" ] \
      || die "task $id already runs here on project $(fm_meta_get "$meta" project), not $proj_dir"
    [ "$(fm_meta_get "$meta" continued_from)" = "$cont_from" ] \
      || die "task $id already runs here continuing '$(fm_meta_get "$meta" continued_from)', not '$cont_from'"
    printf 'notice: task %s is already placed on this worker host; reporting its existing route\n' "$id" >&2
    print_route "$id"
    return 0
  fi
  # A claim without a record is a spawn that never finished (its own failure
  # path removes both), so it is reclaimed under this lock. Anything else
  # occupying the brief path belongs to a host-local task and is refused.
  if [ -e "$claim" ] || [ -L "$claim" ]; then
    rm -f -- "$claim"
    rm -f -- "$brief" "$DATA/$id/launch-brief.md"
  elif [ -e "$brief" ] || [ -L "$brief" ]; then
    die "task $id already has a brief on this worker host that no primary placed there"
  fi

  body=$(mktemp "${TMPDIR:-/tmp}/fm-remote-worker-task.XXXXXX") || die "cannot stage the task body"
  # shellcheck disable=SC2064 # both paths are fixed for this invocation.
  trap "rm -f -- '$body'; fm_lock_release '$lock' >/dev/null 2>&1 || true" EXIT
  cat > "$body"
  [ -n "$(tr -d '[:space:]' < "$body")" ] || die "the primary sent an empty # Task body for $id"
  if [ -n "$cont_from" ]; then
    # The carried Task comes from the primary's body, not a brief of this home.
    source_brief=$(mktemp "${TMPDIR:-/tmp}/fm-remote-worker-source.XXXXXX") || die "cannot stage the carried Task"
    # shellcheck disable=SC2064 # every path is fixed for this invocation.
    trap "rm -f -- '$body' '$source_brief'; fm_lock_release '$lock' >/dev/null 2>&1 || true" EXIT
    { printf '# Task\n'; cat "$body"; } > "$source_brief"
    [ -z "$rescue_url" ] || add_rescue_remote "$proj_dir" "$rescue_url" "project $project"
    fm_continuation_write "$DATA" "$id" "$cont_from" "$kind" "$cont_remote" "$cont_branch" "$cont_head" local \
      || die "$FM_CONT_ERROR"
    brief_args+=(--continue-from "$cont_from" --continue-source "$source_brief")
    spawn_args+=(--continue-from "$cont_from")
  fi

  printf 'placed_at=%s\n' "$(date +%s)" > "$claim" || die "could not write the placement claim $claim"
  spawn_abandon() {
    [ -e "$meta" ] && return 0
    rm -f -- "$claim" "$brief" "$DATA/$id/launch-brief.md"
    rmdir -- "$DATA/$id" 2>/dev/null || true
  }
  if ! out=$("$SCRIPT_DIR/fm-brief.sh" "$id" "$project" "${brief_args[@]}" 2>&1); then
    printf '%s\n' "$out" >&2
    spawn_abandon
    die "could not render the brief for $id on this worker host"
  fi
  if ! replace_task_section "$brief" "$body"; then
    spawn_abandon
    die "the rendered brief for $id has no # Task section to fill"
  fi
  if out=$("$SCRIPT_DIR/fm-spawn.sh" "$id" "$proj_dir" "${spawn_args[@]}" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  if [ "$rc" -ne 0 ]; then
    spawn_abandon
    return "$rc"
  fi
  [ -f "$meta" ] || { spawn_abandon; die "the worker host spawn of $id returned without a task record"; }
  print_route "$id"
}

cmd_send() {
  [ "$#" -eq 3 ] || usage
  local id=$1 delivery_id=$2 message=$3
  case "$delivery_id" in
    ''|-*|*[!A-Za-z0-9._-]*) die "invalid delivery id: $delivery_id" ;;
  esac
  [ -n "${message//[[:space:]]/}" ] || die "remote steer message must be nonempty"
  require_task "$id"
  message="[remote-worker delivery: $delivery_id]"$'\n'"$message"
  FM_SEND_IDEMPOTENT=1 "$SCRIPT_DIR/fm-send.sh" "$id" "$message"
}

cmd_send_stdin() {
  local id=$1 delivery_id=$2 message
  IFS= read -r -d '' message < /dev/stdin || :
  cmd_send "$id" "$delivery_id" "$message"
}

cmd_control() {
  local id=$1 verb=$2
  case "$verb" in
    interrupt|exit) ;;
    relaunch) die "relaunch is not offered for a remote worker; it stays a decision for the primary" ;;
    *) die "unknown control verb: $verb" ;;
  esac
  require_task "$id"
  "$SCRIPT_DIR/fm-control.sh" "$id" "$verb"
}

cmd_answer() {
  local id=$1
  shift
  [ "$#" -eq 0 ] || [ "$#" -eq 2 ] || usage
  require_task "$id"
  "$SCRIPT_DIR/fm-t3-answer.sh" "$id" "$@"
}

cmd_capture() {
  local id=$1 lines=${2:-40}
  case "$lines" in ''|*[!0-9]*|0) die "capture line count must be positive" ;; esac
  [ "$lines" -le "$CAPTURE_MAX_LINES" ] || die "capture line count exceeds $CAPTURE_MAX_LINES"
  require_task "$id"
  (
    set -o pipefail
    "$SCRIPT_DIR/fm-peek.sh" "$id" "$lines" | perl -e '
      binmode STDIN; binmode STDOUT;
      my $remaining = 65536;
      while (1) {
        my $n = read(STDIN, my $chunk, 8192);
        die "capture read failed: $!" unless defined $n;
        last unless $n;
        if ($remaining > 0) {
          my $out = substr($chunk, 0, $remaining);
          print $out or die "capture write failed: $!";
          $remaining -= length($out);
        }
      }
    '
  )
}

cmd_file() {
  local id=$1 which=$2
  case "$which" in
    report|journal|brief|handoff-notes) ;;
    *) die "remote worker file must be report, journal, brief, or handoff-notes, not: $which" ;;
  esac
  require_claim "$id"
  "$SCRIPT_DIR/fm-remote-file.sh" get "data/$id/$which.md"
}

cmd_teardown() {
  local id=$1 force=${2:-} rc=0
  [ -z "$force" ] || [ "$force" = --force ] || usage
  if [ ! -e "$(claim_path "$id")" ] && [ ! -L "$(claim_path "$id")" ] \
     && [ ! -e "$(meta_path "$id")" ] && [ ! -L "$(meta_path "$id")" ]; then
    printf 'teardown %s: no task record remains on this worker host\n' "$id"
    return 0
  fi
  require_claim "$id"
  if [ -f "$(meta_path "$id")" ]; then
    if [ -n "$force" ]; then
      "$SCRIPT_DIR/fm-teardown.sh" "$id" --force || rc=$?
    else
      "$SCRIPT_DIR/fm-teardown.sh" "$id" || rc=$?
    fi
  else
    printf 'teardown %s: no task record remains on this worker host\n' "$id"
  fi
  if [ ! -e "$(meta_path "$id")" ] && [ ! -L "$(meta_path "$id")" ]; then
    rm -f -- "$(claim_path "$id")"
  fi
  return "$rc"
}

validate_url() {
  case "$1" in
    ''|-*|*[[:space:][:cntrl:]]*) die "invalid rescue repository URL: $1" ;;
  esac
}

# Add or confirm the remote fm-rescue at <url> in <checkout>, then prove this
# host reaches it.
add_rescue_remote() { # <checkout> <url> <what>
  local checkout=$1 url=$2 what=$3 current
  if current=$(git -C "$checkout" remote get-url fm-rescue 2>/dev/null); then
    [ "$current" = "$url" ] \
      || die "$what already has a remote 'fm-rescue' at '$current', not '$url'; it is left unchanged"
  else
    git -C "$checkout" remote add fm-rescue "$url" || die "could not add remote 'fm-rescue' to $what"
  fi
  git -C "$checkout" ls-remote fm-rescue >/dev/null \
    || die "this worker host cannot reach the supervisor's rescue repository at $url; check its SSH access to the supervisor"
}

# The id is free for a continuation here: nothing of this home's own uses it.
require_free_id() { # <id>
  local id=$1
  [ ! -e "$(meta_path "$id")" ] && [ ! -L "$(meta_path "$id")" ] \
    || die "task id $id already has a task record on this worker host"
  [ ! -e "$DATA/$id/brief.md" ] || [ -e "$(claim_path "$id")" ] \
    || die "task id $id already has a brief on this worker host that no primary placed there"
}

cmd_admit() {
  local id=$1 project=$2 rc=0
  case "$project" in ''|-*|.*|*[!A-Za-z0-9._-]*) die "invalid project name: $project" ;; esac
  validate_home
  if [ ! -d "$TARGET_HOME/projects/$project" ] || [ -L "$TARGET_HOME/projects/$project" ] \
     || ! git -C "$TARGET_HOME/projects/$project" rev-parse --git-dir >/dev/null 2>&1; then
    die "project $project is not cloned on this worker host"
  fi
  require_free_id "$id"
  "$SCRIPT_DIR/fm-capacity.sh" --admit >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || { printf 'error: this worker host does not admit another task now (exit %s)\n' "$rc" >&2; return "$rc"; }
  printf 'admitted: %s on project %s\n' "$id" "$project"
}

cmd_rescue() {
  local id=$1 url=$2 copy
  validate_url "$url"
  require_task "$id"
  copy=$(fm_meta_get "$(meta_path "$id")" worktree)
  if [ -z "$copy" ] || ! git -C "$copy" rev-parse --git-dir >/dev/null 2>&1; then
    die "task $id's copy '${copy:-unrecorded}' is not a git checkout"
  fi
  add_rescue_remote "$copy" "$url" "task $id's copy"
  printf 'ready: task %s pushes to fm-rescue at %s\n' "$id" "$url"
}

cmd_carried() {
  local id=$1 remote=$2 branch=$3 head=$4 meta copy
  require_task "$id"
  meta=$(meta_path "$id")
  fm_continuation_fields_valid ship "$remote" "$branch" "$head" || die "$FM_CONT_ERROR"
  [ "$(fm_meta_get "$meta" branch)" = "$branch" ] \
    || die "the ready line names branch '$branch', but task $id records '$(fm_meta_get "$meta" branch)'"
  copy=$(fm_meta_get "$meta" worktree)
  fm_continuation_verify_copy "$copy" "$remote" "$branch" "$head" || die "task $id: $FM_CONT_ERROR"
  printf 'carried: %s %s at %s on %s\n' "$id" "$branch" "$head" "$remote"
}

cmd_handoff() {
  local id=$1 new_id=$2 to=$3 ran_on=$4 reason='' remote='' branch='' head='' kind dir rc=0
  shift 4
  validate_id "$new_id"
  fm_continuation_target_valid "$to" || die "invalid continuation target: $to"
  fm_continuation_target_valid "$ran_on" || die "invalid worker host id: $ran_on"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || usage; reason=$2; shift 2 ;;
      --carried) [ "$#" -ge 4 ] || usage; remote=$2; branch=$3; head=$4; shift 4 ;;
      *) die "unknown handoff option: $1" ;;
    esac
  done
  require_task "$id"
  kind=$(fm_meta_get "$(meta_path "$id")" kind)
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-worker-handoff.XXXXXX") || die "cannot stage the continuation record"
  # shellcheck disable=SC2064 # the path is fixed for this invocation.
  trap "rm -rf -- '$dir'" EXIT
  fm_continuation_write "$dir" "$new_id" "$id" "${kind:-ship}" "$remote" "$branch" "$head" "$to" || die "$FM_CONT_ERROR"
  "$SCRIPT_DIR/fm-handoff-compose.sh" "$id" "$new_id" --reason "$reason" --record-dir "$dir" --ran-on "$ran_on" || rc=$?
  return "$rc"
}

cmd_stage() {
  local new_id=$1 old_id=$2 which=$3 target tmp
  validate_id "$old_id"
  case "$which" in
    handoff) target="$DATA/$new_id/handoff.md" ;;
    report) target="$DATA/$old_id/report.md" ;;
    *) die "a staged continuation file must be handoff or report, not: $which" ;;
  esac
  if [ -e "$(meta_path "$new_id")" ] || [ -L "$(meta_path "$new_id")" ]; then
    require_claim "$new_id"
  else
    require_free_id "$new_id"
  fi
  mkdir -p "$(dirname "$target")" && [ ! -L "$(dirname "$target")" ] && [ ! -L "$target" ] \
    || die "cannot stage $target"
  tmp=$(mktemp "$target.stage.XXXXXX") || die "cannot stage $target"
  cat > "$tmp"
  [ -s "$tmp" ] || { rm -f -- "$tmp"; die "the primary sent an empty $which for $new_id"; }
  if [ -e "$target" ]; then
    if cmp -s "$tmp" "$target"; then rm -f -- "$tmp"; printf 'staged: %s (unchanged)\n' "$target"; return 0; fi
    if [ "$which" = report ] || [ -e "$(meta_path "$new_id")" ]; then
      rm -f -- "$tmp"
      die "$target already holds different content; it is left unchanged"
    fi
  fi
  mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; die "cannot stage $target"; }
  printf 'staged: %s\n' "$target"
}

cmd_named_head() {
  local id=$1 line=$2 meta kind reason mode wt url remote_head
  if ! reason=$(require_task "$id" 2>&1); then
    printf 'refused: %s\n' "${reason#error: }"
    exit 1
  fi
  case "$line" in *[[:cntrl:]]*|'') die "the done line must be one non-empty line" ;; esac
  meta=$(meta_path "$id")
  kind=$(fm_meta_get "$meta" kind)
  # shellcheck source=bin/fm-dod-lib.sh
  . "$SCRIPT_DIR/fm-dod-lib.sh"
  mode=$(fm_meta_get "$meta" mode)
  wt=$(fm_meta_get "$meta" worktree)
  if fm_dod_forge_head_is_named_head "$mode" \
    && url=$(fm_dod_pr_url_from_done_note "$(status_line_note "$line")") \
    && fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] \
    && [ -d "$wt" ] && command -v gh >/dev/null 2>&1; then
    fm_pr_github_host_export "$FM_PR_HOST"
    if remote_head=$(fm_run_timed 10 "$SCRIPT_DIR/fm-gh-account.sh" exec --dir "$wt" -- \
      bash -c 'cd "$1" && gh pr view "$2" --json headRefOid -q .headRefOid 2>/dev/null' _ "$wt" "$url") \
      && fm_pr_head_valid "$remote_head"; then
      printf 'accepted: %s\n' "$id"
      return 0
    fi
  fi
  if reason=$(fm_dod_accept_ship_done "${kind:-ship}" "$mode" \
    "$wt" "$(fm_meta_get "$meta" project)" "$line" "$STATE" "$id" "$meta"); then
    printf 'accepted: %s\n' "$id"
    return 0
  fi
  reason=$(printf '%s\n' "$reason" | head -1)
  printf 'refused: %s\n' "${reason:-the named-head gate refused this done line}"
  exit 1
}

VERB=${1:-}
case "$VERB" in
  ''|-h|--help|help) usage ;;
esac
shift
[ "$#" -ge 1 ] || usage
validate_id "$1"
case "$VERB" in
  spawn) [ "$#" -ge 2 ] || usage; cmd_spawn "$@" ;;
  route) [ "$#" -eq 1 ] || usage; validate_home; require_task "$1"; print_route "$1" ;;
  state) [ "$#" -eq 1 ] || usage; validate_home; require_claim "$1"; "$SCRIPT_DIR/fm-crew-state.sh" "$1" ;;
  send) [ "$#" -eq 3 ] || usage; validate_home; cmd_send "$@" ;;
  send-stdin) [ "$#" -eq 2 ] || usage; validate_home; cmd_send_stdin "$@" ;;
  control) [ "$#" -eq 2 ] || usage; validate_home; cmd_control "$@" ;;
  answer) validate_home; cmd_answer "$@" ;;
  capture) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; validate_home; cmd_capture "$@" ;;
  file) [ "$#" -eq 2 ] || usage; validate_home; cmd_file "$@" ;;
  teardown) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; validate_home; cmd_teardown "$@" ;;
  named-head) [ "$#" -eq 2 ] || usage; validate_home; cmd_named_head "$@" ;;
  admit) [ "$#" -eq 2 ] || usage; cmd_admit "$@" ;;
  rescue) [ "$#" -eq 2 ] || usage; validate_home; cmd_rescue "$@" ;;
  carried) [ "$#" -eq 4 ] || usage; validate_home; cmd_carried "$@" ;;
  handoff) [ "$#" -ge 4 ] || usage; validate_home; cmd_handoff "$@" ;;
  stage) [ "$#" -eq 3 ] || usage; validate_home; cmd_stage "$@" ;;
  *) die "unknown command: $VERB" ;;
esac
