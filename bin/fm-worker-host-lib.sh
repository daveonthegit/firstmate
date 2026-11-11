#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Shared parser for data/worker-hosts.md records.
#
# A worker host is another SSH-reachable machine that runs a headless
# Firstmate home for this primary's ship and scout workers. The primary keeps
# every task record; the host only runs the ordinary local scripts against its
# own home (docs/remote-workers.md). docs/configuration.md's Worker hosts
# section owns the record format.
# The summary is natural language, so field boundaries are anchored to the
# structured suffix rather than to incidental punctuation, exactly as in
# bin/fm-secondmate-registry-lib.sh. Routing rejects malformed record lines;
# lines without the `- ` prefix are ignored prose.

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

# Select the record whose id is exactly <id>, leaving its fields in the
# WORKER_HOST_* globals. Returns 1 when no record has that id or the registry
# is absent, and 2 with the reason in WORKER_HOST_ERROR when the registry is
# not a regular file, holds a malformed record, or holds two records with that
# id; a bad record stops the lookup rather than being skipped.
WORKER_HOST_ERROR=
worker_host_lookup() {  # <data-dir> <id>
  local reg line found=0 id host root home summary added
  reg=$(worker_host_registry_path "$1")
  WORKER_HOST_ERROR=
  if [ ! -e "$reg" ] && [ ! -L "$reg" ]; then
    worker_host_parse_line '' || true
    return 1
  fi
  if [ ! -f "$reg" ] || [ -L "$reg" ]; then
    WORKER_HOST_ERROR="no safe worker host registry at $reg"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    if ! worker_host_parse_line "$line"; then
      WORKER_HOST_ERROR="malformed worker host registry entry: $line"
      return 2
    fi
    if [ "$WORKER_HOST_ID" = "$2" ]; then
      if [ "$found" -eq 1 ]; then
        WORKER_HOST_ERROR="worker host id $2 has more than one record in $reg"
        return 2
      fi
      found=1 id=$WORKER_HOST_ID summary=$WORKER_HOST_SUMMARY host=$WORKER_HOST_HOST
      root=$WORKER_HOST_ROOT home=$WORKER_HOST_HOME added=$WORKER_HOST_ADDED
    fi
  done < "$reg"
  worker_host_parse_line '' || true
  [ "$found" -eq 1 ] || return 1
  WORKER_HOST_ID=$id WORKER_HOST_SUMMARY=$summary WORKER_HOST_HOST=$host
  WORKER_HOST_ROOT=$root WORKER_HOST_HOME=$home WORKER_HOST_ADDED=$added
}
