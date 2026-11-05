#!/usr/bin/env bash
# Execute one tracked Firstmate command in a configured remote Firstmate home.
#
# Usage:
#   fm-on.sh [--stdin] <secondmate-id|worker-host-id|unambiguous-ssh-alias> <fm-command> [args...]
#
# Routes come only from remote records in data/secondmates.md and from worker
# host records in data/worker-hosts.md (bin/fm-worker-host-lib.sh). A record
# names an SSH config alias, remote Firstmate code root, and remote FM_HOME.
# A route selects a record when exactly one record across both registries has
# that id or that host alias; anything else is refused as ambiguous.
# The command must be a genuine executable in this checkout's bin/fm-*.sh
# namespace. No per-command table exists.
#
# argv is encoded as one NUL-delimited stream and passed through the fixed
# fm-remote-entrypoint.sh. The remote command's stdin is /dev/null by default,
# because remote staging captures stdin to EOF and an open caller stream would
# block staging indefinitely; a payload caller passes --stdin to forward its
# own stream as the job's bounded input. stdout and stderr remain separate, and
# ssh's exit status is returned unchanged. OpenSSH never receives an auto-retry
# instruction here. Exit 255 therefore means unavailable transport or unknown
# remote completion and must be reconciled by the semantic caller, never
# blindly repeated by this layer.
#
# The SSH alias keeps normal public-key and strict host-key policy in ~/.ssh.
# This command explicitly disables agent forwarding, forwarding setup, and
# configured SendEnv patterns. The remote entrypoint executes the selected
# command under an empty environment with only its fixed runtime values.
#
# ServerAliveInterval/ServerAliveCountMax arm dead-peer detection so a vanished
# peer (a reboot, a dropped link) becomes a bounded ssh failure (exit 255)
# instead of an indefinite hang on a half-open TCP connection. The remote
# sshd answers keepalive probes independently of whatever the remote command
# is doing, so a legitimately long-but-alive remote command is never falsely
# killed. FM_SSH_ALIVE_INTERVAL and FM_SSH_ALIVE_COUNT_MAX override the
# defaults; the worst-case detection window is roughly interval * count.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
PROTOCOL=1

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-worker-host-lib.sh
. "$SCRIPT_DIR/fm-worker-host-lib.sh"
WORKER_REG=$(worker_host_registry_path "$DATA")

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

encode_base64() {
  base64 | tr -d '\n'
}

STDIN_MODE=closed
if [ "${1:-}" = --stdin ]; then
  STDIN_MODE=caller
  shift
fi
[ "$#" -ge 2 ] || usage
ROUTE=$1
COMMAND=$2
shift 2

case "$ROUTE" in ''|-*|*[!A-Za-z0-9._-]*) die "remote route must be a safe secondmate id, worker host id, or SSH alias: $ROUTE" ;; esac
case "$COMMAND" in
  fm-*.sh) ;;
  *) die "remote command must be a basename in the fm-*.sh namespace: $COMMAND" ;;
