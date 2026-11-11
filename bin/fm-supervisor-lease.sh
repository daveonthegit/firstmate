#!/usr/bin/env bash
# fm-supervisor-lease.sh - the machine-wide supervisor lease for a home whose
# records live in a git repository with a remote.
#
# The session lock (bin/fm-lock.sh) only stops two sessions on ONE machine.
# This lease stops two machines from supervising the same fleet: it is a record
# in the home's records repository, and the remote's refusal of a
# non-fast-forward push is the compare-and-swap that decides who holds it.
#
# WHEN IT APPLIES. The lease is active only when data/ is itself the top level
# of a git repository (not merely inside the firstmate checkout) and that
# repository has a remote. Every other home is "off": every verb except steal
# exits 0 without touching anything, and session start behaves exactly as it
# did before the lease existed. A worker-host home (an `.fm-worker-host`
# regular file at the home root) refuses acquire, steal, and push, because a
# worker host must never become a supervisor.
#
# THE RECORD. data/supervisor.lease holds one line:
#   host=<machine id> epoch=<n> since=<UTC> by=<session>
# host=none means released. A missing file is free at epoch 0. Any other shape
# is malformed and refused rather than guessed. The epoch only ever grows: every
# write is epoch+1 over the highest epoch this machine has seen.
#
# MACHINE ID. config/machine-id (one [A-Za-z0-9._-] token) when present;
# otherwise macOS's LocalHostName (stable across networks, unlike hostname);
# otherwise `hostname -s`. The value `none` is reserved and refused for both
# configured and fallback identities.
#
# REMOTE AND BRANCH. data/ must be on a branch with exactly one remote.
# The remote branch is the upstream's merge ref, else the same branch name.
#
# Usage:
#   fm-supervisor-lease.sh status
#       Print mode, machine id, the local lease (data/'s HEAD), the last-seen
#       remote lease, and any stand-down record. Local only - no network.
#       Always exits 0.
#   fm-supervisor-lease.sh acquire [--reemit]
#       Session start runs this before taking the session lock.
#       1. Fetch the records remote and fast-forward data/. A local branch that
#          has diverged from the remote, or a fast-forward blocked by local
#          edits, is refused.
#       2. A lease naming another host is refused.
#       3. A free lease, or one naming this host, is rewritten as
#          host=<this machine> epoch=<n+1>, committed, and pushed. A rejected
#          push means another machine moved the lease first: refused.
#       With --reemit (a context rebuild of a session that already started),
#       nothing is written: the lease must still name this host and no
#       stand-down may be recorded, or it is refused. A free lease is NOT
#       re-taken on --reemit, so a released lease stays released.
#       Unreachable remote (fetch or push could not complete within the bound):
#       continue only when the local copy names this host, the last-seen remote
#       lease is not newer, and no stand-down is recorded; this prints an
#       UNCONFIRMED warning. Otherwise refused - only `steal` overrides that.
#       Every refusal also records a stand-down (below), so a session still
#       running in this home stops acting as supervisor too.
#   fm-supervisor-lease.sh release
#       Requires a reachable remote and a lease naming this host. Writes
#       host=none epoch=<n+1>, commits, and pushes; the push must be accepted
#       before a move counts as started. This home stands down before attempting
#       the push, even if delivery is rejected or unconfirmed, or local adoption
#       fails after the remote accepts the release.
#   fm-supervisor-lease.sh steal --owner-approved
#       ONLY on the owner's explicit word. Takes the lease whoever holds it, at
#       epoch = (highest epoch seen locally or on the remote) + 1, and clears
#       any stand-down. With the remote reachable the push must be accepted;
#       with it unreachable the commit is built on the last-fetched remote
#       records, stays local, is reported UNCONFIRMED, and is pushed by the
#       next acquire or push.
#   fm-supervisor-lease.sh push
#       The records push for a running session: pushes data/'s HEAD to the
#       records remote with the lease file unchanged. The local lease must
#       still name this host. A rejected push, a remote whose lease moved, or a
#       local lease that no longer names this host stands this session down.
#       An unreachable remote is not a stand-down: it exits 3 and the commits
#       wait for the next push.
#
# STAND-DOWN. state/.supervisor-lease-lost (one line: reason and UTC time)
# records that this home no longer holds the lease. While it exists,
# bin/fm-lock.sh refuses to take the session lock and fm_session_lock_owned_by_self
# (bin/fm-session-lock-lib.sh) reports no ownership, so every supervision owner
# that checks the lock stands down. A stand-down from `push` also queues one
# `check: supervisor-lease-lost` wake. Only a successful full acquire or a
# steal clears it.
#
# Output lines start with `supervisor-lease:`. Exit status: 0 held, confirmed,
# unconfirmed, released, or off; 1 refused (stay read-only); 2 usage; 3 push
# deferred because the remote is unreachable.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE
# select the home. FM_SUPERVISOR_LEASE_TIMEOUT bounds each network call in
# seconds (default 15).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LEASE_NAME=supervisor.lease
LOST_MARKER="$STATE/.supervisor-lease-lost"
NET_BOUND=${FM_SUPERVISOR_LEASE_TIMEOUT:-15}
case "$NET_BOUND" in ''|*[!0-9]*|0) NET_BOUND=15 ;; esac

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-supervisor-lease.sh" | sed 's/^# \{0,1\}//; $d'
}

