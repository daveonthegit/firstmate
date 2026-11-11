#!/usr/bin/env bash
# Check, and with --fix converge, the worker host home selected by the fixed
# remote entrypoint (docs/remote-workers.md).
#
# Usage (reached only through bin/fm-on.sh <worker-host-id> --stdin; the
# primary's bin/fm-worker-host-doctor.sh and bin/fm-worker-host-seed.sh build
# the manifest and send it):
#   fm-worker-host-home.sh [--fix] < manifest
#
# A worker host home is a headless Firstmate home, kept separate from the code
# root that runs it, holding only data/, state/, config/, and projects/. The
# home contract bin/fm-remote-worker-control.sh enforces is checked here one
# fact at a time: the .fm-worker-host marker, no second-mate marker, and
# config/backlog-backend set to manual. This command also checks what the
# primary's manifest asks for: the capacity declarations, one clone per named
# project with the primary's origin, that project's primary registry line copied
# byte for byte into this home's data/projects.md (so its delivery mode and
# forge binding are the primary's), the `no-mistakes` remote that `no-mistakes
# init` adds in a no-mistakes project, this home's own T3 sign-in and its days
# left, and whether this machine's T3 server runs the version and offers the
# capabilities the primary needs.
#
# Manifest schema fm-worker-host-home.v1, one key=value per line:
#   schema=fm-worker-host-home.v1
#   host_id_b64=<worker host id>
#   lanes=<cap>                       optional: the config/lane-capacity cap
#   capacity=<name_b64>|<n>           optional, repeatable: config/project-capacity
#   t3_version_b64=<version>          optional: the T3 version the primary runs
#   t3_capabilities=<a,b,...>         optional: T3 capabilities the primary uses
#   t3_note_b64=<why>                 optional: why the primary named no T3 need
#   project_scope=named|present       named checks every record; present checks
#                                     only records this home clones or registers
#   project_count=<n>
#   project=<name_b64>|<origin_b64>|<registry_b64>|<mode_b64>   (origin may be empty)
#
# Line protocol, one fact per line, the same shape as bin/fm-remote-doctor.sh:
#   mode=check|fix
#   home=<FM_HOME>
#   fix <check>=applied: <what changed>        (--fix only)
#   fix <check>=failed: <why it did not land>  (--fix only)
#   check <check>=ok|skip|fixable|human: <evidence>
#   action: <check>: <the exact step to take>
# Every check line describes the home after any repair, because --fix re-runs
# every check. Any remaining fixable or human gap exits 1.
#
# --fix is idempotent and repairs only what it owns: it creates the home and
# its four directories, writes the marker and config/backlog-backend, writes a
# capacity declaration only from a value the manifest carries and never over a
# different one, clones a missing project from the manifest origin, writes the
# primary's registry line, and runs `no-mistakes init` in a no-mistakes clone
# that lacks it. It never touches a second-mate home, never replaces a clone
# with another origin, never signs in to T3, and never copies a credential,
# token, or state/ from anywhere: every sign-in on this host is the operator's
# own step.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_MANIFEST_BYTES=1048576
SCHEMA=fm-worker-host-home.v1
T3_CAPABILITY_NAMES="launchEnvironment sessionStop keepAlive"

# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# Only fm_project_capacity_lookup is used, which needs nothing else sourced.
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
safe_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

MODE=check
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fix) MODE=fix ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

base64_decode() { # <encoded>; prints the decoded text
  if printf '%s' "$1" | base64 --decode 2>/dev/null; then return 0; fi
  printf '%s' "$1" | base64 -D 2>/dev/null
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-worker-host-home.XXXXXX") || die "cannot create a staging directory"
LOCK=
LOCK_HELD=0
cleanup() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$LOCK"
    LOCK_HELD=0
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT

head -c "$((MAX_MANIFEST_BYTES + 1))" > "$TMP/manifest" || die "cannot read the manifest"
[ "$(LC_ALL=C wc -c < "$TMP/manifest" | tr -d ' ')" -le "$MAX_MANIFEST_BYTES" ] \
  || die "the manifest exceeds its byte bound"

manifest_value() { # <key>; the one value, empty when absent
  local count
  count=$(grep -c "^$1=" "$TMP/manifest" 2>/dev/null || true)
  [ "$count" -le 1 ] || die "the manifest repeats $1"
  [ "$count" -eq 1 ] || return 0
  grep "^$1=" "$TMP/manifest" | cut -d= -f2-
}

[ "$(manifest_value schema)" = "$SCHEMA" ] || die "incompatible worker host manifest"
HOST_ID=$(base64_decode "$(manifest_value host_id_b64)") || die "the manifest host id is not valid base64"
safe_id "$HOST_ID" || die "the manifest carries an unsafe worker host id"
LANES=$(manifest_value lanes)
case "$LANES" in ''|[0-9]|[0-9][0-9]|[0-9][0-9][0-9]) ;; *) die "the manifest lane cap is invalid: $LANES" ;; esac
T3_EXPECT_VERSION=
T3_EXPECT_VERSION_B64=$(manifest_value t3_version_b64)
[ -z "$T3_EXPECT_VERSION_B64" ] || T3_EXPECT_VERSION=$(base64_decode "$T3_EXPECT_VERSION_B64") \
  || die "the manifest T3 version is not valid base64"
