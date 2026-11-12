#!/usr/bin/env bash
# The private rescue remote: one bare repository per project on this machine,
# at ~/fm-rescue/<project>.git, that a hand-off pushes a ship's carried branch
# to (bin/fm-handoff.sh --remote fm-rescue) instead of a branch on origin.
# A push creates refs/remotes/fm-rescue/<branch> in the project, which is a
# remote-tracking branch, so ordinary bin/fm-teardown.sh accepts the work with
# no --force: the commits then exist outside the copy it returns. Preservation
# permits cleanup, but does not by itself prove final landing for pruning.
# Usage: fm-rescue.sh ensure <task-id>
#        fm-rescue.sh ensure-project <project-dir>
#        fm-rescue.sh host-url <project-name>
#        fm-rescue.sh holds <project-name> <branch> <head>
#        fm-rescue.sh prune <task-id> <project-dir> [--abandoned]
#   ensure creates the rescue repository for the task's project on demand
#   (private: the directories are mode 700) and adds it to the task's copy as
#   the git remote `fm-rescue`. A copy is a worktree of the project's clone,
#   so the remote lands in that clone's shared config and every later copy,
#   including the continuation's, sees it too. Idempotent; it refuses, and
#   changes nothing, when `fm-rescue` already names another URL or the
#   repository path holds something other than a bare repository. bin/fm-handoff.sh
#   runs it when a ship's hand-off names --remote fm-rescue, so nobody needs
#   to run it first; the remote stays an explicit per-hand-off choice.
#   For a task placed on a worker host (bin/fm-task-route-lib.sh) the
#   repository is still created here, on the supervisor, and the host leg
#   (bin/fm-remote-worker-control.sh `rescue`) adds it to the placed copy by
#   its SSH URL, then proves the host reaches it with git ls-remote.
#   ensure-project adds the remote to a clone on this machine that has no task
#   yet: the project a continuation of a placed task starts in here.
#   host-url creates the repository on demand and prints the URL a worker host
#   uses for it: <dest>:<path>, where <dest> is the one line of
#   config/rescue-ssh, the SSH destination (an ssh config alias or user@host)
#   by which worker hosts reach this supervisor (docs/configuration.md "Rescue
#   remote"). Without that file a worker host cannot reach the repository, so
#   host-url, and ensure for a placed task, refuse.
#   holds exits 0 when this supervisor's repository has <branch> at <head>, the
#   check bin/fm-handoff.sh makes here for work a worker host pushed.
#   prune deletes the rescue refs a finished hand-off chain no longer needs.
#   <task-id> is any task of the chain (the continuation records
#   data/<id>/continuation link it); the chain's tip is the last continuation.
#   For each link whose record names remote fm-rescue it deletes the carried
#   branch from the rescue repository and the matching
#   refs/remotes/fm-rescue/<branch> from <project-dir>, each only while it
#   still points at the carried commit the record names; a ref that moved is
#   left alone and reported, and an absent one is already pruned. It refuses,
#   deleting nothing, while the tip still has a task record (live work) or a
#   hand-off request of its own in progress. Landing is proven by containment
#   of the carried commit in a remote-tracking base branch, excluding fm-rescue
#   and no-mistakes. The base is recorded in the source task's hand-off request,
#   or is the project's default branch when no explicit base was selected.
#   Alternatively, a verified merged PR for the chain's tip proves landing if
#   its head contains the carried commit, or every carried commit since their
#   shared base has a patch-equivalent commit in that head. The latter proof
#   refuses merge commits, missing objects, or unmatched patches; a merged PR
#   alone is insufficient. Cleanup preserves the tip's
#   recorded pr= in data/<tip>/rescue-pr before removing its task record;
#   prune reads that PR live from the forge.
#   Non-forced cleanup of a continuation attempts prune automatically unless
#   another hand-off is in progress; missing landing proof retains the refs
#   and reports that retention without failing cleanup. A Done backlog row
#   alone is not landing proof. Retry prune after landing is verifiable.
#   Refresh remote-tracking refs before pruning. --abandoned is the owner's
#   explicit word that the work is abandoned and needs no landing proof.
#   Unreachable objects leave the rescue repository through git's own garbage
#   collection.
# A copy on this machine reaches the repository by its plain local path, and a
# copy on a worker host by rescue_host_url's SSH URL; those two functions are
# the only places the remote's URL is chosen. Both name the same repository,
# so a branch pushed from either machine is fetched by a continuation on the
# other. Refs pushed from a worker host are pruned only on the supervisor.
# Regression coverage: tests/fm-rescue.test.sh exercises preservation, base
# landing, squash-merged and rebased PR proof, retention on missing or partial
# proof, and abandonment.
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
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-task-route-lib.sh
. "$SCRIPT_DIR/fm-task-route-lib.sh"

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

