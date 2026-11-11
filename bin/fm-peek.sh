#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
# A selector whose meta records remote_host= is a remote secondmate: its pane
# lives on that host, so the capture routes over fm-on.sh to the host-local
# capture (fm-remote-secondmate-control.sh), clamped to that command's
# 100-line cap. An unreachable host or unreadable endpoint fails loudly naming
# the host; the local backend adapters are never asked to read a remote target.
# A selector whose meta records remote_worker_host= is a ship or scout placed on
# a worker host (bin/fm-task-route-lib.sh): the capture routes over fm-on.sh to
# that host's fm-remote-worker-control.sh capture, under the same 100-line
# clamp, and an unreachable host or SSH exit 255 fails naming the host without
# claiming the worker is dead.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
N=${2:-40}

# shellcheck source=bin/fm-task-route-lib.sh
. "$SCRIPT_DIR/fm-task-route-lib.sh"
REMOTE_META=$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)
if [ -z "$REMOTE_META" ]; then
  REMOTE_META=$(fm_backend_meta_for_window "$RAW_TARGET" "$STATE" 2>/dev/null || true)
fi
if [ -n "$REMOTE_META" ]; then
  fm_task_route "$REMOTE_META" || { printf 'error: %s\n' "$FM_TASK_ROUTE_ERROR" >&2; exit 1; }
fi
if [ -n "$REMOTE_META" ] && [ "$FM_TASK_ROUTE" = worker-host ]; then
  REMOTE_ID=${REMOTE_META##*/}
  REMOTE_ID=${REMOTE_ID%.meta}
  case "$N" in ''|*[!0-9]*|0) N=40 ;; esac
  [ "$N" -le 100 ] || N=100
  rc=0
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$FM_TASK_ROUTE_HOST" \
    fm-remote-worker-control.sh capture "$REMOTE_ID" "$N" < /dev/null || rc=$?
  case "$rc" in
    0) exit 0 ;;
    255) echo "error: could not read the pane of $REMOTE_ID on worker host $FM_TASK_ROUTE_HOST (host unreachable or its answer was lost; the worker is not thereby dead)" >&2 ;;
    *) echo "error: worker host $FM_TASK_ROUTE_HOST could not read the pane of $REMOTE_ID (exit $rc; its reason is above; the worker is not thereby dead)" >&2 ;;
  esac
  exit 1
fi
if [ -n "$REMOTE_META" ] && [ "$FM_TASK_ROUTE" = remote-secondmate ]; then
  REMOTE_ID=${REMOTE_META##*/}
  REMOTE_ID=${REMOTE_ID%.meta}
  REMOTE_HOST=$(fm_meta_get "$REMOTE_META" remote_host)
  case "$N" in ''|*[!0-9]*|0) N=40 ;; esac
  [ "$N" -le 100 ] || N=100
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$REMOTE_ID" \
    fm-remote-secondmate-control.sh capture "$REMOTE_ID" "$N" < /dev/null; then
    echo "error: could not read the remote pane of $REMOTE_ID on $REMOTE_HOST (host unreachable or endpoint unreadable; the mate is not thereby dead)" >&2
    exit 1
  fi
  exit 0
fi

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
