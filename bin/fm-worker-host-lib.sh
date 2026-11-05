#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Shared parser for data/worker-hosts.md records.
#
# A worker host is another SSH-reachable machine that runs a headless
# Firstmate home for this primary's ship and scout workers. The primary keeps
# every task record; the host only runs the ordinary local scripts against its
# own home (docs/remote-workers.md). One record per host:
#   - <id> - <summary> (host: <ssh-alias>; root: <abs-code-root>; home: <abs-home>; added YYYY-MM-DD)
# The summary is natural language, so field boundaries are anchored to the
# structured suffix rather than to incidental punctuation, exactly as in
# bin/fm-secondmate-registry-lib.sh. Every other line is ignored prose.

WORKER_HOST_ID=
WORKER_HOST_SUMMARY=
WORKER_HOST_HOST=
WORKER_HOST_ROOT=
WORKER_HOST_HOME=
WORKER_HOST_ADDED=

worker_host_registry_path() { # <data-dir>
  printf '%s/worker-hosts.md\n' "$1"
}

worker_host_parse_line() { # <line>
  local line=$1
  local re='^- ([A-Za-z0-9._-]+) - (.+) \(host:[[:space:]]*([^;)]*);[[:space:]]*root:[[:space:]]*([^;)]*);[[:space:]]*home:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  WORKER_HOST_ID=
  WORKER_HOST_SUMMARY=
  WORKER_HOST_HOST=
  WORKER_HOST_ROOT=
  WORKER_HOST_HOME=
  WORKER_HOST_ADDED=
  [[ "$line" =~ $re ]] || return 1
  WORKER_HOST_ID=${BASH_REMATCH[1]}
  WORKER_HOST_SUMMARY=${BASH_REMATCH[2]}
  WORKER_HOST_HOST=${BASH_REMATCH[3]}
  WORKER_HOST_ROOT=${BASH_REMATCH[4]}
  WORKER_HOST_HOME=${BASH_REMATCH[5]}
  WORKER_HOST_ADDED=${BASH_REMATCH[6]}
  [ -n "$WORKER_HOST_HOST" ] && [ -n "$WORKER_HOST_ROOT" ] && [ -n "$WORKER_HOST_HOME" ]
}
