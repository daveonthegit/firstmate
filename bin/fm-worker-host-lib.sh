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
WORKER_HOST_ERROR=

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

# Resolve the one record whose id or SSH alias equals <route>, the same rule
# bin/fm-on.sh applies across both remote registries. Returns 1 with
# WORKER_HOST_ERROR when nothing matches, 2 when the registry is unsafe or
# malformed, and 3 when the route is ambiguous. On success the WORKER_HOST_*
# fields describe the match.
worker_host_lookup() { # <registry> <route>
  local reg=$1 route=$2 line matches=0 id='' summary='' host='' root='' home='' added=''
  WORKER_HOST_ERROR=
  case "$route" in ''|-*|*[!A-Za-z0-9._-]*) WORKER_HOST_ERROR="invalid worker host route: $route"; return 1 ;; esac
  if [ ! -e "$reg" ] && [ ! -L "$reg" ]; then
    WORKER_HOST_ERROR="no worker host registry at $reg"
    return 1
  fi
  if [ ! -f "$reg" ] || [ -L "$reg" ]; then
    WORKER_HOST_ERROR="worker host registry is not a regular file: $reg"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    if ! worker_host_parse_line "$line"; then
      WORKER_HOST_ERROR="malformed worker host registry entry: $line"
      return 2
    fi
    [ "$WORKER_HOST_ID" = "$route" ] || [ "$WORKER_HOST_HOST" = "$route" ] || continue
    matches=$((matches + 1))
    id=$WORKER_HOST_ID summary=$WORKER_HOST_SUMMARY host=$WORKER_HOST_HOST
    root=$WORKER_HOST_ROOT home=$WORKER_HOST_HOME added=$WORKER_HOST_ADDED
  done < "$reg"
  if [ "$matches" -eq 0 ]; then
    WORKER_HOST_ERROR="no worker host matches '$route'"
    return 1
  fi
  if [ "$matches" -gt 1 ]; then
    WORKER_HOST_ERROR="worker host route '$route' matches $matches records; use a unique worker host id"
    return 3
  fi
  WORKER_HOST_ID=$id
  WORKER_HOST_SUMMARY=$summary
  WORKER_HOST_HOST=$host
  WORKER_HOST_ROOT=$root
  WORKER_HOST_HOME=$home
  WORKER_HOST_ADDED=$added
  return 0
}

# Print every registered worker-host id, one per line. A malformed record
# stops the listing with status 2 rather than silently skipping a host.
worker_host_ids() { # <registry>
  local reg=$1 line
  [ -e "$reg" ] || [ -L "$reg" ] || return 0
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    worker_host_parse_line "$line" || return 2
    printf '%s\n' "$WORKER_HOST_ID"
  done < "$reg"
}