T3_EXPECT_CAPS=$(manifest_value t3_capabilities)
for capability in ${T3_EXPECT_CAPS//,/ }; do
  case " $T3_CAPABILITY_NAMES " in *" $capability "*) ;; *) die "the manifest names an unknown T3 capability: $capability" ;; esac
done
T3_NOTE=
T3_NOTE_B64=$(manifest_value t3_note_b64)
[ -z "$T3_NOTE_B64" ] || T3_NOTE=$(base64_decode "$T3_NOTE_B64") || die "the manifest T3 note is not valid base64"
PROJECT_SCOPE=$(manifest_value project_scope)
case "$PROJECT_SCOPE" in named|present) ;; *) die "the manifest project scope is invalid: $PROJECT_SCOPE" ;; esac
COUNT=$(manifest_value project_count)
case "$COUNT" in ''|*[!0-9]*) die "the manifest project count is invalid" ;; esac
[ "$(grep -c '^project=' "$TMP/manifest" || true)" -eq "$COUNT" ] \
  || die "the manifest project count does not match its records"

# Decode every project and capacity record up front, so a malformed manifest is
# refused before anything is checked or changed.
P_NAMES=()
P_ORIGINS=()
P_LINES=()
P_MODES=()
while IFS= read -r record; do
  IFS='|' read -r name_b64 origin_b64 line_b64 mode_b64 extra <<EOF
${record#project=}
EOF
  [ -n "$name_b64" ] && [ -n "$line_b64" ] && [ -n "$mode_b64" ] && [ -z "${extra:-}" ] \
    || die "a manifest project record is malformed"
  name=$(base64_decode "$name_b64") || die "a project name is not valid base64"
  origin=
  [ -z "$origin_b64" ] || origin=$(base64_decode "$origin_b64") || die "project $name origin is not valid base64"
  line=$(base64_decode "$line_b64") || die "project $name registry line is not valid base64"
  mode=$(base64_decode "$mode_b64") || die "project $name mode is not valid base64"
  safe_id "$name" || die "a manifest project name is unsafe: $name"
  [ -z "$origin" ] || fm_project_origin_safe "$origin" || die "project $name origin is not an accepted clone URL: $origin"
  case "$mode" in no-mistakes|direct-PR) ;; *) die "project $name has a mode a worker host cannot run: $mode" ;; esac
  case "$line" in "- $name "*) ;; *) die "project $name registry line is malformed" ;; esac
  case "$line" in *$'\n'*) die "project $name registry line spans lines" ;; esac
  P_NAMES+=("$name")
  P_ORIGINS+=("$origin")
  P_LINES+=("$line")
  P_MODES+=("$mode")
done < <(grep '^project=' "$TMP/manifest" || true)

C_NAMES=()
C_VALUES=()
while IFS= read -r record; do
  IFS='|' read -r name_b64 value extra <<EOF