# The URL a worker host reaches this supervisor's repository by (header).
rescue_host_url() {  # <project-dir>
  local file="$CONFIG/rescue-ssh" dest path
  [ -f "$file" ] && [ ! -L "$file" ] ||
    die "config/rescue-ssh is not set, so a worker host cannot reach this supervisor's rescue repository; write the SSH destination worker hosts use for this machine there (docs/configuration.md \"Rescue remote\")"
  dest=$(sed -n '1p' "$file" | tr -d '[:space:]')
  case "$dest" in
    '' | -* | *[!A-Za-z0-9._@-]*) die "config/rescue-ssh must hold one SSH destination such as an ssh config alias or user@host (got '$dest')" ;;
  esac
  path=$(rescue_path "$1")
  printf '%s:%s\n' "$dest" "$path"
}

create_repo() {  # <path>
  local path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    is_bare_repo "$path" || die "$path exists but is not a bare git repository; it is left unchanged"
    return 0
  fi
  (umask 077 && mkdir -p "$(dirname "$path")") || die "could not create $(dirname "$path")"
  chmod 700 "$(dirname "$path")" || die "could not make $(dirname "$path") private"
  (umask 077 && git init --quiet --bare "$path") || die "could not create the rescue repository $path"
  echo "created: rescue repository $path"
}

# Add the remote to one checkout on this machine (a task copy or a clone).
add_local_remote() {  # <checkout> <url> <what>
  local checkout=$1 url=$2 what=$3 current
  if current=$(git -C "$checkout" remote get-url "$RESCUE_REMOTE" 2>/dev/null); then
    [ "$current" = "$url" ] ||
      die "$what already has a remote '$RESCUE_REMOTE' at '$current', not '$url'; it is left unchanged"
    return 0
  fi
  git -C "$checkout" remote add "$RESCUE_REMOTE" "$url" ||
    die "could not add remote '$RESCUE_REMOTE' to $what"
}

do_ensure_placed() {  # <task-id> <worker-host-id>
  local id=$1 host=$2 project url out rc=0
  project=$(meta_get "$STATE/$id.meta" remote_project)
  [ -n "$project" ] || die "task $id on worker host $host records no project"
  url=$(rescue_host_url "$project") || exit 1
  create_repo "$(rescue_path "$project")"
  out=$("$SCRIPT_DIR/fm-on.sh" "$host" fm-remote-worker-control.sh rescue "$id" "$url" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | sed "s/^/worker host $host: /" >&2
  [ "$rc" -eq 0 ] || die "worker host $host could not add or reach '$RESCUE_REMOTE' at $url for task $id (exit $rc)"
  echo "ready: task $id's copy on worker host $host pushes to remote '$RESCUE_REMOTE' at $url"
}

is_bare_repo() {  # <path>
  [ "$(git -C "$1" rev-parse --is-bare-repository 2>/dev/null || true)" = true ] &&
    [ "$(cd "$1" && pwd -P)" = "$(cd "$(git -C "$1" rev-parse --absolute-git-dir)" && pwd -P)" ]
}

do_ensure() {  # <task-id>
  local id=$1 meta project copy url current
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || die "task $id has no record at $meta"
  fm_task_route "$meta" || die "$FM_TASK_ROUTE_ERROR"
  case "$FM_TASK_ROUTE" in
    worker-host) do_ensure_placed "$id" "$FM_TASK_ROUTE_HOST"; return ;;
    local) ;;
    *) die "task $id is a second mate on another machine; it has no rescue remote" ;;
  esac
  project=$(meta_get "$meta" project)
  copy=$(meta_get "$meta" worktree)
  [ -n "$project" ] || die "task $id records no project"
  if [ -z "$copy" ] || ! git -C "$copy" rev-parse --git-dir >/dev/null 2>&1; then
    die "task $id's copy '${copy:-unrecorded}' is not a git checkout"
  fi
  url=$(rescue_url "$project")
  if current=$(git -C "$copy" remote get-url "$RESCUE_REMOTE" 2>/dev/null); then
    [ "$current" = "$url" ] ||
      die "task $id's copy already has a remote '$RESCUE_REMOTE' at '$current', not '$url'; it is left unchanged"
  fi
  create_repo "$(rescue_path "$project")"
  add_local_remote "$copy" "$url" "task $id's copy"
  echo "ready: task $id's copy pushes to remote '$RESCUE_REMOTE' at $url"
}

