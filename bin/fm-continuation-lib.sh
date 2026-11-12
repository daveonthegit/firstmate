# shellcheck shell=bash
# Continuation record: what a task continued from another task carries over.
# Usage: . bin/fm-continuation-lib.sh
#
# This file is the single owner of the record bin/fm-handoff.sh writes at
# data/<new-id>/continuation and bin/fm-brief.sh and bin/fm-spawn.sh read when
# they are passed --continue-from <old-id>. One record per continuation task,
# key=value lines, written once and never edited:
#   schema=fm-continuation.v1
#   continued_from=<old-id>
#   kind=<ship|scout>
#   to=local
#   remote=<git remote name>       ship only
#   branch=<carried branch name>   ship only
#   head=<40-hex commit>           ship only
# A ship carries its committed work on <branch> at <head>, pushed to <remote>,
# so the new copy starts from exactly that commit. A scout's copy is scratch:
# it carries nothing through git (its interim report and notes live under
# data/<old-id>/), so its remote, branch, and head are absent and the new copy
# starts from the base as any scout does.
# A brief made with --continue-from records the source task as one
# "Continued from: <old-id>" line under `# Setup` (fm_brief_continued_from).

if ! declare -F fm_task_id_creation_valid >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"
fi
if ! declare -F fm_brief_heading_body >/dev/null 2>&1; then
  # shellcheck source=bin/fm-brief-heading-lib.sh disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-brief-heading-lib.sh"
fi

FM_CONTINUATION_SCHEMA=fm-continuation.v1
# Set by fm_continuation_read on success.
# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
FM_CONT_FROM=''
FM_CONT_KIND=''
FM_CONT_TO=''
FM_CONT_REMOTE=''
FM_CONT_BRANCH=''
FM_CONT_HEAD=''
# Set by the functions below when they fail.
FM_CONT_ERROR=

fm_continuation_path() {  # <data-dir> <new-id>
  printf '%s/%s/continuation\n' "$1" "$2"
}

fm_continuation_remote_valid() {  # <remote>
  case "${1-}" in
    '' | -* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_continuation_fields_valid() {  # <kind> <remote> <branch> <head>
  local kind=$1 remote=$2 branch=$3 head=$4
  case "$kind" in
    ship)
      fm_continuation_remote_valid "$remote" || {
        FM_CONT_ERROR="remote '$remote' is not a git remote name"
        return 1
      }
      git check-ref-format --branch "$branch" >/dev/null 2>&1 || {
        FM_CONT_ERROR="branch '$branch' is not a valid branch name"
        return 1
      }
      printf '%s\n' "$head" | grep -Eqx '[0-9a-f]{40}' || {
        FM_CONT_ERROR="head '$head' is not a full commit id"
        return 1
      }
      ;;
    scout)
      [ -z "$remote$branch$head" ] || {
        FM_CONT_ERROR="a scout continuation carries no remote, branch, or head"
        return 1
      }
      ;;
    *)
      FM_CONT_ERROR="kind '$kind' is not ship or scout"
      return 1
      ;;
  esac
}

# Write the record atomically. Refuses to replace an existing record that
# differs; an identical one is accepted, so a resumed hand-off is idempotent.
fm_continuation_write() {  # <data-dir> <new-id> <old-id> <kind> <remote> <branch> <head>
  local data=$1 new_id=$2 old_id=$3 kind=$4 remote=$5 branch=$6 head=$7 path tmp body
  FM_CONT_ERROR=
  if ! fm_task_id_creation_valid "$new_id" || ! fm_task_id_creation_valid "$old_id"; then
    FM_CONT_ERROR="invalid task id"
    return 1
  fi
  [ "$new_id" != "$old_id" ] || {
    FM_CONT_ERROR="a task cannot continue itself"
    return 1
  }
  fm_continuation_fields_valid "$kind" "$remote" "$branch" "$head" || return 1
  body="schema=$FM_CONTINUATION_SCHEMA"$'\n'"continued_from=$old_id"$'\n'"kind=$kind"$'\n'"to=local"$'\n'
  [ "$kind" != ship ] || body+="remote=$remote"$'\n'"branch=$branch"$'\n'"head=$head"$'\n'
  path=$(fm_continuation_path "$data" "$new_id")
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ -f "$path" ] && [ ! -L "$path" ] && [ "$(cat "$path")"$'\n' = "$body" ]; then
      return 0
    fi
    FM_CONT_ERROR="$path already exists with different content"
    return 1
  fi
  mkdir -p "$data/$new_id" || {
    FM_CONT_ERROR="could not create $data/$new_id"
    return 1
  }
  tmp="$path.tmp.$$"
  if ! { printf '%s' "$body" > "$tmp" && mv -f "$tmp" "$path"; }; then
    rm -f "$tmp"
    FM_CONT_ERROR="could not write $path"
    return 1
  fi
}

# Read and validate the record for <new-id>, which must name <old-id>.
fm_continuation_read() {  # <data-dir> <new-id> <old-id>
  local data=$1 new_id=$2 old_id=$3 path line key value seen=' ' schema=''
  local from='' kind='' to='' remote='' branch='' head=''
  FM_CONT_ERROR=
  path=$(fm_continuation_path "$data" "$new_id")
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    FM_CONT_ERROR="no continuation record at $path; bin/fm-handoff.sh writes it"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || {
      FM_CONT_ERROR="$path has a malformed line: $line"
      return 1
    }
    case "$seen" in *" $key "*)
      FM_CONT_ERROR="$path repeats $key"
      return 1
      ;;
    esac
    seen+="$key "
    case "$key" in
      schema) schema=$value ;;
      continued_from) from=$value ;;
      kind) kind=$value ;;
      to) to=$value ;;
      remote) remote=$value ;;
      branch) branch=$value ;;
      head) head=$value ;;
      *)
        FM_CONT_ERROR="$path has an unknown key: $key"
        return 1
        ;;
    esac
  done < "$path"
  [ "$schema" = "$FM_CONTINUATION_SCHEMA" ] || {
    FM_CONT_ERROR="$path is not a $FM_CONTINUATION_SCHEMA record"
    return 1
  }
  [ "$from" = "$old_id" ] || {
    FM_CONT_ERROR="$path continues '${from:-nothing}', not '$old_id'"
    return 1
  }
  [ "$to" = local ] || {
    FM_CONT_ERROR="$path names target '${to:-nothing}'; only local continuations exist"
    return 1
  }
  fm_continuation_fields_valid "$kind" "$remote" "$branch" "$head" || {
    FM_CONT_ERROR="$path: $FM_CONT_ERROR"
    return 1
  }
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  {
    FM_CONT_FROM=$from
    FM_CONT_KIND=$kind
    FM_CONT_TO=$to
    FM_CONT_REMOTE=$remote
    FM_CONT_BRANCH=$branch
    FM_CONT_HEAD=$head
  }
}

# Print every "Continued from: <id>" line in the brief's `# Setup` section;
# return 1 when there is none.
fm_brief_continued_from() {  # <brief>
  fm_brief_heading_body "$1" "# Setup" | awk '
    sub(/^Continued from: /, "") { print; n++ }
    END { exit !n }
  '
}
