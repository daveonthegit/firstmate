#!/usr/bin/env bash
# Check, and with --fix converge, one registered worker host from the primary.
#
# Usage:
#   fm-worker-host-doctor.sh <worker-host-id> [--fix] [--lanes <cap>]
#       [--capacity <project>=<n>]... [<project>[=<origin-url>]...]
#
# The host must already have a record in this home's data/worker-hosts.md
# (docs/configuration.md "Worker hosts"). This command runs two checks over the
# record's route, both through bin/fm-on.sh and so both on the host itself:
#   1. bin/fm-remote-doctor.sh, the account's transport readiness: the remote
#      job worker every later command runs through, its runtime PATH, and its
#      tools. Its lines are relayed with an `account: ` prefix. With --fix it
#      runs bin/fm-remote-readiness-lib.sh's check, repair, check sequence, and
#      the home is never touched while that verdict is red.
#   2. bin/fm-worker-host-home.sh, the worker host home itself, which owns
#      every home check and repair and prints them in its own line protocol.
#
# The primary's facts travel in the manifest that second command reads on
# stdin, so the host compares against the primary rather than guessing:
#   - each named project's registry line from this home's data/projects.md,
#     copied byte for byte so the host registers the same delivery mode and
#     forge binding; bin/fm-project-mode.sh must resolve it, and a local-only
#     project is refused because its work never leaves this machine;
#   - each named project's origin: <project>=<origin-url> when given, else this
#     home's clone's origin when it has one (bin/fm-project-origin-lib.sh owns
#     which URLs are accepted);
#   - the T3 version and capabilities the primary needs, read from this home's
#     own `bin/fm-t3-mcp.mjs status`; unavailable primary evidence remains
#     unresolved when this home has a T3 sign-in;
#   - --lanes and --capacity, the host's config/lane-capacity cap and
#     config/project-capacity lines, which --fix writes only where no different
#     value is already declared.
# With no project named, every non-local-only project this home registers is
# sent, and the host checks only those it already clones or registers.
#
# Nothing else crosses: no credential, token, config/ file, or state/ record of
# this home is ever sent, and no T3 sign-in is made for the host.
#
# Exit 0 when both checks pass, 1 when a gap remains, and 255 when SSH could not
# complete, which means the host's state is unknown: rerun the same command,
# because every repair converges.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MAX_MANIFEST_BYTES=1048576

# shellcheck source=bin/fm-worker-host-lib.sh
. "$SCRIPT_DIR/fm-worker-host-lib.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
encode() { base64 | tr -d '\n'; }
safe_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

[ "$#" -ge 1 ] || usage
case "$1" in -h|--help) usage ;; esac
ID=$1
shift
safe_id "$ID" || die "invalid worker host id: $ID"

FIX=0
LANES=
CAPACITY_ARGS=()
PROJECT_NAMES=()
PROJECT_ORIGINS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fix) FIX=1 ;;
    --lanes)
      [ "$#" -ge 2 ] || usage
      LANES=$2
      shift
      ;;
    --capacity)
      [ "$#" -ge 2 ] || usage
      CAPACITY_ARGS+=("$2")
      shift
      ;;
    -h|--help) usage ;;
    -*) usage ;;
    *)
      name=${1%%=*}
      origin=
      case "$1" in *=*) origin=${1#*=} ;; esac
      safe_id "$name" || die "invalid project name: $name"
      if [ -n "$origin" ]; then
        fm_project_origin_credential_free "$origin" || die "project $name requires a credential-free clone URL; authenticate on the host"
      fi
      PROJECT_NAMES+=("$name")
      PROJECT_ORIGINS+=("$origin")
      ;;
  esac
  shift
done
case "$LANES" in ''|[0-9]|[0-9][0-9]|[0-9][0-9][0-9]) ;; *) die "--lanes must be a whole number below 1000: $LANES" ;; esac

