#!/usr/bin/env bash
# The private rescue remote: one bare repository per project on this machine,
# at ~/fm-rescue/<project>.git, that a hand-off pushes a ship's carried branch
# to (bin/fm-handoff.sh --remote fm-rescue) instead of a branch on origin.
# A push creates refs/remotes/fm-rescue/<branch> in the project, which is a
# remote-tracking branch, so ordinary bin/fm-teardown.sh accepts the work as
# landed with no --force: the commits then exist outside the copy it returns.
# Usage: fm-rescue.sh ensure <task-id>
#        fm-rescue.sh prune <task-id> <project-dir> [--abandoned|--landed]
#        fm-rescue.sh path <project-dir>
#   ensure creates the rescue repository for the task's project on demand
#   (private: the directories are mode 700) and adds it to the task's copy as
#   the git remote `fm-rescue`. A copy is a worktree of the project's clone,
#   so the remote lands in that clone's shared config and every later copy,
#   including the continuation's, sees it too. Idempotent; it refuses, and
#   changes nothing, when `fm-rescue` already names another URL or the
#   repository path holds something other than a bare repository. bin/fm-handoff.sh
#   runs it when a ship's hand-off names --remote fm-rescue, so nobody needs
#   to run it first; the remote stays an explicit per-hand-off choice.
#   prune deletes the rescue refs a finished hand-off chain no longer needs.
#   <task-id> is any task of the chain (the continuation records
#   data/<id>/continuation link it); the chain's tip is the last continuation.
#   For each link whose record names remote fm-rescue it deletes the carried
#   branch from the rescue repository and the matching
#   refs/remotes/fm-rescue/<branch> from <project-dir>, each only while it
#   still points at the carried commit the record names; a ref that moved is
#   left alone and reported, and an absent one is already pruned. It refuses,
#   deleting nothing, while the tip still has a task record (live work) or a
#   hand-off request of its own in progress. Without a flag it also needs
#   proof that the tip was cleaned up rather than never spawned: its backlog
#   item must be done. --landed is passed by bin/fm-teardown.sh right after an
#   ordinary (not forced) cleanup of the tip, whose landed-work test is that
#   proof; the tip must then be <task-id> itself. --abandoned is the owner's
#   word that the work is abandoned (including a continuation that was never
#   spawned, or one cleaned up with --force), and is the only way to prune in a
#   home whose backlog is kept by hand. Unreachable objects leave the rescue
#   repository through git's own garbage collection.
#   path prints the rescue repository path for a project.
# A later cross-machine hand-off can reach the same repository from a worker
# host over SSH: rescue_url below is the one place the remote's URL is chosen,
# and it is a plain local path today because only same-machine hand-offs exist.
# Exit codes: 0 done (or nothing to prune); 1 refused or failed; 2 usage.
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

# shellcheck source=bin/fm-continuation-lib.sh
. "$SCRIPT_DIR/fm-continuation-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

RESCUE_REMOTE=fm-rescue

die() { echo "error: $*" >&2; exit 1; }