${record#capacity=}
EOF
  [ -n "$name_b64" ] && [ -z "${extra:-}" ] || die "a manifest capacity record is malformed"
  name=$(base64_decode "$name_b64") || die "a capacity project name is not valid base64"
  safe_id "$name" || die "a capacity project name is unsafe: $name"
  case "$value" in [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) die "project $name capacity is not a positive integer below 1000: $value" ;; esac
  C_NAMES+=("$name")
  C_VALUES+=("$value")
done < <(grep '^capacity=' "$TMP/manifest" || true)

DATA="$FM_HOME/data"
CONFIG="$FM_HOME/config"
PROJECTS="$FM_HOME/projects"
REG="$DATA/projects.md"
TOKEN="$CONFIG/t3code-token"
LANE_FILE="$CONFIG/lane-capacity"
PROJECT_CAPACITY_FILE="$CONFIG/project-capacity"

CHECK_NAMES=()
CHECK_VALUES=()
CHECK_ACTIONS=()

# A check recorded again replaces its earlier value, so a re-check during the
# repair pass is the one later checks read.
record() { # <name> <value> [operator-action]
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      CHECK_VALUES[i]=$2
      CHECK_ACTIONS[i]=${3:-}
      return 0
    fi
    i=$((i + 1))
  done
  CHECK_NAMES+=("$1")
  CHECK_VALUES+=("$2")
  CHECK_ACTIONS+=("${3:-}")
}

check_value() { # <name>
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      printf '%s' "${CHECK_VALUES[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

check_is_ok() { # <name>
  case "$(check_value "$1" 2>/dev/null || true)" in ok:*) return 0 ;; esac
  return 1
}

fix_report() { # <check> applied|failed <text>
  printf 'fix %s=%s: %s\n' "$1" "$2" "$3"
}

real_dir() { # <path>: an existing directory that is not a link
  [ -d "$1" ] && [ ! -L "$1" ]
}

real_file() { # <path>: an existing regular file that is not a link
  [ -f "$1" ] && [ ! -L "$1" ]
}

# --- the home ------------------------------------------------------------------

# bin/fm-remote-entrypoint.sh already refuses a home that overlaps the code
# root before this command runs, so what remains is whether the home exists.
check_home() {
  if [ -e "$FM_HOME" ] || [ -L "$FM_HOME" ]; then
    if real_dir "$FM_HOME"; then
      record home "ok: $FM_HOME is its own directory, separate from the code root $FM_ROOT"
    else
      record home "human: $FM_HOME exists but is not a directory" \
        "inspect that path and move it aside yourself; Firstmate never replaces it"
    fi
    return 0
  fi
  record home "fixable: $FM_HOME does not exist" "seed this host from the primary, or rerun the doctor with --fix"
}

check_secondmate() {
  local marker found=
  for marker in .fm-secondmate-home .fm-secondmate-parent; do
    if [ -e "$FM_HOME/$marker" ] || [ -L "$FM_HOME/$marker" ]; then
      found="${found:+$found and }$marker"
    fi
  done
  if [ -n "$found" ]; then
    record secondmate "human: $FM_HOME carries $found, so it is a second-mate home" \
      "give the worker host its own home path; a worker host home must never be a second-mate home, and Firstmate changes nothing in this one"
    return 0
  fi
  record secondmate "ok: no second-mate marker"
}

check_layout() {
  local dir missing='' unsafe=''
  if ! real_dir "$FM_HOME"; then
    record layout "fixable: data/, state/, config/, and projects/ follow the home" \
      "seed this host from the primary, or rerun the doctor with --fix"
    return 0
  fi
  for dir in data state config projects; do
    if [ -e "$FM_HOME/$dir" ] || [ -L "$FM_HOME/$dir" ]; then
      real_dir "$FM_HOME/$dir" || unsafe="${unsafe:+$unsafe }$dir/"
    else
      missing="${missing:+$missing }$dir/"
    fi
  done
  if [ -n "$unsafe" ]; then
    record layout "human: $unsafe in $FM_HOME is not a plain directory" \
      "inspect it yourself; Firstmate never replaces a link or file there"
  elif [ -n "$missing" ]; then
    record layout "fixable: $FM_HOME has no $missing" "rerun the doctor with --fix"
  else
    record layout "ok: data/ state/ config/ projects/"
  fi
}

check_marker() {
  local marker="$FM_HOME/.fm-worker-host" owner
  if real_file "$marker"; then
    owner=$(head -n 1 "$marker" 2>/dev/null || true)
    if [ -n "$owner" ] && [ "$owner" != "$HOST_ID" ]; then
      record marker "human: $marker names worker host $owner, not $HOST_ID" \
        "check which primary record owns this home; two worker host records must not share one home"
      return 0
    fi
    record marker "ok: $marker"
    return 0
  fi
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    record marker "human: $marker is not a regular file" "inspect it yourself and replace it with a plain file"
    return 0
  fi
  record marker "fixable: no .fm-worker-host marker in $FM_HOME" "rerun the doctor with --fix"
}

check_backlog_backend() {
  if real_dir "$CONFIG" && fm_backlog_backend_manual "$CONFIG"; then
    record backlog-backend "ok: manual; the primary's backlog owns these tasks"
    return 0
  fi
  record backlog-backend "fixable: config/backlog-backend is not manual" "rerun the doctor with --fix"
}

# The cap bin/fm-capacity.sh reads, from its own report line: a number, "none"
# when absent, "invalid" for a malformed file, or empty when no report printed.
# Its exit status is not used, because it also fails for reasons other than the
# declaration.
lane_capacity_target() {
  local out
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-capacity.sh" 2>/dev/null || true)
  printf '%s\n' "$out" | sed -n 's/^capacity: .* target=\([^ ]*\).*/\1/p' | head -n 1
}

check_lane_capacity() {
  local target
  if [ ! -e "$LANE_FILE" ] && [ ! -L "$LANE_FILE" ]; then
    if [ -n "$LANES" ]; then
      record lane-capacity "fixable: no config/lane-capacity; the primary asks for a cap of $LANES" "rerun the seed or the doctor with --fix"
    else
      record lane-capacity "ok: absent, so this home caps no lanes"
    fi
    return 0
  fi
  if ! real_file "$LANE_FILE"; then
    record lane-capacity "human: $LANE_FILE is not a regular file" \
      "inspect it yourself and replace it with a plain lane capacity declaration"
    return 0
  fi
  target=$(lane_capacity_target)
  case "$target" in
    '')
      record lane-capacity "human: bin/fm-capacity.sh printed no report for $FM_HOME, so its lane cap cannot be read" \
        "run 'FM_HOME=$FM_HOME $FM_ROOT/bin/fm-capacity.sh' on that machine and fix what it reports"
      return 0
      ;;
    none|invalid|*[!0-9]*)
      record lane-capacity "human: $LANE_FILE is not a valid lane capacity declaration" \
        "fix it by hand; docs/configuration.md \"Lane capacity\" owns its format"
      return 0
      ;;
  esac
  if [ -n "$LANES" ] && [ "$target" != "$LANES" ]; then
    record lane-capacity "human: $LANE_FILE caps lanes at $target, not the requested $LANES" \
      "edit the cap on the host yourself; Firstmate never overwrites an existing capacity declaration"
    return 0
  fi
  record lane-capacity "ok: cap $target"
}

