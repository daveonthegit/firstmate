#!/usr/bin/env bash
# fm-host-reserve.sh - temporarily pause or reduce lane placement on a host for
# owner-reserved use (gaming, server hosting) without disturbing running work.
#
# Usage:
#   fm-host-reserve.sh pause  [--host <id|local>] [--reason <text>] [--for <duration>]
#   fm-host-reserve.sh reduce [--host <id|local>] [--max-lanes <N>] [--keep-gb <G>]
#                             [--reason <text>] [--for <duration>]
#   fm-host-reserve.sh release [--host <id|local>]
#   fm-host-reserve.sh status  [--host <id|local> | --all]
#
# Writes or clears this machine's runtime reservation record at
# ~/.firstmate/host-reserve (FM_HOST_RESERVE_FILE overrides the path for
# isolated tests). Every Firstmate home on the machine (primary, worker host,
# and second-mate homes) reads that one file through bin/fm-capacity.sh,
# alongside its config/lane-capacity and any external reserve-flag file
# (docs/configuration.md "Lane capacity"), so a reservation covers the whole
# machine.
#
#   pause    Admits no new ship or scout lanes (free_lanes=0, reason=reserve).
#            bin/fm-placement.sh skips this host, and bin/fm-spawn.sh defers new
#            launches when admit-spawns is set. Running workers keep running.
#   reduce   Shrinks effective capacity while keeping running work intact:
#            --max-lanes caps fixed mode at min(cap, N) and caps auto mode's
#            ceiling at min(max-lanes, N); --keep-gb raises the minimum
#            available memory floor to at least G GB. At least one of
#            --max-lanes or --keep-gb is required. --max-lanes 0 pauses new
#            admission like `pause`.
#   release  Removes the reservation file so normal capacity resumes. Idempotent.
#   status   Reports the current state (none, paused, reduced, expired, or
#            invalid) without changing anything. With --all, inspects this
#            machine and every registered worker host in data/worker-hosts.md.
#
# Duration format for --for: <N><s|m|h|d> (positive integer, e.g. 90m, 4h, 1d).
# An expired --for reservation is automatically ignored by bin/fm-capacity.sh,
# so a timed reservation self-releases even if you forget to run `release`.
#
# Remote hosts: passing --host <worker-host-id> (anything other than `local`)
# delegates this exact command to that worker host through bin/fm-on.sh.
#
# Safety: never interrupts, exits, or tears down any running worker or
# secondmate. Refuses a symlinked reservation directory or file.
#
# Exit status: 0 on success, 1 on refusal/error or invalid reservation file,
# 2 on usage, 255 on unreachable SSH transport.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RESERVE_FILE="${FM_HOST_RESERVE_FILE:-${HOME:-}/.firstmate/host-reserve}"
RESERVE_DIR=$(dirname "$RESERVE_FILE")

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,/^set -eu$/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
is_num() { case "$1" in ''|*[!0-9.]*|*.*.*|.*|*.) return 1 ;; esac; }
safe_id() { case "$1" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

parse_duration_secs() { # <Ns|Nm|Nh|Nd>
  local raw=$1 num mult
  case "$raw" in
    *[!0-9smhd]*|'') return 1 ;;
    *s) num=${raw%s}; mult=1 ;;
    *m) num=${raw%m}; mult=60 ;;
    *h) num=${raw%h}; mult=3600 ;;
    *d) num=${raw%d}; mult=86400 ;;
    *) return 1 ;;
  esac
  is_uint "$num" && [ "${#num}" -le 7 ] && [ "$((10#$num))" -gt 0 ] || return 1
  printf '%s\n' "$((10#$num * mult))"
}

format_utc() { # <epoch>
  date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || printf '%s' "$1"
}

validate_reason() { # <text>
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*|*[[:cntrl:]]*) die "reason must be a single line without control characters" ;;
  esac
}

require_safe_state() {
  if [ -L "$RESERVE_DIR" ]; then
    die "refusing symlinked reservation directory: $RESERVE_DIR"
  fi
  if [ ! -d "$RESERVE_DIR" ]; then
    mkdir -p "$RESERVE_DIR" || die "cannot create reservation directory: $RESERVE_DIR"
    chmod 0700 "$RESERVE_DIR" 2>/dev/null || true
  fi
  if [ -L "$RESERVE_FILE" ]; then
    die "refusing symlinked reservation file: $RESERVE_FILE"
  fi
  if [ -e "$RESERVE_FILE" ] && [ ! -f "$RESERVE_FILE" ]; then
    die "refusing non-regular reservation path: $RESERVE_FILE"
  fi
}