say() { printf 'supervisor-lease: %s\n' "$*"; }

# --- identity and mode -------------------------------------------------------

machine_id() {
  local id=
  if [ -f "$CONFIG/machine-id" ]; then
    id=$(head -n 1 "$CONFIG/machine-id" 2>/dev/null | tr -d '[:space:]')
    case "$id" in
      ''|none|*[!A-Za-z0-9._-]*)
        say "refused: config/machine-id must be one [A-Za-z0-9._-] token other than none" >&2
        return 1
        ;;
    esac
    printf '%s\n' "$id"
    return 0
  fi
  if command -v scutil >/dev/null 2>&1; then
    id=$(scutil --get LocalHostName 2>/dev/null || true)
  fi
  [ -n "$id" ] || id=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
  id=$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '-')
  case "$id" in
    ''|none) say "refused: cannot determine a non-reserved machine id; write config/machine-id" >&2; return 1 ;;
  esac
  printf '%s\n' "$id"
}

worker_host_home() {
  [ -f "$FM_HOME/.fm-worker-host" ] && [ ! -L "$FM_HOME/.fm-worker-host" ]
}

session_label() {
  local pid=
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh" 2>/dev/null \
    && pid=$(fm_session_lock_anchor_pid 2>/dev/null || true)
  printf 'session-%s\n' "${pid:-$PPID}"
}

g() { git -C "$DATA" "$@"; }