WORKER_REG=$(worker_host_registry_path "$DATA")
[ -f "$WORKER_REG" ] && [ ! -L "$WORKER_REG" ] \
  || die "no worker host registry at $WORKER_REG; register the host first (docs/remote-workers.md)"
FOUND=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '- '*) ;; *) continue ;; esac
  worker_host_parse_line "$line" || die "malformed worker host registry entry: $line"
  [ "$WORKER_HOST_ID" = "$ID" ] || continue
  FOUND=1
  break
done < "$WORKER_REG"
[ "$FOUND" -eq 1 ] || die "no worker host $ID in $WORKER_REG; register it first (docs/remote-workers.md)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-worker-host-doctor.XXXXXX") || die "cannot create a staging directory"
trap 'rm -rf -- "$TMP"' EXIT

# --- the manifest ----------------------------------------------------------------

REG="$DATA/projects.md"
SCOPE=named
if [ "${#PROJECT_NAMES[@]}" -eq 0 ]; then
  SCOPE=present
  if [ -f "$REG" ]; then
    while IFS= read -r name; do
      PROJECT_NAMES+=("$name")
      PROJECT_ORIGINS+=("")
    done < <(awk '/^- / { name = $2; if (name ~ /^[A-Za-z0-9._-]+$/) print name }' "$REG")
  fi
fi

: > "$TMP/projects"
SENT=0
i=0
while [ "$i" -lt "${#PROJECT_NAMES[@]}" ]; do
  project=${PROJECT_NAMES[$i]}
  origin=${PROJECT_ORIGINS[$i]}
  i=$((i + 1))
  if ! mode_line=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$project" 2>"$TMP/mode.err"); then
    [ "$SCOPE" = present ] && continue
    cat "$TMP/mode.err" >&2
    die "project $project does not resolve to a delivery posture"
  fi
  mode=${mode_line%% *}
  case "$mode" in
    no-mistakes|direct-PR) ;;
    local-only)
      [ "$SCOPE" = present ] && continue
      die "project $project is local-only, so its work never runs on a worker host"
      ;;
    *) die "project $project has an unsupported delivery mode: $mode" ;;
  esac
  registry_line=$(awk -v p="- $project " 'index($0, p) == 1 { print; exit }' "$REG" 2>/dev/null || true)
  [ -n "$registry_line" ] || die "project $project has no record in $REG"
  if [ -z "$origin" ] && [ -d "$PROJECTS/$project/.git" ]; then
    origin=$(git -C "$PROJECTS/$project" remote get-url origin 2>/dev/null || true)
    if [ -n "$origin" ] && ! fm_project_origin_credential_free "$origin"; then
      die "project $project requires a credential-free clone URL; authenticate on the host"
    fi
  fi
  printf 'project=%s|%s|%s|%s\n' \
    "$(printf '%s' "$project" | encode)" \
    "$(if [ -n "$origin" ]; then printf '%s' "$origin" | encode; fi)" \
    "$(printf '%s' "$registry_line" | encode)" \
    "$(printf '%s' "$mode" | encode)" >> "$TMP/projects"
  SENT=$((SENT + 1))
done