# One project's declared capacity in this home's own declaration, read through
# the declaration's single owner. A worker host home has no parent, so its
# root home, the one that lib reads, is itself.
project_capacity_of() { # <name>; sets PC_VALUE; fails on an unreadable declaration
  PC_VALUE=
  fm_project_capacity_lookup "$CONFIG" "$1" || return 1
  PC_VALUE=$FM_PROJECT_CAPACITY
}

check_project_capacity() {
  local i=0 name want missing='' differs=''
  if [ ! -e "$PROJECT_CAPACITY_FILE" ] && [ ! -L "$PROJECT_CAPACITY_FILE" ]; then
    if [ "${#C_NAMES[@]}" -gt 0 ]; then
      record project-capacity "fixable: no config/project-capacity; the primary declares ${C_NAMES[*]}" "rerun the seed or the doctor with --fix"
    else
      record project-capacity "ok: absent, so no project is capped on this host"
    fi
    return 0
  fi
  if ! real_file "$PROJECT_CAPACITY_FILE" || ! project_capacity_of ""; then
    record project-capacity "human: $PROJECT_CAPACITY_FILE is unreadable or malformed, which refuses every spawn on this host" \
      "fix it by hand; docs/configuration.md \"Project capacity\" owns its format"
    return 0
  fi
  while [ "$i" -lt "${#C_NAMES[@]}" ]; do
    name=${C_NAMES[$i]}
    want=${C_VALUES[$i]}
    i=$((i + 1))
    project_capacity_of "$name" || true
    if [ -z "$PC_VALUE" ]; then
      missing="${missing:+$missing }$name"
    elif [ "$PC_VALUE" != "$want" ]; then
      differs="${differs:+$differs, }$name is $PC_VALUE not $want"
    fi
  done
  if [ -n "$differs" ]; then
    record project-capacity "human: $PROJECT_CAPACITY_FILE already declares $differs" \
      "edit those lines on the host yourself; Firstmate never overwrites an existing capacity declaration"
  elif [ -n "$missing" ]; then
    record project-capacity "fixable: $PROJECT_CAPACITY_FILE does not declare $missing" "rerun the seed or the doctor with --fix"
  else
    record project-capacity "ok: $PROJECT_CAPACITY_FILE is valid"
  fi
}

# --- projects ------------------------------------------------------------------

registry_line_of() { # <name>; the home's registry line for that project, if any
  [ -f "$REG" ] || return 0
  awk -v p="- $1 " 'index($0, p) == 1 { print; exit }' "$REG"
}