[ "$#" -ge 1 ] || usage
VERB=$1
case "$VERB" in
  -h|--help) usage ;;
  pause|reduce|release|status) shift ;;
  *) usage ;;
esac

HOST=local
ALL_HOSTS=0
REASON=
MAX_LANES=
KEEP_GB=
FOR_DUR=
UNTIL_EPOCH=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) [ "$#" -ge 2 ] || usage; HOST=$2; shift 2 ;;
    --all) ALL_HOSTS=1; shift ;;
    --reason) [ "$#" -ge 2 ] || usage; REASON=$2; shift 2 ;;
    --max-lanes) [ "$#" -ge 2 ] || usage; MAX_LANES=$2; shift 2 ;;
    --keep-gb) [ "$#" -ge 2 ] || usage; KEEP_GB=$2; shift 2 ;;
    --for) [ "$#" -ge 2 ] || usage; FOR_DUR=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

safe_id "$HOST" || die "invalid host id: $HOST"
if [ "$ALL_HOSTS" -eq 1 ]; then
  [ "$VERB" = status ] || die "--all is valid only with status"
  [ "$HOST" = local ] || die "cannot combine --all with --host"
fi
[ -z "$REASON" ] || validate_reason "$REASON"

case "$VERB" in
  pause)
    [ -z "$MAX_LANES" ] && [ -z "$KEEP_GB" ] || die "pause does not take --max-lanes or --keep-gb; use reduce"
    ;;
  reduce)
    [ -n "$MAX_LANES" ] || [ -n "$KEEP_GB" ] || die "reduce requires --max-lanes <N> and/or --keep-gb <G>"
    if [ -n "$MAX_LANES" ]; then
      is_uint "$MAX_LANES" && [ "${#MAX_LANES}" -le 9 ] || die "--max-lanes must be a non-negative integer: $MAX_LANES"
      MAX_LANES=$((10#$MAX_LANES))
    fi
    if [ -n "$KEEP_GB" ]; then
      is_num "$KEEP_GB" || die "--keep-gb must be a non-negative number: $KEEP_GB"
    fi
    ;;
  release|status)
    [ -z "$REASON" ] && [ -z "$MAX_LANES" ] && [ -z "$KEEP_GB" ] && [ -z "$FOR_DUR" ] \
      || die "$VERB does not accept reservation parameters"
    ;;
esac

if [ -n "$FOR_DUR" ]; then
  dur_secs=$(parse_duration_secs "$FOR_DUR") || die "invalid --for duration '$FOR_DUR' (expected e.g. 90m, 4h, 1d)"
  UNTIL_EPOCH=$(($(date +%s) + dur_secs))
fi

# Delegate non-local single-host commands through fm-on.sh.
if [ "$HOST" != local ]; then
  REMOTE_ARGS=("$VERB")
  [ -z "$REASON" ] || REMOTE_ARGS+=(--reason "$REASON")
  [ -z "$MAX_LANES" ] || REMOTE_ARGS+=(--max-lanes "$MAX_LANES")
  [ -z "$KEEP_GB" ] || REMOTE_ARGS+=(--keep-gb "$KEEP_GB")
  [ -z "$FOR_DUR" ] || REMOTE_ARGS+=(--for "$FOR_DUR")
  exec "$SCRIPT_DIR/fm-on.sh" "$HOST" fm-host-reserve.sh "${REMOTE_ARGS[@]}"
fi

print_local_status() { # <label>
  local label=$1 now line key val r_mode='' r_reason='' r_lanes='' r_keep='' r_until='' r_set='' bad=0 detail=''
  now=$(date +%s)
  if [ -L "$RESERVE_DIR" ]; then
    printf 'host-reserve: %s state=invalid (symlinked reservation directory)\n' "$label"
    return 1
  fi
  if [ ! -e "$RESERVE_FILE" ] && [ ! -L "$RESERVE_FILE" ]; then
    printf 'host-reserve: %s state=none\n' "$label"
    return 0
  fi
  if [ -L "$RESERVE_FILE" ] || [ ! -f "$RESERVE_FILE" ] || [ ! -r "$RESERVE_FILE" ]; then
    printf 'host-reserve: %s state=invalid (unreadable or unsafe reservation file)\n' "$label"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) bad=1; break ;; esac
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      mode) r_mode=$val ;;
      reason) r_reason=$val ;;
      max_lanes) r_lanes=$val ;;
      keep_gb) r_keep=$val ;;
      until) r_until=$val ;;
      set_at) r_set=$val ;;
      *) bad=1; break ;;
    esac
  done < "$RESERVE_FILE"
  if [ "$bad" -eq 0 ]; then
    case "$r_mode" in
      pause)
        [ -z "$r_keep" ] || bad=1
        [ -z "$r_lanes" ] || [ "$r_lanes" = 0 ] || bad=1
        ;;
      reduce)
        [ -n "$r_lanes" ] || [ -n "$r_keep" ] || bad=1
        [ -z "$r_lanes" ] || is_uint "$r_lanes" || bad=1
        [ -z "$r_keep" ] || is_num "$r_keep" || bad=1
        ;;
      *) bad=1 ;;
    esac
    [ -z "$r_until" ] || { is_uint "$r_until" && [ "$r_until" -gt 0 ]; } || bad=1
    [ -z "$r_set" ] || is_uint "$r_set" || bad=1
  fi
  if [ "$bad" -eq 1 ]; then
    printf 'host-reserve: %s state=invalid (malformed reservation file; run release or overwrite)\n' "$label"
    return 1
  fi
  if [ -n "$r_until" ] && [ "$now" -ge "$r_until" ]; then
    printf 'host-reserve: %s state=expired mode=%s until=%s reason=%s\n' \
      "$label" "$r_mode" "$(format_utc "$r_until")" "${r_reason:-owner reserved}"
    return 0
  fi
  [ -z "$r_lanes" ] || detail="${detail:+$detail }max_lanes=$r_lanes"
  [ -z "$r_keep" ] || detail="${detail:+$detail }keep_gb=$r_keep"
  [ -z "$r_until" ] || detail="${detail:+$detail }until=$(format_utc "$r_until")"
  if [ "$r_mode" = pause ] || [ "$r_lanes" = 0 ]; then
    printf 'host-reserve: %s state=paused%s reason=%s\n' \
      "$label" "${detail:+ $detail}" "${r_reason:-owner reserved}"
  else
    printf 'host-reserve: %s state=reduced%s reason=%s\n' \
      "$label" "${detail:+ $detail}" "${r_reason:-owner reserved}"
  fi
  return 0
}