: > "$TMP/capacity"
for arg in ${CAPACITY_ARGS[@]+"${CAPACITY_ARGS[@]}"}; do
  case "$arg" in *=*) ;; *) die "--capacity takes <project>=<n>: $arg" ;; esac
  name=${arg%%=*}
  value=${arg#*=}
  safe_id "$name" || die "invalid capacity project name: $name"
  case "$value" in [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) die "--capacity for $name must be a positive whole number below 1000: $value" ;; esac
  printf 'capacity=%s|%s\n' "$(printf '%s' "$name" | encode)" "$value" >> "$TMP/capacity"
done

# The T3 facts this primary runs on, from its own sign-in. They are versions and
# capability names only; the credential itself never leaves this machine.
T3_VERSION=
T3_CAPS=
T3_NOTE=
T3_REQUIRED=1
TOKEN="$CONFIG/t3code-token"
if [ ! -e "$TOKEN" ] && [ ! -L "$TOKEN" ]; then
  T3_REQUIRED=0
  T3_NOTE="the primary has no T3 sign-in"
elif ! command -v node >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  T3_NOTE="the primary cannot read its own T3 status without node and jq"
elif ! status_json=$(node "$SCRIPT_DIR/fm-t3-mcp.mjs" status --token-file "$TOKEN" 2>"$TMP/t3.err"); then
  T3_NOTE="the primary's own T3 status could not be read"
else
  T3_VERSION=$(printf '%s' "$status_json" | jq -r '.serverVersion // empty')
  T3_CAPS=$(printf '%s' "$status_json" \
    | jq -r '[("launchEnvironment", "sessionStop", "keepAlive") as $c | select(.[$c] == true) | $c] | join(",")')
fi

{
  printf 'schema=fm-worker-host-home.v1\n'
  printf 'host_id_b64=%s\n' "$(printf '%s' "$ID" | encode)"
  printf 't3_required=%s\n' "$T3_REQUIRED"
  [ -z "$LANES" ] || printf 'lanes=%s\n' "$LANES"
  cat "$TMP/capacity"
  [ -z "$T3_VERSION" ] || printf 't3_version_b64=%s\n' "$(printf '%s' "$T3_VERSION" | encode)"
  [ -z "$T3_CAPS" ] || printf 't3_capabilities=%s\n' "$T3_CAPS"
  [ -z "$T3_NOTE" ] || printf 't3_note_b64=%s\n' "$(printf '%s' "$T3_NOTE" | encode)"
  printf 'project_scope=%s\n' "$SCOPE"
  printf 'project_count=%s\n' "$SENT"
  cat "$TMP/projects"
} > "$TMP/manifest"
[ "$(LC_ALL=C wc -c < "$TMP/manifest" | tr -d ' ')" -le "$MAX_MANIFEST_BYTES" ] \
  || die "the worker host manifest exceeds the $MAX_MANIFEST_BYTES-byte bound"

# --- the account, then the home ----------------------------------------------------

relay_account() { # <output>
  [ -z "$1" ] || printf '%s\n' "$1" | sed 's/^/account: /'
}

set +e
if [ "$FIX" -eq 1 ]; then
  fm_remote_readiness_ensure "$SCRIPT_DIR" "$ID"
  ACCOUNT_RC=$?
  ACCOUNT_OUT=$FM_REMOTE_READINESS_OUT
else
  ACCOUNT_OUT=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-doctor.sh </dev/null 2>&1)
  ACCOUNT_RC=$?
fi
set -e
relay_account "$ACCOUNT_OUT"
if [ "$ACCOUNT_RC" -eq 255 ]; then
  printf 'error: worker host %s could not be reached, so its state is unknown; rerun this command once SSH answers\n' "$ID" >&2
  exit 255
fi
if [ "$FIX" -eq 1 ] && [ "$ACCOUNT_RC" -ne 0 ]; then
  printf 'error: worker host %s account is not ready, so its home was not changed; close the account gaps above and rerun\n' "$ID" >&2
  exit 1
fi

HOME_ARGS=()
[ "$FIX" -eq 0 ] || HOME_ARGS=(--fix)
set +e
"$SCRIPT_DIR/fm-on.sh" --stdin "$ID" fm-worker-host-home.sh ${HOME_ARGS[@]+"${HOME_ARGS[@]}"} < "$TMP/manifest"
HOME_RC=$?
set -e
if [ "$HOME_RC" -eq 255 ]; then
  printf 'error: worker host %s could not be reached, so its home state is unknown; rerun this command once SSH answers\n' "$ID" >&2
  exit 255
fi
[ "$HOME_RC" -eq 0 ] && [ "$ACCOUNT_RC" -eq 0 ] && exit 0
exit 1