project_in_scope() { # <index>
  local name=${P_NAMES[$1]}
  [ "$PROJECT_SCOPE" = named ] && return 0
  [ -e "$PROJECTS/$name" ] || [ -L "$PROJECTS/$name" ] || [ -n "$(registry_line_of "$name")" ]
}

check_project() { # <index>
  local idx=$1 name origin line mode dest existing have
  name=${P_NAMES[$idx]}
  origin=${P_ORIGINS[$idx]}
  line=${P_LINES[$idx]}
  mode=${P_MODES[$idx]}
  dest="$PROJECTS/$name"

  if real_dir "$dest" && [ -d "$dest/.git" ]; then
    existing=$(git -C "$dest" remote get-url origin 2>/dev/null || true)
    if [ -z "$origin" ]; then
      record "clone:$name" "ok: $dest (origin $existing; the primary named no origin to compare)"
    elif [ "$existing" = "$origin" ]; then
      record "clone:$name" "ok: $dest from $origin"
    else
      record "clone:$name" "human: $dest clones $existing, not the primary's $origin" \
        "inspect that clone yourself; Firstmate never replaces a clone that may hold work"
    fi
  elif [ -e "$dest" ] || [ -L "$dest" ]; then
    record "clone:$name" "human: $dest exists but is not a git clone" \
      "inspect that path yourself and move it aside; Firstmate never replaces it"
  elif [ -n "$origin" ]; then
    record "clone:$name" "fixable: no clone of $name in $PROJECTS" "rerun the seed or the doctor with --fix"
  else
    record "clone:$name" "human: no clone of $name, and the primary has no origin for it" \
      "on the primary, rerun the doctor with --fix naming $name=<origin-url>"
  fi

  have=$(registry_line_of "$name")
  if [ "$have" = "$line" ]; then
    record "registry:$name" "ok: data/projects.md matches the primary's record"
  elif [ -z "$have" ]; then
    record "registry:$name" "fixable: $name is not registered in data/projects.md" "rerun the seed or the doctor with --fix"
  else
    record "registry:$name" "fixable: data/projects.md registers $name differently from the primary ($have)" \
      "rerun the doctor with --fix to copy the primary's record, so delivery mode and forge binding match"
  fi

  if [ "$mode" != no-mistakes ]; then
    record "no-mistakes:$name" "skip: $name ships $mode"
  elif check_is_ok "clone:$name" && git -C "$dest" remote get-url no-mistakes >/dev/null 2>&1; then
    record "no-mistakes:$name" "ok: $dest has its no-mistakes remote"
  elif check_is_ok "clone:$name" || [ -n "$origin" ]; then
    record "no-mistakes:$name" "fixable: $name is not initialized for no-mistakes" "rerun the seed or the doctor with --fix"
  else
    record "no-mistakes:$name" "human: $name cannot be initialized until its clone exists" "close the clone:$name gap first"
  fi
}

# --- T3 ------------------------------------------------------------------------

# The T3 sign-in is this home's own (config/t3code-token), minted on this
# machine by the operator. bin/fm-t3-mcp.mjs owns reading it: host-credential is
# offline and gives the days left even with the server down; status proves the
# server and reports its version and capabilities.
T3_STATUS_JSON=

t3_expected() {
  [ -n "$T3_EXPECT_VERSION" ] || [ -n "$T3_EXPECT_CAPS" ]
}

