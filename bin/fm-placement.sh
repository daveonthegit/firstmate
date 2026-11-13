#!/usr/bin/env bash
# fm-placement.sh - choose which machine runs a fresh ship or scout, by load.
#
# Usage:
#   fm-placement.sh <project> [--local-dir <dir>]
#
# Automatic placement (docs/configuration.md "Automatic placement") treats this
# supervisor's own machine and every worker host in data/worker-hosts.md as
# equals and asks each for its own capacity report; bin/fm-spawn.sh runs this
# when config/auto-placement is set and no machine was named. It is also safe
# to run by hand to see where a task would go. It never spawns, locks, or
# changes anything.
#
# <project> is the project's clone directory name. --local-dir names this
# machine's clone of it (default projects/<project> in this home).
#
# Eligibility. This machine is eligible when that clone is a git checkout. A
# worker host is eligible when its home has the project's clone: the seeded
# projects fact (bin/fm-worker-host-seed.sh) answered by the host leg's
# `headroom` verb (bin/fm-remote-worker-control.sh) through bin/fm-on.sh.
# Projects are never seeded here. A host whose record id is `local` is skipped,
# because `local` names this machine.
#
# Load signal. Each machine's own bin/fm-capacity.sh report: its open lanes
# against its own config/lane-capacity cap, with free_lanes forced to 0 by any
# host constraint (cpu load, memory, disk, pressure, max-load1, reserve,
# battery). A host's report counts the tasks placed on it, and this machine's
# report does not count them (bin/fm-capacity.sh), so each task counts once,
# against the machine it runs on. A machine admits the task when its report
# says reason=ok with free lanes above 0.
#
# Skipped, never treated as free and never an error: a host that cannot be
# reached (SSH exit 255) or does not answer within FM_PLACEMENT_PROBE_TIMEOUT
# seconds (default 30), a host whose leg refuses or answers without a report,
# a host without the project, and a host with no or an unreadable lane cap.
# This machine needs its own lane cap: with config/lane-capacity absent or
# unreadable the command exits 1, because the setting is on and this
# machine's share cannot be judged.
#
# Ranking among the machines that admit: the larger open share of the
# machine's own cap first (free lanes divided by its cap, so a 3-lane and a
# 6-lane machine are compared fairly); on a tie, more open lanes; on a further
# tie, this machine before worker hosts, then worker hosts in registry order.
#
# Output: one human line per machine on stdout, each starting "placement: ",
# naming its open lanes, cap, load, and free memory, or why it was skipped or
# does not admit; then one last line "order: <machine>..." listing the
# admitting machines best first, `local` for this machine. An empty order means
# nothing admits the task now, and the caller leaves it queued.
#
# Environment: FM_HOME and the FM_*_OVERRIDE variables resolve the home as the
# other bin/ scripts do; FM_PLACEMENT_PROBE_TIMEOUT bounds each host check.
#
# Exit status: 0 with a decision (possibly an empty order), 1 when this
# machine's lane cap or the worker host registry is unusable, 2 on usage.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
PROBE_TIMEOUT=${FM_PLACEMENT_PROBE_TIMEOUT:-30}
case "$PROBE_TIMEOUT" in ''|*[!0-9]*|0) PROBE_TIMEOUT=30 ;; esac

# shellcheck source=bin/fm-worker-host-lib.sh
. "$SCRIPT_DIR/fm-worker-host-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() { echo "usage: fm-placement.sh <project> [--local-dir <dir>]" >&2; exit 2; }

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
esac
[ "$#" -ge 1 ] || usage
PROJECT=$1
shift
LOCAL_DIR=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --local-dir) [ "$#" -ge 2 ] || usage; LOCAL_DIR=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$PROJECT" in
  ''|-*|.*|*[!A-Za-z0-9._-]*)
    echo "error: fm-placement.sh needs a project clone directory name (got '$PROJECT')" >&2
    exit 2
    ;;
esac
[ -n "$LOCAL_DIR" ] || LOCAL_DIR="$PROJECTS/$PROJECT"