# Sets MODE=off|active and, when active, BRANCH REMOTE REMOTE_BRANCH TRACK.
# Returns 1 with a diagnostic when data/ is a records repository whose remote
# or branch cannot be resolved without guessing.
MODE=off BRANCH='' REMOTE='' REMOTE_BRANCH='' TRACK=''
resolve_repo() {
  local top data_phys remotes count merge
  MODE=off
  # The top of a repository always carries a .git entry, so a home without one
  # is off without running git at all.
  [ -d "$DATA" ] && [ -e "$DATA/.git" ] || return 0
  data_phys=$(cd "$DATA" 2>/dev/null && pwd -P) || return 0
  top=$(g rev-parse --show-toplevel 2>/dev/null) || return 0
  top=$(cd "$top" 2>/dev/null && pwd -P) || return 0
  [ "$top" = "$data_phys" ] || return 0
  remotes=$(g remote 2>/dev/null || true)
  [ -n "$remotes" ] || return 0
  MODE=active
  BRANCH=$(g symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    say "refused: data/ is not on a branch, so the records branch is unknown"
    return 1
  }
  count=$(printf '%s\n' "$remotes" | grep -c .)
  if [ "$count" -ne 1 ]; then
    say "refused: data/ must have exactly one records remote"
    return 1
  fi
  REMOTE=$remotes
  merge=$(g config --get "branch.$BRANCH.merge" 2>/dev/null || true)
  REMOTE_BRANCH=${merge#refs/heads/}
  [ -n "$REMOTE_BRANCH" ] || REMOTE_BRANCH=$BRANCH
  TRACK="refs/remotes/$REMOTE/$REMOTE_BRANCH"
  return 0
}

# --- lease records -----------------------------------------------------------

# parse_lease <text>: sets L_HOST L_EPOCH L_SINCE; empty text is free at 0.
L_HOST='' L_EPOCH=0 L_SINCE=''
parse_lease() {
  local text=$1 re
  L_HOST=none L_EPOCH=0 L_SINCE=''
  [ -n "$text" ] || return 0
  re='^host=([A-Za-z0-9._-]+) epoch=([0-9]+) since=([0-9TZ:-]+) by=([^[:space:]]+)$'
  if [[ "$text" =~ $re ]]; then
    L_HOST=${BASH_REMATCH[1]} L_EPOCH=$((10#${BASH_REMATCH[2]})) L_SINCE=${BASH_REMATCH[3]}
    return 0
  fi
  return 1
}

# lease_at <commit-ish>: prints the lease text recorded in that commit, empty
# when the commit or the file does not exist.
lease_at() {
  g rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1 || return 0
  g show "$1:$LEASE_NAME" 2>/dev/null | head -n 1
}

describe() {  # <text>
  if [ -z "$1" ]; then printf 'free (no record)'; else printf '%s' "$1"; fi
}

# --- network -----------------------------------------------------------------

net() {  # bounded git call against the records remote
  GIT_TERMINAL_PROMPT=0 fm_run_timed "$NET_BOUND" git -C "$DATA" "$@"
}

# fetch_remote: 0 fetched (TRACK updated, or deleted when the remote branch
# does not exist yet), 1 unreachable. Sets REMOTE_TIP (empty for no branch).
REMOTE_TIP='' FETCH_ERR=''
fetch_remote() {
  local out rc
  REMOTE_TIP='' FETCH_ERR=''
  out=$(net ls-remote "$REMOTE" "refs/heads/$REMOTE_BRANCH" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    FETCH_ERR=$(printf '%s' "$out" | tail -n 1)
    [ "$rc" -ne 124 ] || FETCH_ERR="no answer within ${NET_BOUND}s"
    return 1
  fi
  REMOTE_TIP=$(printf '%s\n' "$out" | awk 'NR==1 {print $1}')
  if [ -z "$REMOTE_TIP" ]; then
    g update-ref -d "$TRACK" >/dev/null 2>&1 || true
    return 0
  fi
  out=$(net fetch --quiet --no-tags "$REMOTE" "+refs/heads/$REMOTE_BRANCH:$TRACK" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    FETCH_ERR=$(printf '%s' "$out" | tail -n 1)
    [ "$rc" -ne 124 ] || FETCH_ERR="no answer within ${NET_BOUND}s"
    return 1
  fi
  REMOTE_TIP=$(g rev-parse --verify --quiet "$TRACK^{commit}" 2>/dev/null || true)
  return 0
}

# fast_forward: brings data/'s branch up to the fetched remote tip. 0 when the
# branch now contains the remote tip, 1 with a diagnostic otherwise.
fast_forward() {
  local head out
  [ -n "$REMOTE_TIP" ] || return 0
  head=$(g rev-parse --verify --quiet HEAD 2>/dev/null || true)
  if [ -z "$head" ]; then
    say "refused: data/ has no commits yet but the records remote does; clone the records repository instead"
    return 1
  fi
  g merge-base --is-ancestor "$REMOTE_TIP" "$head" 2>/dev/null && return 0
  if ! g merge-base --is-ancestor "$head" "$REMOTE_TIP" 2>/dev/null; then
    say "refused: data/ has diverged from $REMOTE/$REMOTE_BRANCH; reconcile the records by hand"
    return 1
  fi
  out=$(g merge --ff-only --quiet "$REMOTE_TIP" 2>&1) || {
    say "refused: cannot fast-forward data/ to $REMOTE/$REMOTE_BRANCH: $(printf '%s' "$out" | head -n 1)"
    return 1
  }
  return 0
}

# push_commit <commit>: 0 accepted, 1 rejected, 2 transport failure.
PUSH_ERR=
push_commit() {
  local out rc
  PUSH_ERR=
  out=$(net push --porcelain "$REMOTE" "$1:refs/heads/$REMOTE_BRANCH" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || return 0
  if printf '%s\n' "$out" | grep -q '^!'; then
    PUSH_ERR=$(printf '%s\n' "$out" | grep '^!' | head -n 1 | cut -f3)
    return 1
  fi
  PUSH_ERR=$(printf '%s' "$out" | tail -n 1)
  [ "$rc" -ne 124 ] || PUSH_ERR="no answer within ${NET_BOUND}s"
  return 2
}

# --- writing -------------------------------------------------------------------

identity_env() {
  # A records repository without a configured identity can still commit.
  local name email
  name=$(g config --get user.name 2>/dev/null || true)
  email=$(g config --get user.email 2>/dev/null || true)
  [ -n "${GIT_AUTHOR_NAME:-}" ] || [ -n "$name" ] || export GIT_AUTHOR_NAME=firstmate GIT_COMMITTER_NAME=firstmate
  [ -n "${GIT_AUTHOR_EMAIL:-}" ] || [ -n "$email" ] || export GIT_AUTHOR_EMAIL=firstmate@localhost GIT_COMMITTER_EMAIL=firstmate@localhost
}

# make_commit <parent-or-empty> <lease-text> <message>: prints a new commit
# whose tree is the parent's with only the lease file replaced. Neither the
# index nor the working tree is touched, so a rejected push leaves data/
# exactly as it was.
make_commit() {
  local parent=$1 text=$2 msg=$3 blob tree idx commit
  idx=$(mktemp "${TMPDIR:-/tmp}/fm-lease-index.XXXXXX") || return 1
  rm -f "$idx"
  identity_env
  blob=$(printf '%s\n' "$text" | g hash-object -w --stdin) || { rm -f "$idx"; return 1; }
  if [ -n "$parent" ]; then
    GIT_INDEX_FILE=$idx g read-tree "$parent" || { rm -f "$idx"; return 1; }
  else
    GIT_INDEX_FILE=$idx g read-tree --empty || { rm -f "$idx"; return 1; }
  fi
  GIT_INDEX_FILE=$idx g update-index --add --cacheinfo "100644,$blob,$LEASE_NAME" || { rm -f "$idx"; return 1; }
  tree=$(GIT_INDEX_FILE=$idx g write-tree) || { rm -f "$idx"; return 1; }
  rm -f "$idx"
  if [ -n "$parent" ]; then
    commit=$(printf '%s\n' "$msg" | g commit-tree "$tree" -p "$parent") || return 1
  else
    commit=$(printf '%s\n' "$msg" | g commit-tree "$tree") || return 1
  fi
  printf '%s\n' "$commit"
}

# adopt_commit <commit> <old-head-or-empty> <lease-text>: moves data/'s branch
# to the commit and brings the lease file's index entry and working copy along,
# leaving every other path's staged and unstaged state alone.
adopt_commit() {
  local commit=$1 old=$2 text=$3 blob
  if [ -n "$old" ]; then
    g update-ref "refs/heads/$BRANCH" "$commit" "$old" || return 1
  else
    g update-ref "refs/heads/$BRANCH" "$commit" || return 1
  fi
  blob=$(g rev-parse "$commit:$LEASE_NAME") || return 1
  g update-index --add --cacheinfo "100644,$blob,$LEASE_NAME" || return 1
  printf '%s\n' "$text" > "$DATA/$LEASE_NAME"
}

lease_line() {  # <host> <epoch>
  printf 'host=%s epoch=%s since=%s by=%s' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(session_label)"
}

# --- stand-down ----------------------------------------------------------------

record_stand_down() {  # <reason> [wake]
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s at=%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOST_MARKER" 2>/dev/null || true
  if [ "${2:-}" = wake ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    fm_wake_append check supervisor-lease-lost \
      "supervisor lease lost: $1 - this session stood down to read-only" >/dev/null 2>&1 || true
  fi
}

clear_stand_down() { rm -f "$LOST_MARKER" 2>/dev/null || true; }

refuse() {  # <reason>
  say "refused: $1"
  say "this home does not hold the supervisor lease; stay read-only"
  record_stand_down "refused: $1"
  exit 1
}

# --- verbs ---------------------------------------------------------------------

cmd_status() {
  local me local_text remote_text
  me=$(machine_id 2>/dev/null || printf 'unknown')
  if worker_host_home; then
    say "mode: worker-host (this home refuses the supervisor lease)"
  fi
  if ! resolve_repo >/dev/null; then
    say "mode: misconfigured records repository"
  fi
  if [ "$MODE" = off ]; then
    say "mode: off (data/ is not a git repository with a remote)"
    return 0
  fi
  say "mode: active (remote $REMOTE, branch $BRANCH -> $REMOTE_BRANCH)"
  say "machine: $me"
  local_text=$(lease_at HEAD)
  say "local: $(describe "$local_text")"
  if g rev-parse --verify --quiet "$TRACK" >/dev/null 2>&1; then
    remote_text=$(lease_at "$TRACK")
    say "last seen on remote: $(describe "$remote_text")"
  else
    say "last seen on remote: nothing fetched"
  fi
  if [ -f "$LOST_MARKER" ]; then
    say "stood down: $(head -n 1 "$LOST_MARKER" 2>/dev/null)"
  fi
  return 0
}

cmd_acquire() {
  local reemit=$1 me head text track_text new rc
  if worker_host_home; then
    say "refused: this is a worker-host home (.fm-worker-host), which never supervises"
    exit 1
  fi
  resolve_repo || refuse "the records repository cannot be resolved"
  [ "$MODE" = active ] || exit 0
  me=$(machine_id) || refuse "this machine's id is unknown"

  if ! fetch_remote; then
    head=$(g rev-parse --verify --quiet HEAD 2>/dev/null || true)
    text=$(lease_at HEAD)
    parse_lease "$text" || refuse "the local lease record is malformed: $text"
    local mine=$L_HOST local_epoch=$L_EPOCH
    track_text=$(lease_at "$TRACK")
    parse_lease "$track_text" || L_EPOCH=$((local_epoch + 1))
    if [ "$mine" = "$me" ] && [ "$L_EPOCH" -le "$local_epoch" ] && [ ! -f "$LOST_MARKER" ]; then
      say "UNCONFIRMED: the records remote is unreachable ($FETCH_ERR)"
      say "held by this machine at epoch $local_epoch per the local copy; nothing newer was seen"
      exit 0
    fi
    refuse "the records remote is unreachable ($FETCH_ERR) and the local copy does not show this machine holding the lease; only fm-supervisor-lease.sh steal --owner-approved overrides this"
  fi
  fast_forward || { record_stand_down "records could not be fast-forwarded"; say "this home does not hold the supervisor lease; stay read-only"; exit 1; }
  head=$(g rev-parse --verify --quiet HEAD 2>/dev/null || true)
  text=$(lease_at HEAD)
  parse_lease "$text" || refuse "the lease record is malformed: $text"
  if [ "$L_HOST" != none ] && [ "$L_HOST" != "$me" ]; then
    refuse "the lease is held by $L_HOST at epoch $L_EPOCH since $L_SINCE"
  fi
  if [ "$reemit" -eq 1 ]; then
    if [ "$L_HOST" = "$me" ] && [ ! -f "$LOST_MARKER" ]; then
      say "held by this machine at epoch $L_EPOCH (confirmed, unchanged)"
      exit 0
    fi
    if [ -f "$LOST_MARKER" ]; then
      refuse "this home stood down ($(head -n 1 "$LOST_MARKER" 2>/dev/null)); a context rebuild never re-takes the lease"
    fi
    refuse "the lease is free (epoch $L_EPOCH); a context rebuild never re-takes the lease"
  fi
  text=$(lease_line "$me" $((L_EPOCH + 1)))
  new=$(make_commit "$head" "$text" "supervisor lease: $me takes epoch $((L_EPOCH + 1))") \
    || refuse "could not write the lease commit"
  push_commit "$new" && rc=0 || rc=$?
  case "$rc" in
    0)
      adopt_commit "$new" "$head" "$text" || refuse "the lease was pushed but data/ could not be updated; run acquire again"
      clear_stand_down
      say "held by this machine at epoch $((L_EPOCH + 1))"
      exit 0
      ;;
    1)
      refuse "the records push was rejected ($PUSH_ERR): another machine moved the lease first"
      ;;
    *)
      if [ "$L_HOST" = "$me" ] && [ ! -f "$LOST_MARKER" ]; then
        say "UNCONFIRMED: the records push did not complete ($PUSH_ERR)"
        say "held by this machine at epoch $L_EPOCH per the fetched records; the epoch was not advanced"
        exit 0
      fi
      refuse "the records push did not complete ($PUSH_ERR), so the lease was not taken"
      ;;
  esac
}

cmd_release() {
  local me head text new rc
  resolve_repo || { say "refused: the records repository cannot be resolved"; exit 1; }
  if [ "$MODE" = off ]; then
    say "off: data/ is not a git repository with a remote; there is no lease to release"
    exit 0
  fi
  me=$(machine_id) || exit 1
  fetch_remote || { say "refused: the records remote is unreachable ($FETCH_ERR); a release must reach it"; exit 1; }
  fast_forward || refuse "records could not be fast-forwarded"
  head=$(g rev-parse --verify --quiet HEAD 2>/dev/null || true)
  text=$(lease_at HEAD)
  parse_lease "$text" || refuse "the lease record is malformed: $text"
  if [ "$L_HOST" != "$me" ]; then
    refuse "the lease is not held by this machine (it reads $(describe "$text"))"
  fi
  text=$(lease_line none $((L_EPOCH + 1)))
  new=$(make_commit "$head" "$text" "supervisor lease: $me releases at epoch $((L_EPOCH + 1))") \
    || { say "refused: could not write the release commit"; exit 1; }
  record_stand_down "release attempted at epoch $((L_EPOCH + 1))"
  push_commit "$new" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    refuse "the release push was not confirmed ($PUSH_ERR); the move has not started"
  fi
  adopt_commit "$new" "$head" "$text" || refuse "the release was pushed but data/ could not be updated"
  record_stand_down "released at epoch $((L_EPOCH + 1))"
  say "released at epoch $((L_EPOCH + 1)); this home has stood down"
  exit 0
}

cmd_steal() {
  local me head text track_text top new rc reachable=1
  if worker_host_home; then
    say "refused: this is a worker-host home (.fm-worker-host), which never supervises"
    exit 1
  fi
  resolve_repo || { say "refused: the records repository cannot be resolved"; exit 1; }
  if [ "$MODE" = off ]; then
    say "refused: data/ is not a git repository with a remote; there is no lease to steal"
    exit 1
  fi
  me=$(machine_id) || exit 1
  if ! fetch_remote; then
    reachable=0
    # Build on the last-seen remote records, so the steal can publish later.
    REMOTE_TIP=$(g rev-parse --verify --quiet "$TRACK^{commit}" 2>/dev/null || true)
  fi
  record_stand_down "steal attempted"
  fast_forward || refuse "records could not be fast-forwarded"
  head=$(g rev-parse --verify --quiet HEAD 2>/dev/null || true)
  text=$(lease_at HEAD)
  parse_lease "$text" || L_EPOCH=0
  top=$L_EPOCH
  track_text=$(lease_at "$TRACK")
  if parse_lease "$track_text" && [ "$L_EPOCH" -gt "$top" ]; then top=$L_EPOCH; fi
  text=$(lease_line "$me" $((top + 1)))
  new=$(make_commit "$head" "$text" "supervisor lease: $me steals epoch $((top + 1)) on the owner's word") \
    || { say "refused: could not write the steal commit"; exit 1; }
  if [ "$reachable" -eq 1 ]; then
    push_commit "$new" && rc=0 || rc=$?
    if [ "$rc" -eq 1 ]; then
      refuse "the steal push was rejected ($PUSH_ERR); the records moved meanwhile - run steal again"
    fi
    [ "$rc" -eq 0 ] || reachable=0
  fi
  adopt_commit "$new" "$head" "$text" || { say "refused: could not update data/ with the steal commit"; exit 1; }
  clear_stand_down
  if [ "$reachable" -eq 0 ]; then
    say "UNCONFIRMED: stolen locally at epoch $((top + 1)), but the records remote is unreachable (${FETCH_ERR:-$PUSH_ERR}); the next acquire or push publishes it"
    exit 0
  fi
  say "stolen: held by this machine at epoch $((top + 1))"
  exit 0
}

cmd_push() {
  local me head text remote_text rc
  if worker_host_home; then
    say "refused: this is a worker-host home (.fm-worker-host), which never pushes records"
    exit 1
  fi
  resolve_repo || { say "refused: the records repository cannot be resolved"; exit 1; }
  if [ "$MODE" = off ]; then
    say "off: data/ is not a git repository with a remote; nothing to push"
    exit 0
  fi
  if [ -f "$LOST_MARKER" ]; then
    say "refused: this home already stood down ($(head -n 1 "$LOST_MARKER" 2>/dev/null)); no records push"
    exit 1
  fi
  me=$(machine_id) || exit 1
  head=$(g rev-parse --verify --quiet HEAD 2>/dev/null || true)
  [ -n "$head" ] || { say "nothing to push: data/ has no commits"; exit 0; }
  text=$(lease_at HEAD)
  if ! parse_lease "$text" || [ "$L_HOST" != "$me" ]; then
    stand_down_push "the local lease no longer names this machine (it reads $(describe "$text"))"
  fi
  local epoch=$L_EPOCH
  if ! fetch_remote; then
    say "deferred: the records remote is unreachable ($FETCH_ERR); commits stay local until the next push"
    exit 3
  fi
  if [ -n "$REMOTE_TIP" ] && ! g merge-base --is-ancestor "$REMOTE_TIP" "$head" 2>/dev/null; then
    remote_text=$(lease_at "$REMOTE_TIP")
    if parse_lease "$remote_text" && { [ "$L_HOST" != "$me" ] || [ "$L_EPOCH" -ne "$epoch" ]; }; then
      stand_down_push "the lease moved to $(describe "$remote_text")"
    fi
    stand_down_push "the records remote moved past this machine's records"
  fi
  push_commit "$head" && rc=0 || rc=$?
  case "$rc" in
    0) say "pushed: records at $(g rev-parse --short HEAD) with the lease at epoch $epoch"; exit 0 ;;
    1) stand_down_push "the records push was rejected ($PUSH_ERR)" ;;
    *) say "deferred: the records push did not complete ($PUSH_ERR); commits stay local until the next push"; exit 3 ;;
  esac
}

stand_down_push() {  # <reason>
  record_stand_down "$1" wake
  say "STOOD DOWN: $1"
  say "this session no longer holds the supervisor lease and is now read-only: do not spawn, steer, merge, or drain"
  exit 1
}

case "${1:-}" in
  status) cmd_status; exit 0 ;;
  acquire)
    case "${2:-}" in
      '') cmd_acquire 0 ;;
      --reemit) cmd_acquire 1 ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  release) cmd_release ;;
  steal)
    if [ "${2:-}" != --owner-approved ]; then
      say "refused: steal takes the lease from whoever holds it and needs the owner's explicit word: steal --owner-approved"
      exit 2
    fi
    cmd_steal
    ;;
  push) cmd_push ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