check_t3() {
  local out days expires version cap have missing='' offered=''
  T3_STATUS_JSON=
  if [ ! -e "$TOKEN" ] && [ ! -L "$TOKEN" ]; then
    if t3_expected; then
      record t3-credential "human: this home has no T3 sign-in, and the primary runs T3" \
        "on that machine, as that account, run '$FM_ROOT/bin/fm-t3-mcp.mjs login --access full-access --token-file $TOKEN', then rerun the doctor"
    else
      record t3-credential "skip: this home has no T3 sign-in${T3_NOTE:+; $T3_NOTE}"
    fi
    record t3-server "skip: no T3 sign-in to check"
    record t3-version "skip: no T3 sign-in to check"
    record t3-capabilities "skip: no T3 sign-in to check"
    return 0
  fi
  if ! command -v node >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    record t3-credential "human: node and jq must both resolve on the remote runtime PATH to read the T3 sign-in" \
      "install the missing tool on that account, or add a ~/.local/bin wrapper for it"
    record t3-server "human: the T3 server cannot be checked without node and jq" "close the t3-credential gap first"
    record t3-version "human: the T3 version cannot be read without node and jq" "close the t3-credential gap first"
    record t3-capabilities "human: the T3 capabilities cannot be read without node and jq" "close the t3-credential gap first"
    return 0
  fi
  if ! out=$(node "$SCRIPT_DIR/fm-t3-mcp.mjs" host-credential --token-file "$TOKEN" 2>"$TMP/t3.err"); then
    out=$(grep -v '^warning:' "$TMP/t3.err" | tail -n 1)
    record t3-credential "human: ${out#fm-t3-mcp: }" \
      "on that machine, as that account, run '$FM_ROOT/bin/fm-t3-mcp.mjs login --access full-access --token-file $TOKEN' (the operator's sign-in), then rerun the doctor"
    record t3-server "human: the T3 server cannot be checked until this home's sign-in passes" "close the t3-credential gap first"
    record t3-version "human: the T3 version cannot be read until this home's sign-in passes" "close the t3-credential gap first"
    record t3-capabilities "human: the T3 capabilities cannot be read until this home's sign-in passes" "close the t3-credential gap first"
    return 0
  fi
  days=$(printf '%s' "$out" | jq -r '.daysLeft // empty')
  expires=$(printf '%s' "$out" | jq -r '.expiresAt // empty')
  record t3-credential "ok: ${days:-unknown} days left (expires ${expires:-unknown}); the operator signs in again before then"

  if ! T3_STATUS_JSON=$(node "$SCRIPT_DIR/fm-t3-mcp.mjs" status --token-file "$TOKEN" 2>"$TMP/t3.err"); then
    T3_STATUS_JSON=
    out=$(grep -v '^warning:' "$TMP/t3.err" | tail -n 1)
    record t3-server "human: ${out#fm-t3-mcp: }" \
      "start T3 Code on that machine and keep it running, or sign in again there if the sign-in was refused, then rerun the doctor"
    record t3-version "human: the T3 version cannot be read until its server answers" "close the t3-server gap first"
    record t3-capabilities "human: the T3 capabilities cannot be read until its server answers" "close the t3-server gap first"
    return 0
  fi
  record t3-server "ok: the T3 server this home signed in to answers and passes the capability gate"

  version=$(printf '%s' "$T3_STATUS_JSON" | jq -r '.serverVersion // "unknown"')
  if [ -z "$T3_EXPECT_VERSION" ]; then
    record t3-version "skip: this host runs T3 $version; the primary named no version to match${T3_NOTE:+ ($T3_NOTE)}"
  elif [ "$version" = "$T3_EXPECT_VERSION" ]; then
    record t3-version "ok: T3 $version, the same build as the primary"
  else
    record t3-version "human: this host runs T3 $version, but the primary runs $T3_EXPECT_VERSION" \
      "install T3 $T3_EXPECT_VERSION on that machine, restart its service, and rerun the doctor"
  fi

  for cap in $T3_CAPABILITY_NAMES; do
    have=$(printf '%s' "$T3_STATUS_JSON" | jq -r --arg c "$cap" '.[$c] // false')
    [ "$have" != true ] || offered="${offered:+$offered }$cap"
  done
  for cap in ${T3_EXPECT_CAPS//,/ }; do
    case " $offered " in *" $cap "*) ;; *) missing="${missing:+$missing }$cap" ;; esac
  done
  if [ -n "$missing" ]; then
    record t3-capabilities "human: this host's T3 lacks $missing, which the primary uses" \
      "install the T3 build the primary runs on that machine, then rerun the doctor"
  elif [ -n "$T3_EXPECT_CAPS" ]; then
    record t3-capabilities "ok: offers ${offered:-none}, covering the primary's ${T3_EXPECT_CAPS//,/ }"
  else
    record t3-capabilities "skip: offers ${offered:-none}; the primary named no capability to match"
  fi
}

run_checks() {
  local i=0
  CHECK_NAMES=()
  CHECK_VALUES=()
  CHECK_ACTIONS=()
  check_home
  check_secondmate
  check_layout
  check_marker
  check_backlog_backend
  check_lane_capacity
  check_project_capacity
  while [ "$i" -lt "${#P_NAMES[@]}" ]; do
    if project_in_scope "$i"; then check_project "$i"; fi
    i=$((i + 1))
  done
  check_t3
}

# --- repairs -------------------------------------------------------------------