case "$VERB" in
  status)
    rc=0
    print_local_status local || rc=1
    if [ "$ALL_HOSTS" -eq 1 ]; then
      # shellcheck source=bin/fm-worker-host-lib.sh
      . "$SCRIPT_DIR/fm-worker-host-lib.sh"
      ids=$(worker_host_ids "$DATA") || die "worker host registry is unusable: $WORKER_HOST_ERROR"
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        [ "$id" != local ] || continue
        host_rc=0
        out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-host-reserve.sh status 2>/dev/null) || host_rc=$?
        if [ "$host_rc" -eq 255 ]; then
          printf 'host-reserve: %s state=unreachable\n' "$id"
        elif [ "$host_rc" -ne 0 ] || [ -z "$out" ]; then
          printf 'host-reserve: %s state=error (exit %s)\n' "$id" "$host_rc"
          rc=1
        else
          printf '%s\n' "$out" | sed "s/^host-reserve: local /host-reserve: $id /"
        fi
      done <<EOF
$ids
EOF
    fi
    exit "$rc"
    ;;
  release)
    require_safe_state
    if [ -e "$RESERVE_FILE" ]; then
      rm -f -- "$RESERVE_FILE" || die "could not remove $RESERVE_FILE"
      printf 'host-reserve: local released\n'
    else
      printf 'host-reserve: local already clear\n'
    fi
    exit 0
    ;;
  pause|reduce)
    require_safe_state
    now=$(date +%s)
    eff_mode=$VERB
    [ "$VERB" = reduce ] && [ "$MAX_LANES" = 0 ] && eff_mode=pause
    eff_reason=${REASON:-owner reserved}
    tmp=$(mktemp "$RESERVE_DIR/.host-reserve.XXXXXX") || die "cannot stage reservation file in $RESERVE_DIR"
    {
      printf 'mode=%s\n' "$eff_mode"
      printf 'reason=%s\n' "$eff_reason"
      [ -z "$MAX_LANES" ] || [ "$eff_mode" = pause ] || printf 'max_lanes=%s\n' "$MAX_LANES"
      [ -z "$KEEP_GB" ] || [ "$eff_mode" = pause ] || printf 'keep_gb=%s\n' "$KEEP_GB"
      [ -z "$UNTIL_EPOCH" ] || printf 'until=%s\n' "$UNTIL_EPOCH"
      printf 'set_at=%s\n' "$now"
    } > "$tmp" || { rm -f -- "$tmp"; die "cannot write reservation file"; }
    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$RESERVE_FILE" || { rm -f -- "$tmp"; die "cannot publish $RESERVE_FILE"; }
    print_local_status local
    exit 0
    ;;
esac
