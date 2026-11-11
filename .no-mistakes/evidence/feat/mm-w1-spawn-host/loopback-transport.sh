#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2;; --) shift; break;; *) exit 90;; esac; done
[ "$1" = lab-loopback ] && [ "$2" = fm-remote-entrypoint.sh ] || exit 91
decode() { printf '%s' "$1" | base64 --decode; }
root=$(decode "$4"); home=$(decode "$5")
args=(); while IFS= read -r -d '' a; do args+=("$a"); done < <(decode "$6")
rc=0
env -u FM_SUPERVISION_ACTOR -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_SPAWN_NO_GUARD=1 "$root/bin/${args[0]}" "${args[@]:1}" || rc=$?
[ "${LAB_LOSE_RESULT:-}" != 1 ] || exit 255
exit "$rc"