acquire_lock() {
  # The lock lives beside the home, in the same place and under the same key
  # bin/fm-remote-home-provision.sh uses, so a worker host seed and a second
  # mate seed aimed at one path never interleave.
  local parent lock_root key
  parent=$(dirname "$FM_HOME")
  real_dir "$parent" || { fix_report home failed "the home's parent $parent is not a directory"; return 1; }
  lock_root="$parent/.firstmate-provision-locks"
  if [ -e "$lock_root" ] || [ -L "$lock_root" ]; then
    real_dir "$lock_root" || { fix_report home failed "the provisioning lock root $lock_root is unsafe"; return 1; }
  else
    mkdir "$lock_root" 2>/dev/null || true
    real_dir "$lock_root" || { fix_report home failed "cannot create the provisioning lock root $lock_root"; return 1; }
  fi
  if command -v shasum >/dev/null 2>&1; then
    key=$(printf '%s' "$FM_HOME" | shasum -a 256 | awk '{print $1}')
  else
    key=$(printf '%s' "$FM_HOME" | sha256sum | awk '{print $1}')
  fi
  # shellcheck disable=SC2034 # read by bin/fm-wake-lib.sh as it is sourced.
  FM_STATE_OVERRIDE="$lock_root"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  LOCK="$lock_root/.remote-home-provision-$key.lock"
  fm_lock_acquire_wait "$LOCK" || { fix_report home failed "cannot lock $FM_HOME for provisioning"; return 1; }
  LOCK_HELD=1
}

write_file() { # <path> <content>: replace one small file atomically
  printf '%s\n' "$2" > "$1.tmp.$$" && mv -f -- "$1.tmp.$$" "$1"
}

fix_home() {
  if mkdir -p -- "$FM_HOME" 2>/dev/null && real_dir "$FM_HOME"; then
    fix_report home applied "created $FM_HOME"
  else
    fix_report home failed "could not create $FM_HOME"
  fi
}

fix_layout() {
  local dir made=
  for dir in data state config projects; do
    [ ! -e "$FM_HOME/$dir" ] && [ ! -L "$FM_HOME/$dir" ] || continue
    mkdir -- "$FM_HOME/$dir" || { fix_report layout failed "could not create $dir/"; return 0; }
    made="${made:+$made }$dir/"
  done
  fix_report layout applied "created $made"
}

fix_marker() {
  if write_file "$FM_HOME/.fm-worker-host" "$HOST_ID"; then
    fix_report marker applied "wrote .fm-worker-host for $HOST_ID"
  else
    fix_report marker failed "could not write .fm-worker-host"
  fi
}

fix_backlog_backend() {
  if write_file "$CONFIG/backlog-backend" manual; then
    fix_report backlog-backend applied "set config/backlog-backend to manual"
  else
    fix_report backlog-backend failed "could not write config/backlog-backend"
  fi
}

fix_lane_capacity() {
  [ -n "$LANES" ] || return 0
  [ ! -e "$LANE_FILE" ] && [ ! -L "$LANE_FILE" ] || return 0
  if write_file "$LANE_FILE" "$LANES"; then
    fix_report lane-capacity applied "declared a cap of $LANES lanes"
  else
    fix_report lane-capacity failed "could not write config/lane-capacity"
  fi
}

fix_project_capacity() {
  local i=0 name added=
  if [ ! -e "$PROJECT_CAPACITY_FILE" ] && [ ! -L "$PROJECT_CAPACITY_FILE" ]; then
    printf '# workers each project admits at once on this worker host\n' > "$PROJECT_CAPACITY_FILE" \
      || { fix_report project-capacity failed "could not create config/project-capacity"; return 0; }
  fi
  while [ "$i" -lt "${#C_NAMES[@]}" ]; do
    name=${C_NAMES[$i]}
    project_capacity_of "$name" || { fix_report project-capacity failed "config/project-capacity is unreadable"; return 0; }
    if [ -z "$PC_VALUE" ]; then
      printf '%s %s\n' "$name" "${C_VALUES[$i]}" >> "$PROJECT_CAPACITY_FILE" \
        || { fix_report project-capacity failed "could not declare $name"; return 0; }
      added="${added:+$added, }$name ${C_VALUES[$i]}"
    fi
    i=$((i + 1))
  done
  [ -z "$added" ] || fix_report project-capacity applied "declared $added"
}

fix_clone() { # <index>
  local name=${P_NAMES[$1]} origin=${P_ORIGINS[$1]} stage
  # Clone beside the destination and publish by rename, so a failed or killed
  # clone never leaves a half-written project where a later check would read it.
  stage=$(mktemp -d "$PROJECTS/.fm-clone-$name.XXXXXX") \
    || { fix_report "clone:$name" failed "cannot stage a clone in $PROJECTS"; return 0; }
  if git clone --no-local --quiet -- "$origin" "$stage/repo" >"$TMP/clone.err" 2>&1 \
    && mv -- "$stage/repo" "$PROJECTS/$name"; then
    rm -rf -- "$stage"
    fix_report "clone:$name" applied "cloned $origin"
    return 0
  fi
  rm -rf -- "$stage"
  fix_report "clone:$name" failed "git clone of $origin failed: $(tail -n 1 "$TMP/clone.err")"
}

