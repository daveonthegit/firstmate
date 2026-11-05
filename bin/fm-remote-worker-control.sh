#!/usr/bin/env bash
# Host-local leg for ship and scout workers a primary places on a worker host.
#
# Usage (reached through bin/fm-on.sh <worker-host-id> on the primary):
#   fm-remote-worker-control.sh spawn <task-id> <project> [--scout] [flags...]  # # Task body on stdin
#   fm-remote-worker-control.sh route <task-id>
#   fm-remote-worker-control.sh state <task-id>
#   fm-remote-worker-control.sh send <task-id> [--fire-and-forget <delivery-id>] <message>
#   fm-remote-worker-control.sh send-stdin <task-id> [--fire-and-forget <delivery-id>]  # message on stdin
#   fm-remote-worker-control.sh control <task-id> {interrupt|exit}
#   fm-remote-worker-control.sh answer <task-id> [<request-id> <answers-json>]
#   fm-remote-worker-control.sh capture <task-id> [lines]
#   fm-remote-worker-control.sh file <task-id> {report|journal|brief}
#   fm-remote-worker-control.sh teardown <task-id> [--force]
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
#   branch=<b> (ship only, when recorded)
# one key=value per line.
#
# send writes the steer idempotently (FM_SEND_IDEMPOTENT=1), so the primary may
# repeat this leg once after an ambiguous transport failure without a second
# record. teardown runs the full ordinary fm-teardown here - landed-work test,
# endpoint close, process reaper, worktree return - and removes the claim only
# once that task record is gone.
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
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

validate_id() {
  case "$1" in ''|-*|.*|*[!A-Za-z0-9._-]*) die "invalid task id: $1" ;; esac
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

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

cmd_send() { # <id> [--fire-and-forget <delivery-id>] <message>
  local id=$1 message
  local -a send_args
  shift
  send_args=()
  if [ "${1:-}" = --fire-and-forget ]; then
    [ "$#" -ge 2 ] || usage
    send_args+=(--fire-and-forget "$2")
    shift 2
  fi
  [ "$#" -eq 1 ] || usage
  message=$1
  [ -n "${message//[[:space:]]/}" ] || die "remote steer message must be nonempty"
  require_task "$id"
  FM_SEND_IDEMPOTENT=1 "$SCRIPT_DIR/fm-send.sh" "$id" "${send_args[@]}" "$message"
}

cmd_send_stdin() { # <id> [--fire-and-forget <delivery-id>]
  local id=$1 message
  shift
  IFS= read -r -d '' message < /dev/stdin || :
  cmd_send "$id" "$@" "$message"
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
  "$SCRIPT_DIR/fm-peek.sh" "$id" "$lines" | head -c 65536
}

cmd_file() {
  local id=$1 which=$2
  case "$which" in
    report|journal|brief) ;;
    *) die "remote worker file must be report, journal, or brief, not: $which" ;;
  esac
  require_claim "$id"
  "$SCRIPT_DIR/fm-remote-file.sh" get "data/$id/$which.md"
}

cmd_teardown() {
  local id=$1 force=${2:-} rc=0
  [ -z "$force" ] || [ "$force" = --force ] || usage
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
  send) [ "$#" -ge 2 ] || usage; validate_home; cmd_send "$@" ;;
  send-stdin) [ "$#" -ge 1 ] && [ "$#" -le 3 ] || usage; validate_home; cmd_send_stdin "$@" ;;
  control) [ "$#" -eq 2 ] || usage; validate_home; cmd_control "$@" ;;
  answer) validate_home; cmd_answer "$@" ;;
  capture) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; validate_home; cmd_capture "$@" ;;
  file) [ "$#" -eq 2 ] || usage; validate_home; cmd_file "$@" ;;
  teardown) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; validate_home; cmd_teardown "$@" ;;
  *) die "unknown command: $VERB" ;;
esac
