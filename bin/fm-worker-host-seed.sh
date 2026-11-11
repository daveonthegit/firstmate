#!/usr/bin/env bash
# Seed a registered worker host's home from the primary.
#
# Usage:
#   fm-worker-host-seed.sh <worker-host-id> --lanes <cap> [--capacity <project>=<n>]...
#       <project>[=<origin-url>]...
#
# Seeding is bin/fm-worker-host-doctor.sh --fix with the declarations a new host
# needs made explicit: the lane cap for its config/lane-capacity, and the
# projects it should work on. That doctor's header owns what is sent and what
# is checked, and bin/fm-worker-host-home.sh owns every repair on the host:
# the home beside (never inside) the code root with data/, state/, config/, and
# projects/; the .fm-worker-host marker; config/backlog-backend set to manual;
# the capacity files; one clone per project from its origin; the primary's
# registry line for each; and `no-mistakes init` in each no-mistakes project.
#
# Before the home is touched, the account's transport readiness must pass
# bin/fm-remote-doctor.sh, repaired where it can be. Seeding sends no
# credential, token, or state/ record and never makes the home a second-mate
# home; the host's sign-ins, including its own T3 sign-in, stay the operator's
# steps, which the final check lines name until they are done.
#
# Rerunning converges. Exit statuses are the doctor's: 0 ready, 1 a gap remains
# (often only a sign-in still to do on the host), 255 unknown completion.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -ge 1 ] || usage
case "$1" in -h|--help|-*) usage ;; esac
ID=$1
shift

ARGS=()
LANES_GIVEN=0
PROJECTS_GIVEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lanes)
      [ "$#" -ge 2 ] || usage
      LANES_GIVEN=1
      ARGS+=(--lanes "$2")
      shift
      ;;
    --capacity)
      [ "$#" -ge 2 ] || usage
      ARGS+=(--capacity "$2")
      shift
      ;;
    -h|--help|-*) usage ;;
    *)
      PROJECTS_GIVEN=1
      ARGS+=("$1")
      ;;
  esac
  shift
done
[ "$LANES_GIVEN" -eq 1 ] || die "--lanes <cap> is required: say how many workers this host runs at once"
[ "$PROJECTS_GIVEN" -eq 1 ] || die "name at least one project"

exec "$SCRIPT_DIR/fm-worker-host-doctor.sh" "$ID" --fix "${ARGS[@]}"
