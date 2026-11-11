#!/usr/bin/env bash
set -eu
export FM_HOME="$PWD/.live-handoff/home"
export FM_GH_ACCOUNT=none
export TREEHOUSE_ROOT="$PWD/.live-handoff/pool"
H="$PWD/bin/fm-handoff.sh"
check() {
  local want=$1 needle=$2 rc=0 out
  shift 2
  printf '\n$'; printf ' %q' "$@"; printf '\n'
  out=$("$@" 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$out" "$rc"
  [ "$rc" = "$want" ] && [[ "$out" == *"$needle"* ]]
}
check 1 '--remote is required' "$H" scout-h1 --to local
check 2 'only a local hand-off exists' "$H" scout-h1 --to another-host
check 2 'unknown option --as' "$H" scout-h1 --to local --remote origin --as custom
printf 'needs-decision [at=%s] [key=colour]: choose colour\n' "$(date +%s)" >> "$FM_HOME/state/scout-h1.status"
check 1 'open decision' "$H" scout-h1 --to local --remote origin
[ ! -e "$FM_HOME/data/scout-h1/handoff-request" ]
printf 'resolved [at=%s] [key=colour]: blue\n' "$(date +%s)" >> "$FM_HOME/state/scout-h1.status"
for marker in "$FM_HOME/.fm-worker-host" "$FM_HOME/state/.supervisor-lease-lost"; do
  printf 'synthetic lab stand-down\n' > "$marker"
  rc=0; out=$("$H" scout-h1 --to local --remote origin 2>&1) || rc=$?
  printf '\nRequest while %s exists: %s (exit=%s)\n' "${marker##*/}" "$out" "$rc"
  [ "$rc" = 1 ] && [ ! -e "$FM_HOME/data/scout-h1/handoff-request" ]
  rm "$marker"
done
check 0 'requested: scout-h1' "$H" scout-h1 --to local --remote origin --reason 'local lab guard verification'
check 75 'waiting: scout-h1' "$H" scout-h1 --to local --remote origin
# These are synthetic protocol inputs, not a claim that the model quiesced.
printf 'paused [at=%s]: handoff ready\n' "$(date +%s)" >> "$FM_HOME/state/scout-h1.status"
for notes in absent empty; do
  [ "$notes" != empty ] || touch "$FM_HOME/data/scout-h1/handoff-notes.md"
  check 1 'no nonempty notes' "$H" scout-h1 --to local --remote origin
  [ -e "$FM_HOME/state/scout-h1.meta" ] && [ ! -e "$FM_HOME/data/scout-h1-c2/continuation" ]
done
before=$(shasum "$FM_HOME/data/scout-h1/handoff-request")
inbox_before=$(ls "$FM_HOME/state/scout-h1.inbox" | wc -l)
for marker in "$FM_HOME/.fm-worker-host" "$FM_HOME/state/.supervisor-lease-lost"; do
  printf 'synthetic lab stand-down\n' > "$marker"
  for action in finish cancel; do
    rc=0
    if [ "$action" = finish ]; then
      out=$("$H" scout-h1 --to local --remote origin --model other 2>&1) || rc=$?
    else
      out=$("$H" scout-h1 --to local --cancel 2>&1) || rc=$?
    fi
    printf '\n%s while %s exists: %s (exit=%s)\n' "$action" "${marker##*/}" "$out" "$rc"
    [ "$rc" = 1 ]
    [ "$(shasum "$FM_HOME/data/scout-h1/handoff-request")" = "$before" ]
    [ "$(ls "$FM_HOME/state/scout-h1.inbox" | wc -l)" = "$inbox_before" ]
    [ -e "$FM_HOME/state/scout-h1.meta" ] && [ ! -e "$FM_HOME/data/scout-h1-c2/continuation" ]
  done
  rm "$marker"
done
check 0 'cancelled:' "$H" scout-h1 --to local --cancel
[ ! -e "$FM_HOME/data/scout-h1/handoff-request" ]
[ -e "$FM_HOME/state/scout-h1.meta" ]
printf '\nConfirmed: refused operations left old task, request checksum and inbox unchanged; cancellation removed only the request and queued the resume steer.\n'