esac
case "$COMMAND" in */*|*..*) die "remote command must not contain a path or traversal: $COMMAND" ;; esac
LOCAL_COMMAND="$FM_ROOT/bin/$COMMAND"
[ -f "$LOCAL_COMMAND" ] && [ ! -L "$LOCAL_COMMAND" ] && [ -x "$LOCAL_COMMAND" ] \
  || die "remote command is not a genuine tracked executable in this Firstmate checkout: $COMMAND"
git -C "$FM_ROOT" ls-files --error-unmatch "bin/$COMMAND" >/dev/null 2>&1 \
  || die "remote command is not tracked by this Firstmate checkout: $COMMAND"
REG_PRESENT=0
if [ -e "$REG" ] || [ -L "$REG" ]; then
  [ -f "$REG" ] && [ ! -L "$REG" ] || die "no safe secondmate registry at $REG"
  REG_PRESENT=1
fi
WORKER_REG_PRESENT=0
if [ -e "$WORKER_REG" ] || [ -L "$WORKER_REG" ]; then
  [ -f "$WORKER_REG" ] && [ ! -L "$WORKER_REG" ] || die "no safe worker host registry at $WORKER_REG"
  WORKER_REG_PRESENT=1
fi
[ "$REG_PRESENT" -eq 1 ] || [ "$WORKER_REG_PRESENT" -eq 1 ] \
  || die "no safe secondmate registry at $REG and no worker host registry at $WORKER_REG"

# A record matches when its id or its SSH alias equals the route; exactly one
# matching record across both registries selects it.
MATCHES=0
HOST=
ROOT=
HOME_PATH=
note_match() { # <id> <host> <root> <home>
  if [ "$1" = "$ROUTE" ] || [ "$2" = "$ROUTE" ]; then
    MATCHES=$((MATCHES + 1))
    HOST=$2 ROOT=$3 HOME_PATH=$4
  fi
}
if [ "$REG_PRESENT" -eq 1 ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
    note_match "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_ROOT" "$SECONDMATE_REGISTRY_HOME"
  done < "$REG"
fi
if [ "$WORKER_REG_PRESENT" -eq 1 ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    worker_host_parse_line "$line" || die "malformed worker host registry entry: $line"
    note_match "$WORKER_HOST_ID" "$WORKER_HOST_HOST" "$WORKER_HOST_ROOT" "$WORKER_HOST_HOME"
  done < "$WORKER_REG"
fi
[ "$MATCHES" -gt 0 ] || die "no remote secondmate, worker host, or SSH alias matches '$ROUTE'"
[ "$MATCHES" -eq 1 ] || die "remote route '$ROUTE' is ambiguous across $MATCHES configured remote homes; use a secondmate or worker host id"
case "$HOST" in ''|-*|*[!A-Za-z0-9._-]*) die "configured SSH alias is unsafe: $HOST" ;; esac
case "$ROOT" in /*) ;; *) die "configured remote root is not absolute: $ROOT" ;; esac
case "$HOME_PATH" in /*) ;; *) die "configured remote home is not absolute: $HOME_PATH" ;; esac
case "$ROOT$HOME_PATH" in *$'\n'*|*$'\r'*|*$'\t'*) die "configured remote root or home contains control characters" ;; esac
for configured_path in "$ROOT" "$HOME_PATH"; do
  case "/$configured_path/" in */../*|*/./*) die "configured remote root or home contains traversal components" ;; esac
  case "$configured_path" in *'//'*) die "configured remote root or home contains an empty path component" ;; esac
done

ROOT_B64=$(printf '%s' "$ROOT" | encode_base64)
HOME_B64=$(printf '%s' "$HOME_PATH" | encode_base64)
ARGV_B64=$(printf '%s\0' "$COMMAND" "$@" | encode_base64)
SSH_BIN=${FM_SSH_BIN:-ssh}
ALIVE_INTERVAL=${FM_SSH_ALIVE_INTERVAL:-15}
ALIVE_COUNT_MAX=${FM_SSH_ALIVE_COUNT_MAX:-3}
case "$ALIVE_INTERVAL" in ''|*[!0-9]*) die "FM_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL" ;; esac
case "$ALIVE_COUNT_MAX" in ''|*[!0-9]*) die "FM_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX" ;; esac
[ "$ALIVE_INTERVAL" -gt 0 ] || die "FM_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL"
[ "$ALIVE_COUNT_MAX" -gt 0 ] || die "FM_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX"

SSH_ARGS=(
  -o ForwardAgent=no
  -o ClearAllForwardings=yes
  -o 'SendEnv=-*'
  -o "ServerAliveInterval=$ALIVE_INTERVAL"
  -o "ServerAliveCountMax=$ALIVE_COUNT_MAX"
  -- "$HOST" fm-remote-entrypoint.sh "$PROTOCOL" "$ROOT_B64" "$HOME_B64" "$ARGV_B64"
)
if [ "$STDIN_MODE" = caller ]; then
  exec "$SSH_BIN" "${SSH_ARGS[@]}"
fi
exec "$SSH_BIN" "${SSH_ARGS[@]}" < /dev/null
