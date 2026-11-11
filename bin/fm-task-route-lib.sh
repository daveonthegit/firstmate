#!/usr/bin/env bash
# shellcheck disable=SC2034 # route fields are output globals for sourcing callers.
# Shared routing helper: where does the task a record names actually run?
#
#   fm_task_route <meta>
#
# Every entry point that acts on one task (spawn, steer, state, peek, control,
# answer, cleanup) reads the task record, state/<id>.meta, and must tell three
# cases apart before it touches anything, because each lives somewhere else:
#
#   local              the worker runs in this home; every recorded endpoint,
#                      worktree, and project path is a path on this machine.
#   worker-host        a ship or scout this primary placed on a worker host
#                      (docs/remote-workers.md): the record names the host with
#                      remote_worker_host=<id>, its remote_* keys name the
#                      host's own home, endpoint, and copy. Steer, state,
#                      peek, lifecycle control, and answer run
#                      bin/fm-remote-worker-control.sh there through
#                      bin/fm-on.sh <FM_TASK_ROUTE_HOST>, never a local
#                      backend; cleanup runs the host's own fm-teardown
#                      there first (bin/fm-teardown.sh's worker-host
#                      cleanup); a local spawn or relaunch, and a forced
#                      second-mate retirement over a placed child record,
#                      refuse through fm_task_route_require_supported.
#   remote-secondmate  a persistent second mate on another machine: the record
#                      names its SSH alias with remote_host=<alias>, and its
#                      operations run bin/fm-remote-secondmate-control.sh.
#
# On success it sets FM_TASK_ROUTE to one of those words and FM_TASK_ROUTE_HOST
# to the worker host id or second-mate SSH alias (empty for local), and returns
# 0. It returns 1 with FM_TASK_ROUTE_ERROR set, and both route fields empty,
# when the record is missing, unreadable, symlinked, not a regular file,
# names an unsafe worker host id, or
# names BOTH remote_worker_host and remote_host: such a record is
# contradictory, so a caller refuses it rather than guess which leg owns it.
# A placed task never records remote_host, exactly so that the entry points
# which already route on remote_host never send it down the second-mate leg.
# The keys are read like fm_meta_get reads them (the last line wins); this file
# sources nothing, so any script can use it.

FM_TASK_ROUTE=
FM_TASK_ROUTE_HOST=
FM_TASK_ROUTE_ERROR=

fm_task_route_key() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_task_route() {  # <meta>
  local meta=$1 worker secondmate
  FM_TASK_ROUTE=
  FM_TASK_ROUTE_HOST=
  FM_TASK_ROUTE_ERROR=
  if [ ! -f "$meta" ] || [ -L "$meta" ] || [ ! -r "$meta" ]; then
    FM_TASK_ROUTE_ERROR="no readable task record at $meta"
    return 1
  fi
  worker=$(fm_task_route_key "$meta" remote_worker_host)
  secondmate=$(fm_task_route_key "$meta" remote_host)
  if [ -n "$worker" ] && [ -n "$secondmate" ]; then
    FM_TASK_ROUTE_ERROR="task record $meta names both worker host $worker and remote second-mate host $secondmate"
    return 1
  fi
  if [ -n "$worker" ]; then
    case "$worker" in
      -*|*[!A-Za-z0-9._-]*)
        FM_TASK_ROUTE_ERROR="task record $meta names an unsafe worker host id: $worker"
        return 1
        ;;
    esac
    FM_TASK_ROUTE='worker-host'
    FM_TASK_ROUTE_HOST=$worker
  elif [ -n "$secondmate" ]; then
    FM_TASK_ROUTE='remote-secondmate'
    FM_TASK_ROUTE_HOST=$secondmate
  else
    FM_TASK_ROUTE=local
  fi
  return 0
}

# fm_task_route_require_supported <meta> <operation>: route the record and
# refuse, naming the host, when it is placed on a worker host, for an entry
# point that has no worker-host branch (today: a local spawn or relaunch,
# and a forced second-mate retirement over a placed child record).
fm_task_route_require_supported() {
  fm_task_route "$1" || {
    printf 'error: %s\n' "$FM_TASK_ROUTE_ERROR" >&2
    return 1
  }
  if [ "$FM_TASK_ROUTE" = worker-host ]; then
    printf 'error: task placed on worker host %s; %s is not yet supported\n' "$FM_TASK_ROUTE_HOST" "$2" >&2
    return 1
  fi
}