# report_field <report-line> <key>
report_field() {
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

CANDIDATES=
# judge <machine> <label> <rank> <report-line>: print the machine's line, and
# add it to CANDIDATES when it admits.
judge() {
  local machine=$1 label=$2 rank=$3 report=$4 free reason lanes target load1 cores mem detail
  free=$(report_field "$report" free_lanes)
  reason=$(report_field "$report" reason)
  lanes=$(report_field "$report" lanes)
  target=$(report_field "$report" target)
  load1=$(report_field "$report" load1)
  cores=$(report_field "$report" cores)
  mem=$(report_field "$report" mem_free_pct)
  detail="load ${load1:-unknown} on ${cores:-unknown} cores, memory ${mem:-unknown}% free"
  [ "${mem:-unknown}" != unknown ] || detail="load ${load1:-unknown} on ${cores:-unknown} cores, memory unknown"
  if [ "$(report_field "$report" budget_measured)" = false ]; then
    printf 'placement: %s skipped - no measured adaptive budget yet (ceiling-only fallback)\n' "$label"
    return 1
  fi
  case "$target" in
    unknown)
      printf 'placement: %s skipped - adaptive lane budget unavailable (%s)\n' "$label" "$reason"
      return 1
      ;;
    none)
      printf 'placement: %s skipped - no lane cap declared (config/lane-capacity), so its share cannot be compared\n' "$label"
      return 1
      ;;
    invalid|'')
      printf 'placement: %s skipped - its lane cap is unreadable (config/lane-capacity)\n' "$label"
      return 1
      ;;
  esac
  case "$free" in ''|*[!0-9]*) free=0 ;; esac
  if [ "$reason" = ok ] && [ "$free" -gt 0 ] && [ "$target" -gt 0 ] 2>/dev/null; then
    printf 'placement: %s admits - %s of %s lanes open (%s running; %s)\n' "$label" "$free" "$target" "${lanes:-0}" "$detail"
    CANDIDATES="$CANDIDATES$((free * 1000000 / target)) $free $rank $machine"$'\n'
    return 0
  fi
  [ "$reason" != full ] || reason="full, $lanes of $target lanes running"
  printf 'placement: %s does not admit - %s (%s)\n' "$label" "$reason" "$detail"
  return 1
}

# --- this machine -----------------------------------------------------------
if [ -d "$LOCAL_DIR" ] && git -C "$LOCAL_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  rc=0
  report=$("$SCRIPT_DIR/fm-capacity.sh" 2>/dev/null | head -n 1) || rc=$?
  case "$(report_field "$report" target)" in
    none)
      echo "error: automatic placement is on but this machine declares no lane cap; write config/lane-capacity (docs/configuration.md \"Lane capacity\")" >&2
      exit 1
      ;;
    invalid|'')
      echo "error: automatic placement is on but this machine's lane cap is unreadable; bin/fm-capacity.sh names the problem" >&2
      exit 1
      ;;
  esac
  judge local "this machine" 0 "$report" || true
else
  printf 'placement: this machine skipped - it has no clone of %s\n' "$PROJECT"
fi

# --- worker hosts -----------------------------------------------------------
rc=0
ids=$(worker_host_ids "$DATA") || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "error: the worker host registry is unusable: $WORKER_HOST_ERROR" >&2
  exit 1
fi
rank=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  rank=$((rank + 1))
  if [ "$id" = local ]; then
    printf 'placement: worker host local skipped - the id local names this machine\n'
    continue
  fi
  rc=0
  out=$(fm_run_timed "$PROBE_TIMEOUT" "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-worker-control.sh headroom "$PROJECT" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    255) printf 'placement: worker host %s skipped - unreachable\n' "$id"; continue ;;
    124) printf 'placement: worker host %s skipped - no answer within %s s\n' "$id" "$PROBE_TIMEOUT"; continue ;;
    *) printf 'placement: worker host %s skipped - its check failed (exit %s; bin/fm-worker-host-doctor.sh %s names the gap)\n' "$id" "$rc" "$id"; continue ;;
  esac
  if [ "$(printf '%s\n' "$out" | sed -n 's/^cloned=//p' | head -n 1)" != yes ]; then
    printf 'placement: worker host %s skipped - it has no clone of %s\n' "$id" "$PROJECT"
    continue
  fi
  report=$(printf '%s\n' "$out" | grep '^capacity: ' | head -n 1)
  if [ -z "$report" ]; then
    printf 'placement: worker host %s skipped - it answered without a capacity report\n' "$id"
    continue
  fi
  judge "$id" "worker host $id" "$rank" "$report" || true
done <<EOF
$ids
EOF

# --- decision ---------------------------------------------------------------
order=$(printf '%s' "$CANDIDATES" | sort -k1,1nr -k2,2nr -k3,3n | awk '{print $4}' | paste -sd ' ' -)
if [ -n "$order" ]; then
  first=${order%% *}
  if [ "$first" = local ]; then
    printf 'placement: chose this machine\n'
  else
    printf 'placement: chose worker host %s\n' "$first"
  fi
else
  printf 'placement: no machine admits the task now\n'
fi
printf 'order: %s\n' "$order"
exit 0