meta_get() {  # <meta> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

rescue_path() {  # <project-dir>
  local name
  name=$(basename "$1")
  name=${name%.git}
  fm_task_id_path_safe "$name" || die "project name '$name' is not usable as a rescue repository name"
  printf '%s/fm-rescue/%s.git\n' "$HOME" "$name"
}

rescue_url() {  # <project-dir>
  rescue_path "$1"
}

is_bare_repo() {  # <path>
  [ "$(git -C "$1" rev-parse --is-bare-repository 2>/dev/null || true)" = true ] &&
    [ "$(cd "$1" && pwd -P)" = "$(cd "$(git -C "$1" rev-parse --absolute-git-dir)" && pwd -P)" ]
}

do_ensure() {  # <task-id>
  local id=$1 meta project copy path url current
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || die "task $id has no record at $meta"
  project=$(meta_get "$meta" project)
  copy=$(meta_get "$meta" worktree)
  [ -n "$project" ] || die "task $id records no project"
  if [ -z "$copy" ] || ! git -C "$copy" rev-parse --git-dir >/dev/null 2>&1; then
    die "task $id's copy '${copy:-unrecorded}' is not a git checkout"
  fi
  path=$(rescue_path "$project")
  url=$(rescue_url "$project")
  if current=$(git -C "$copy" remote get-url "$RESCUE_REMOTE" 2>/dev/null); then
    [ "$current" = "$url" ] ||
      die "task $id's copy already has a remote '$RESCUE_REMOTE' at '$current', not '$url'; it is left unchanged"
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    is_bare_repo "$path" || die "$path exists but is not a bare git repository; it is left unchanged"
  else
    (umask 077 && mkdir -p "$(dirname "$path")") || die "could not create $(dirname "$path")"
    chmod 700 "$(dirname "$path")" || die "could not make $(dirname "$path") private"
    (umask 077 && git init --quiet --bare "$path") || die "could not create the rescue repository $path"
    echo "created: rescue repository $path"
  fi
  if [ -z "${current:-}" ]; then
    git -C "$copy" remote add "$RESCUE_REMOTE" "$url" ||
      die "could not add remote '$RESCUE_REMOTE' to task $id's copy"
  fi
  echo "ready: task $id's copy pushes to remote '$RESCUE_REMOTE' at $url"
}

# Every continuation record that continues <id>; prints the continuing ids.
continuations_of() {  # <id>
  local record new_id
  for record in "$DATA"/*/continuation; do
    [ -f "$record" ] || continue
    new_id=$(basename "$(dirname "$record")")
    [ "$(sed -n 's/^continued_from=//p' "$record" | head -n 1)" = "$1" ] || continue
    printf '%s\n' "$new_id"
  done
}

# Delete <ref> in <git-dir-or-copy> only while it points at <head>.
# Prints one of: pruned, absent, moved:<sha>, failed.
delete_ref_at() {  # <git-path> <ref> <head>
  local actual
  actual=$(git -C "$1" rev-parse --verify --quiet "$2" 2>/dev/null || true)
  if [ -z "$actual" ]; then
    echo absent
  elif [ "$actual" != "$3" ]; then
    echo "moved:$actual"
  elif git -C "$1" update-ref -d "$2" "$3" 2>/dev/null; then
    echo pruned
  else
    echo failed
  fi
}

do_prune() {  # <task-id> <project-dir> <flag>
  local id=$1 project=$2 flag=$3 tip next count path cur result tracking rc=0 carried=0
  [ -d "$project" ] || die "project directory $project does not exist"
  path=$(rescue_path "$project")

  tip=$id
  count=0
  while :; do
    next=$(continuations_of "$tip")
    [ -n "$next" ] || break
    [ "$(printf '%s\n' "$next" | wc -l | tr -d ' ')" = 1 ] ||
      die "task $tip was continued more than once ($(printf '%s' "$next" | tr '\n' ' ')); prune each by hand"
    tip=$next
    count=$((count + 1))
    [ "$count" -le 100 ] || die "the continuation chain from $id does not end"
  done

  [ ! -e "$STATE/$tip.meta" ] ||
    die "task $tip, the last continuation of $id, still has a task record; its rescued work is in use until it is cleaned up"
  [ ! -e "$DATA/$tip/handoff-request" ] ||
    die "task $tip has a hand-off request in progress; finish or cancel it first"
  case "$flag" in
    --landed)
      [ "$tip" = "$id" ] || die "--landed vouches for $id, but the chain continues to $tip"
      ;;
    --abandoned) ;;
    '')
      if fm_backlog_transition_applies "$CONFIG" "$DATA" ship; then
        fm_backlog_row_probe "$DATA" "$tip" ||
          die "cannot prove task $tip was cleaned up: its backlog item could not be read (${FM_BACKLOG_ROW_ERROR:-$FM_BACKLOG_ROW_RESULT}); pass --abandoned only with the owner's word"
        case "$FM_BACKLOG_ROW_STATE" in
          done\ *) ;;
          *) die "task $tip's backlog item is ${FM_BACKLOG_ROW_STATE%% *}, so it may never have run; its rescued work stays until it lands, or pass --abandoned with the owner's word" ;;
        esac
      else
        [ "$?" -ne 2 ] || die "the backlog cannot be read ($FM_BACKLOG_TRANSITION_ERROR)"
        die "this home's backlog is kept by hand, so prune cannot prove task $tip was cleaned up; pass --abandoned only with the owner's word"
      fi
      ;;
  esac

  cur=$tip
  while [ -f "$(fm_continuation_path "$DATA" "$cur")" ]; do
    next=$(sed -n 's/^continued_from=//p' "$(fm_continuation_path "$DATA" "$cur")" | head -n 1)
    fm_continuation_read "$DATA" "$cur" "$next" || die "$FM_CONT_ERROR"
    if [ "$FM_CONT_KIND" = ship ] && [ "$FM_CONT_REMOTE" = "$RESCUE_REMOTE" ]; then
      carried=1
      if [ -d "$path" ]; then
        result=$(delete_ref_at "$path" "refs/heads/$FM_CONT_BRANCH" "$FM_CONT_HEAD")
      else
        result=absent
      fi
      tracking=$(delete_ref_at "$project" "refs/remotes/$RESCUE_REMOTE/$FM_CONT_BRANCH" "$FM_CONT_HEAD")
      case "$result" in
        pruned) echo "pruned: $FM_CONT_BRANCH at $FM_CONT_HEAD from $path (carried from $FM_CONT_FROM to $cur)" ;;
        absent) echo "already pruned: $FM_CONT_BRANCH from $path (carried from $FM_CONT_FROM to $cur)" ;;
        moved:*) echo "warning: $path has $FM_CONT_BRANCH at ${result#moved:}, not the carried $FM_CONT_HEAD; left in place" >&2; rc=1 ;;
        *) echo "warning: could not delete $FM_CONT_BRANCH from $path" >&2; rc=1 ;;
      esac
      case "$tracking" in
        pruned|absent) ;;
        moved:*) echo "warning: $project has $RESCUE_REMOTE/$FM_CONT_BRANCH at ${tracking#moved:}, not the carried $FM_CONT_HEAD; left in place" >&2 ;;
        *) echo "warning: could not delete $RESCUE_REMOTE/$FM_CONT_BRANCH from $project" >&2; rc=1 ;;
      esac
    fi
    cur=$next
  done
  [ "$carried" -eq 1 ] || echo "nothing to prune: no hand-off in $id's chain carried work through $RESCUE_REMOTE"
  return "$rc"
}

verb=${1:-}
[ "$#" -eq 0 ] || shift
case "$verb" in
  ensure)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_task_id_path_safe "$1" || { echo "error: invalid task id '$1'" >&2; exit 2; }
    do_ensure "$1"
    ;;
  prune)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
    fm_task_id_path_safe "$1" || { echo "error: invalid task id '$1'" >&2; exit 2; }
    case "${3:-}" in
      ''|--abandoned|--landed) ;;
      *) echo "error: unknown option ${3}" >&2; exit 2 ;;
    esac
    do_prune "$1" "$2" "${3:-}"
    ;;
  path)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    rescue_path "$1"
    ;;
  *) usage >&2; exit 2 ;;
esac