do_ensure_project() {  # <project-dir>
  local project=$1 url current
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || die "$project is not a git checkout"
  url=$(rescue_url "$project")
  if current=$(git -C "$project" remote get-url "$RESCUE_REMOTE" 2>/dev/null) && [ "$current" != "$url" ]; then
    die "$project already has a remote '$RESCUE_REMOTE' at '$current', not '$url'; it is left unchanged"
  fi
  create_repo "$(rescue_path "$project")"
  add_local_remote "$project" "$url" "$project"
  echo "ready: $project fetches from remote '$RESCUE_REMOTE' at $url"
}

do_holds() {  # <project-name> <branch> <head>
  local path actual
  path=$(rescue_path "$1")
  [ -d "$path" ] || die "no rescue repository at $path"
  actual=$(git -C "$path" rev-parse --verify --quiet "refs/heads/$2^{commit}" 2>/dev/null || true)
  [ "$actual" = "$3" ] || die "the rescue repository $path has $2 at '${actual:-nothing}', not $3"
  echo "holds: $path has $2 at $3"
}

do_host_url() {  # <project-name>
  local url
  url=$(rescue_host_url "$1") || exit 1
  create_repo "$(rescue_path "$1")" >&2
  printf '%s\n' "$url"
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

carried_landed() {
  local project=$1 from=$2 head=$3 tip=$4 base ref remote target fork patches merges patch
  base=$(meta_get "$DATA/$from/handoff-request" base_branch)
  [ -n "$base" ] || base=$(fm_default_branch "$project" || true)
  while IFS= read -r ref; do
    remote=${ref#refs/remotes/}
    remote=${remote%%/*}
    case "$remote" in fm-rescue|no-mistakes) continue ;; esac
    [ "$ref" = "refs/remotes/$remote/$base" ] || continue
    if git -C "$project" merge-base --is-ancestor "$head" "$ref" 2>/dev/null; then
      return 0
    fi
  done < <(git -C "$project" for-each-ref --format='%(refname)' refs/remotes/)
  target=$(meta_get "$DATA/$tip/rescue-pr" pr)
  [ -n "$target" ] || return 1
  fm_pr_read_merged_head "$project" "$target" || return 1
  git -C "$project" merge-base --is-ancestor "$head" "$FM_PR_MERGED_HEAD" 2>/dev/null && return 0

  # Rebase rewrites carried commits. Require every commit since the shared
  # base to have a patch-equivalent commit in the verified merged PR head.
  # Missing objects, merge commits (which cherry omits), or unmatched patches
  # leave the rescue refs intact rather than guessing that the work landed.
  fork=$(git -C "$project" merge-base "$head" "$FM_PR_MERGED_HEAD" 2>/dev/null) || return 1
  merges=$(git -C "$project" rev-list --merges "$fork..$head" 2>/dev/null) || return 1
  [ -z "$merges" ] || return 1
  patches=$(git -C "$project" cherry "$FM_PR_MERGED_HEAD" "$head" "$fork" 2>/dev/null) || return 1
  [ -n "$patches" ] || return 1
  while IFS= read -r patch; do
    case "$patch" in '- '*) ;; *) return 1 ;; esac
  done <<< "$patches"
  return 0
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

  cur=$tip
  while [ -f "$(fm_continuation_path "$DATA" "$cur")" ]; do
    next=$(sed -n 's/^continued_from=//p' "$(fm_continuation_path "$DATA" "$cur")" | head -n 1)
    fm_continuation_read "$DATA" "$cur" "$next" || die "$FM_CONT_ERROR"
    if [ "$FM_CONT_KIND" = ship ] && [ "$FM_CONT_REMOTE" = "$RESCUE_REMOTE" ]; then
      carried=1
      if [ "$flag" != --abandoned ] && ! carried_landed "$project" "$FM_CONT_FROM" "$FM_CONT_HEAD" "$tip"; then
        echo "retained: $FM_CONT_BRANCH; no proof of landing on its remote base branch or in a merged PR" >&2
        rc=1
        cur=$next
        continue
      fi
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
  ensure-project)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    do_ensure_project "$1"
    ;;
  host-url)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_task_id_path_safe "$1" || { echo "error: invalid project name '$1'" >&2; exit 2; }
    do_host_url "$1"
    ;;
  holds)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    fm_task_id_path_safe "$1" || { echo "error: invalid project name '$1'" >&2; exit 2; }
    do_holds "$@"
    ;;
  prune)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
    fm_task_id_path_safe "$1" || { echo "error: invalid task id '$1'" >&2; exit 2; }
    case "${3:-}" in
      ''|--abandoned) ;;
      *) echo "error: unknown option ${3}" >&2; exit 2 ;;
    esac
    do_prune "$1" "$2" "${3:-}"
    ;;
  *) usage >&2; exit 2 ;;
esac
