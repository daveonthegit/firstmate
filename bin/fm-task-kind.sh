#!/usr/bin/env bash
# Resolve a task's classification from its authoritative metadata record.
# Usage: bash bin/fm-task-kind.sh <task.meta>
# May also be sourced to call fm_task_kind <task.meta>.

fm_task_kind() {
  local meta=${1:?task metadata required} line kind=''
  if [ -f "$meta" ] && [ -r "$meta" ] && [ ! -L "$meta" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in kind=*) kind=${line#kind=} ;; esac
    done < "$meta"
  fi
  case "$kind" in
    scout|secondmate) printf '%s\n' "$kind" ;;
    *) printf '%s\n' ship ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  fm_task_kind "${1:?usage: fm-task-kind.sh <task.meta>}"
fi