fix_registry() { # <index>
  local name=${P_NAMES[$1]} line=${P_LINES[$1]}
  if {
    [ ! -f "$REG" ] || awk -v p="- $name " 'index($0, p) != 1' "$REG"
    printf '%s\n' "$line"
  } > "$REG.tmp.$$" && mv -f -- "$REG.tmp.$$" "$REG"; then
    fix_report "registry:$name" applied "copied the primary's record"
  else
    fix_report "registry:$name" failed "could not write data/projects.md"
  fi
}

fix_no_mistakes() { # <index>
  local name=${P_NAMES[$1]} dest="$PROJECTS/${P_NAMES[$1]}"
  real_dir "$dest" && [ -d "$dest/.git" ] || { fix_report "no-mistakes:$name" failed "$name has no clone to initialize"; return 0; }
  command -v no-mistakes >/dev/null 2>&1 \
    || { fix_report "no-mistakes:$name" failed "no-mistakes does not resolve on the remote runtime PATH"; return 0; }
  if (cd "$dest" && no-mistakes init >"$TMP/nm.out" 2>&1); then
    fix_report "no-mistakes:$name" applied "ran no-mistakes init"
  else
    fix_report "no-mistakes:$name" failed "no-mistakes init failed: $(tail -n 1 "$TMP/nm.out")"
  fi
}

value_is_fixable() { # <check>
  case "$(check_value "$1" 2>/dev/null || true)" in fixable:*) return 0 ;; esac
  return 1
}

apply_fixes() {
  local i=0
  # A second-mate home, or a home that is not safely its own directory, is
  # never changed: those are the human gaps the checks already name.
  check_is_ok secondmate || return 0
  case "$(check_value home)" in ok:*|fixable:*) ;; *) return 0 ;; esac
  acquire_lock || return 0
  if value_is_fixable home; then
    fix_home
    real_dir "$FM_HOME" || return 0
  fi
  # Re-read each fact just before repairing it, in dependency order:
  # directories before the files and clones inside them.
  check_layout
  if value_is_fixable layout; then fix_layout; fi
  check_layout
  check_is_ok layout || return 0
  check_marker
  if value_is_fixable marker; then fix_marker; fi
  check_backlog_backend
  if value_is_fixable backlog-backend; then fix_backlog_backend; fi
  check_lane_capacity
  if value_is_fixable lane-capacity; then fix_lane_capacity; fi
  check_project_capacity
  if value_is_fixable project-capacity; then fix_project_capacity; fi
  while [ "$i" -lt "${#P_NAMES[@]}" ]; do
    if project_in_scope "$i"; then
      check_project "$i"
      if value_is_fixable "clone:${P_NAMES[$i]}"; then fix_clone "$i"; fi
      if value_is_fixable "registry:${P_NAMES[$i]}"; then fix_registry "$i"; fi
      check_project "$i"
      if value_is_fixable "no-mistakes:${P_NAMES[$i]}"; then fix_no_mistakes "$i"; fi
    fi
    i=$((i + 1))
  done
}

# --- report --------------------------------------------------------------------

printf 'mode=%s\n' "$MODE"
printf 'home=%s\n' "$FM_HOME"
run_checks
if [ "$MODE" = fix ]; then
  apply_fixes
  run_checks
fi

GAPS=()
i=0
while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
  printf 'check %s=%s\n' "${CHECK_NAMES[$i]}" "${CHECK_VALUES[$i]}"
  case "${CHECK_VALUES[$i]}" in fixable:*|human:*) GAPS+=("$i") ;; esac
  i=$((i + 1))
done
NAMES=
for i in ${GAPS[@]+"${GAPS[@]}"}; do
  [ -z "${CHECK_ACTIONS[$i]}" ] || printf 'action: %s: %s\n' "${CHECK_NAMES[$i]}" "${CHECK_ACTIONS[$i]}"
  NAMES="${NAMES:+$NAMES }${CHECK_NAMES[$i]}"
done
if [ "${#GAPS[@]}" -gt 0 ]; then
  printf 'error: this worker host home is not ready; unresolved: %s\n' "$NAMES" >&2
  exit 1
fi
printf 'ok: worker host home ready at %s\n' "$FM_HOME"
