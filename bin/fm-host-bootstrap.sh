#!/usr/bin/env bash
# fm-host-bootstrap.sh - idempotent new-host setup and verification for a
# Firstmate primary or worker/remote-secondmate host (macOS or Linux).
#
# Usage:
#   fm-host-bootstrap.sh [--fix] [--role primary|worker|both] [--backend <name>]
#   fm-host-bootstrap.sh --ssh <ssh-alias> --remote-root <abs-path>
#                        [--fix] [--role primary|worker|both] [--backend <name>]
#
# Run locally on a fresh Mac (inside a cloned Firstmate checkout), or against a
# fresh Mac over SSH before it is registered in data/worker-hosts.md or
# data/secondmates.md. It reuses bin/fm-bootstrap.sh's toolchain definitions
# and installer, plus bin/fm-remote-doctor.sh for worker/remote account
# readiness (Aqua LaunchAgents, entrypoint symlink, and version-manager
# wrappers), rather than duplicating a parallel system.
#
# Roles:
#   primary  Checks (and with --fix installs/upgrades) the universal fleet
#            toolchain and selected backend CLI, verifies agent harnesses, and
#            lists human-only sign-ins (Apple ID/macOS console, GitHub, Claude,
#            Antigravity, T3 Code).
#   worker   Checks everything in primary plus the fixed remote entrypoint
#            symlink (~/.local/bin/fm-remote-entrypoint.sh) and delegates
#            account/service readiness to bin/fm-remote-doctor.sh.
#   both     Default. Prepares a machine so it can serve as either a primary
#            Firstmate home or an equal worker / remote-secondmate host.
#
# Line protocol, one fact per line (matching bin/fm-remote-doctor.sh):
#   mode=check|fix
#   role=primary|worker|both
#   backend=<resolved-backend>
#   platform=darwin|linux|<uname -s>|unknown
#   tool <name>=ok: <path>|outdated: <detail>|missing: <cmd>|manual: <url>
#   fix <check>=applied: <what changed>         (--fix only)
#   fix <check>=failed: <why it did not land>   (--fix only)
#   check <name>=ok|skip|fixable|human: <evidence>
#   action: <name>: <exact step>
#
# Idempotency and safety:
#   - Check mode (default) is read-only.
#   - --fix installs only missing automatable tools (via bin/fm-bootstrap.sh
#     install), upgrades outdated automatable tools with their own updater,
#     creates ~/.local/bin/fm-remote-entrypoint.sh only when absent (never
#     overwriting a non-Firstmate file), and runs bin/fm-remote-doctor.sh --fix
#     for worker/both roles.
#   - It NEVER runs interactive sign-ins, never touches FileVault or auto-login
#     passwords, never writes credentials, and never modifies another machine's
#     live fleet config. Every sign-in only a person can do stays reported as
#     `human:` until completed.
#   - --ssh disables agent forwarding, port forwarding, and SendEnv patterns
#     and arms bounded SSH dead-peer detection, matching bin/fm-on.sh.
#
# Exit status: 0 when every required tool, service, and sign-in check passes;
# 1 when any automatable or human gap remains; 2 on usage; 255 on SSH failure.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,/^set -eu$/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }

MODE=check
ROLE=both
BACKEND_ARG=
SSH_ALIAS=
REMOTE_ROOT=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fix) MODE=fix; shift ;;
    --role)
      [ "$#" -ge 2 ] || usage
      case "$2" in primary|worker|both) ROLE=$2 ;; *) die "invalid --role '$2' (expected primary, worker, or both)" 2 ;; esac
      shift 2
      ;;
    --backend)
      [ "$#" -ge 2 ] || usage
      BACKEND_ARG=$2
      shift 2
      ;;
    --ssh)
      [ "$#" -ge 2 ] || usage
      SSH_ALIAS=$2
      shift 2
      ;;
    --remote-root)
      [ "$#" -ge 2 ] || usage
      REMOTE_ROOT=$2
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

# Over-SSH mode for a fresh Mac before registration in data/worker-hosts.md.
if [ -n "$SSH_ALIAS" ]; then
  case "$SSH_ALIAS" in ''|-*|*[!A-Za-z0-9._-]*) die "unsafe SSH alias: $SSH_ALIAS" ;; esac
  [ -n "$REMOTE_ROOT" ] || die "--ssh requires --remote-root <absolute-path-to-firstmate-clone>"
  case "$REMOTE_ROOT" in /*) ;; *) die "--remote-root must be an absolute path: $REMOTE_ROOT" ;; esac
  case "$REMOTE_ROOT" in *$'\n'*|*$'\r'*|*$'\t'*|*"'"*|*'"'*|*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*)
    die "--remote-root contains unsafe characters: $REMOTE_ROOT" ;;
  esac
  case "/$REMOTE_ROOT/" in */../*|*/./*) die "--remote-root must not contain path traversal: $REMOTE_ROOT" ;; esac
  if [ -n "$BACKEND_ARG" ]; then
    case "$BACKEND_ARG" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid --backend: $BACKEND_ARG" ;; esac
  fi
  SSH_BIN=${FM_SSH_BIN:-ssh}
  ALIVE_INTERVAL=${FM_SSH_ALIVE_INTERVAL:-15}
  ALIVE_COUNT_MAX=${FM_SSH_ALIVE_COUNT_MAX:-3}
  REMOTE_ARGS=("$REMOTE_ROOT/bin/fm-host-bootstrap.sh" --role "$ROLE")
  [ "$MODE" != fix ] || REMOTE_ARGS+=(--fix)
  [ -z "$BACKEND_ARG" ] || REMOTE_ARGS+=(--backend "$BACKEND_ARG")
  exec "$SSH_BIN" \
    -o ForwardAgent=no \
    -o ClearAllForwardings=yes \
    -o 'SendEnv=-*' \
    -o "ServerAliveInterval=$ALIVE_INTERVAL" \
    -o "ServerAliveCountMax=$ALIVE_COUNT_MAX" \
    -- "$SSH_ALIAS" "${REMOTE_ARGS[@]}" < /dev/null
elif [ -n "$REMOTE_ROOT" ]; then
  die "--remote-root applies only with --ssh"
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"

if [ -n "$BACKEND_ARG" ]; then
  FM_BACKEND=$BACKEND_ARG
  export FM_BACKEND
fi
BACKEND=$(fm_backend_name)
if ! fm_backend_required_tools "$BACKEND" >/dev/null 2>&1; then
  die "unknown backend '$BACKEND' (see docs/configuration.md \"Runtime backend\")"
fi
PLATFORM=$(fm_remote_job_platform)
ENTRYPOINT_LINK="${HOME:-}/.local/bin/fm-remote-entrypoint.sh"
HARNESS_CANDIDATES=(claude agy codex pi pi-signed grok opencode cursor-agent omp)

CHECK_NAMES=()
CHECK_VALUES=()
CHECK_ACTIONS=()
TOOL_MISSING=()
TOOL_OUTDATED=()
TOOL_OUTDATED_CMDS=()
TOOL_MANUAL=()

record() { # <name> <value> [action]
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

fix_report() { # <check> applied|failed <detail>
  printf 'fix %s=%s: %s\n' "$1" "$2" "$3"
}

shared_entrypoint_valid() { # <target>
  local target=$1 root
  case "$target" in /*/bin/fm-remote-entrypoint.sh) ;; *) return 1 ;; esac
  root=${target%/bin/fm-remote-entrypoint.sh}
  [ -f "$target" ] && [ ! -L "$target" ] && [ -x "$target" ] \
    && [ -d "$root/bin" ] && [ ! -L "$root/bin" ] \
    && [ -f "$root/AGENTS.md" ] && [ ! -L "$root/AGENTS.md" ]
}

# Run fm-bootstrap.sh in local detect-only mode to reuse its single-owned
# version floors, backend delta, and install/upgrade commands without running
# fleet sync or mutating any home state.
scan_toolchain() {
  local diag line tool rest cmd url
  TOOL_MISSING=()
  TOOL_OUTDATED=()
  TOOL_OUTDATED_CMDS=()
  TOOL_MANUAL=()
  diag=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip FM_BACKEND="$BACKEND" \
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-bootstrap.sh" 2>/dev/null || true)
  while IFS= read -r line; do
    case "$line" in
      'MISSING: '*)
        rest=${line#MISSING: }
        tool=${rest%% *}
        cmd=$(printf '%s' "$rest" | sed -n 's/^[^ ]* (install: \(.*\))$/\1/p')
        TOOL_MISSING+=("$tool")
        record "tool:$tool" "fixable: missing ($cmd)" "rerun with --fix, or run: $cmd"
        ;;
      'OUTDATED: '*)
        rest=${line#OUTDATED: }
        tool=${rest%% *}
        cmd=$(printf '%s' "$rest" | sed -n 's/.*; upgrade: \(.*\))$/\1/p')
        TOOL_OUTDATED+=("$tool")
        TOOL_OUTDATED_CMDS+=("$cmd")
        record "tool:$tool" "fixable: outdated ($rest)" "rerun with --fix, or run: $cmd"
        ;;
      'MISSING_MANUAL: '*)
        rest=${line#MISSING_MANUAL: }
        tool=${rest%% *}
        url=$(printf '%s' "$rest" | sed -n 's/^[^ ]* (instructions: \(.*\))$/\1/p')
        TOOL_MANUAL+=("$tool")
        record "tool:$tool" "human: not installed (manual install)" "install $tool from ${url:-its vendor instructions}, then rerun"
        ;;
      'PRESENTATION_UNAVAILABLE: '*)
        rest=${line#PRESENTATION_UNAVAILABLE: }
        record "tool:lavish-axi" "skip: optional presentation tool ($rest)"
        ;;
    esac
  done <<EOF
$diag
EOF
  # jq is always needed on worker hosts and for auto lane budgeting.
  if ! command -v jq >/dev/null 2>&1; then
    local seen=0 t
    for t in ${TOOL_MISSING[@]+"${TOOL_MISSING[@]}"}; do
      [ "$t" != jq ] || seen=1
    done
    if [ "$seen" -eq 0 ]; then
      TOOL_MISSING+=(jq)
      record "tool:jq" "fixable: missing (brew install jq)" "rerun with --fix, or install jq"
    fi
  fi
  if [ "$PLATFORM" = darwin ]; then
    if command -v lsof >/dev/null 2>&1; then
      record "tool:lsof" "ok: $(command -v lsof)"
    else
      record "tool:lsof" "human: lsof is missing on macOS" "restore macOS command-line tools (xcode-select --install)"
    fi
  fi
  if [ "${#TOOL_MISSING[@]}" -eq 0 ] && [ "${#TOOL_OUTDATED[@]}" -eq 0 ] && [ "${#TOOL_MANUAL[@]}" -eq 0 ]; then
    record toolchain "ok: universal and $BACKEND toolchain satisfied"
  else
    record toolchain "fixable: toolchain gaps remain (see tool:* lines)" "rerun with --fix for automatable tools and install any manual tools"
  fi
}

fix_toolchain() {
  local i tool cmd out
  for tool in ${TOOL_MISSING[@]+"${TOOL_MISSING[@]}"}; do
    if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-bootstrap.sh" install "$tool" 2>&1); then
      fix_report "tool:$tool" applied "installed $tool via fm-bootstrap.sh install"
    else
      fix_report "tool:$tool" failed "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  i=0
  while [ "$i" -lt "${#TOOL_OUTDATED[@]}" ]; do
    tool=${TOOL_OUTDATED[$i]}
    cmd=${TOOL_OUTDATED_CMDS[$i]}
    i=$((i + 1))
    cmd=${cmd%%  #*}
    if [ -z "$cmd" ]; then
      fix_report "tool:$tool" failed "no upgrade command reported"
      continue
    fi
    if out=$(bash -c "$cmd" 2>&1); then
      fix_report "tool:$tool" applied "upgraded $tool ($cmd)"
    else
      fix_report "tool:$tool" failed "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
}

check_entrypoint() {
  local want="$FM_ROOT/bin/fm-remote-entrypoint.sh"
  if [ "$ROLE" = primary ]; then
    record remote-entrypoint "skip: not required for primary-only role"
    return 0
  fi
  if [ -L "$ENTRYPOINT_LINK" ] && [ "$(readlink "$ENTRYPOINT_LINK")" = "$want" ]; then
    record remote-entrypoint "ok: $ENTRYPOINT_LINK -> $want"
  elif [ -L "$ENTRYPOINT_LINK" ] && shared_entrypoint_valid "$(readlink "$ENTRYPOINT_LINK")"; then
    record remote-entrypoint "ok: $ENTRYPOINT_LINK -> $(readlink "$ENTRYPOINT_LINK") (shared entrypoint)"
  elif [ -e "$ENTRYPOINT_LINK" ] || [ -L "$ENTRYPOINT_LINK" ]; then
    record remote-entrypoint "human: $ENTRYPOINT_LINK exists and is not a Firstmate entrypoint symlink" \
      "inspect $ENTRYPOINT_LINK and replace it with 'ln -sfn $want $ENTRYPOINT_LINK'; Firstmate never overwrites a non-Firstmate file"
  else
    record remote-entrypoint "fixable: missing $ENTRYPOINT_LINK" "rerun with --fix to link $ENTRYPOINT_LINK -> $want"
  fi
}

fix_entrypoint() {
  local want="$FM_ROOT/bin/fm-remote-entrypoint.sh"
  [ "$ROLE" != primary ] || return 0
  [ ! -e "$ENTRYPOINT_LINK" ] && [ ! -L "$ENTRYPOINT_LINK" ] || return 0
  if mkdir -p "$(dirname "$ENTRYPOINT_LINK")" 2>/dev/null && ln -s "$want" "$ENTRYPOINT_LINK" 2>/dev/null; then
    fix_report remote-entrypoint applied "linked $ENTRYPOINT_LINK -> $want"
  else
    fix_report remote-entrypoint failed "could not link $ENTRYPOINT_LINK -> $want"
  fi
}

check_remote_account() {
  local doctor_backend=any out rc=0 gap_line
  if [ "$ROLE" = primary ]; then
    record remote-account "skip: not required for primary-only role"
    return 0
  fi
  case "$BACKEND" in herdr|rex|t3code) doctor_backend=$BACKEND ;; esac
  out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-remote-doctor.sh" --backend "$doctor_backend" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    record remote-account "ok: fm-remote-doctor.sh ($doctor_backend) passed"
  else
    gap_line=$(printf '%s\n' "$out" | grep -E '^check [^=]+=(fixable|human):' | head -n 1 || true)
    if printf '%s\n' "$out" | grep -q '^check [^=]*=fixable:'; then
      record remote-account "fixable: fm-remote-doctor.sh ($doctor_backend) reported gaps${gap_line:+ ($gap_line)}" \
        "rerun with --fix, or run 'bin/fm-remote-doctor.sh --fix --backend $doctor_backend'"
    else
      record remote-account "human: fm-remote-doctor.sh ($doctor_backend) reported human gaps${gap_line:+ ($gap_line)}" \
        "run 'bin/fm-remote-doctor.sh --backend $doctor_backend' to see all operator steps"
    fi
  fi
}

fix_remote_account() {
  local doctor_backend=any out rc=0
  [ "$ROLE" != primary ] || return 0
  case "$BACKEND" in herdr|rex|t3code) doctor_backend=$BACKEND ;; esac
  out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-remote-doctor.sh" --fix --backend "$doctor_backend" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    fix_report remote-account applied "fm-remote-doctor.sh --fix ($doctor_backend) converged"
  else
    fix_report remote-account failed "fm-remote-doctor.sh --fix ($doctor_backend) left gaps (check human steps)"
  fi
}

check_harnesses() {
  local h found='' resolved
  for h in "${HARNESS_CANDIDATES[@]}"; do
    resolved=$(command -v "$h" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
      found="${found:+$found, }$h"
    fi
  done
  if [ -n "$found" ]; then
    record harnesses "ok: installed ($found)"
  else
    record harnesses "human: no verified agent harness found on PATH" \
      "install at least one verified harness (e.g. Claude Code, Antigravity agy, Codex, Pi, Grok, or OpenCode)"
  fi
}

check_human_signins() {
  local uid_num token out days
  # 1. Apple ID / macOS console GUI login + Remote Login (macOS only)
  if [ "$PLATFORM" = darwin ]; then
    uid_num=$(id -u 2>/dev/null || true)
    if [ -n "$uid_num" ] && command -v launchctl >/dev/null 2>&1 \
       && launchctl print "gui/$uid_num" >/dev/null 2>&1; then
      record signin-apple-macos "ok: Aqua GUI session active for uid $uid_num (sign in to Apple ID, enable Remote Login, and configure automatic login / FileVault at console if running headless)"
    else
      record signin-apple-macos "human: no active macOS Aqua GUI session for uid ${uid_num:-unknown}" \
        "sign in at the Mac console (Apple ID, Remote Login in System Settings > General > Sharing, and automatic login / FileVault posture for headless reboots)"
    fi
  else
    record signin-apple-macos "skip: macOS console sign-in applies only on Darwin"
  fi

  # 2. GitHub CLI authentication
  if ! command -v gh >/dev/null 2>&1; then
    record signin-github "human: gh is not installed yet" "install gh, then run 'gh auth login'"
  elif gh auth status >/dev/null 2>&1; then
    record signin-github "ok: gh auth status passed"
  else
    record signin-github "human: GitHub CLI is not authenticated" "run 'gh auth login' interactively as this account"
  fi

  # 3. Claude sign-in (human interactive /login)
  if command -v claude >/dev/null 2>&1; then
    record signin-claude "human: interactive sign-in required on a fresh host (claude resolves at $(command -v claude))" \
      "run 'claude' and complete '/login' in the Aqua GUI session so credentials store in the login keychain"
  else
    record signin-claude "human: claude CLI is not installed" \
      "install Claude Code, then run 'claude' and complete '/login'"
  fi

  # 4. Antigravity sign-in (human interactive login)
  if command -v agy >/dev/null 2>&1; then
    record signin-antigravity "human: interactive sign-in required on a fresh host (agy resolves at $(command -v agy))" \
      "sign in to Antigravity (agy) interactively on this host"
  else
    record signin-antigravity "human: agy CLI is not installed (optional unless using Antigravity)" \
      "install Antigravity CLI (agy) and sign in interactively if this host runs Antigravity"
  fi

  # 5. T3 Code sign-in (loopback host credential check)
  token="$CONFIG/t3code-token"
  if [ -f "$token" ] && [ ! -L "$token" ] && command -v node >/dev/null 2>&1 \
     && out=$(node "$SCRIPT_DIR/fm-t3-mcp.mjs" host-credential --token-file "$token" 2>/dev/null); then
    days=$(printf '%s' "$out" | sed -n 's/.*"daysLeft":[[:space:]]*\([0-9]*\).*/\1/p' | head -n 1)
    record signin-t3code "ok: valid host T3 credential at $token (${days:-unknown} days left)"
  else
    record signin-t3code "human: no valid T3 Code sign-in at $token" \
      "open T3 Code on this host, then run '$FM_ROOT/bin/fm-t3-mcp.mjs login --access full-access --token-file $token'"
  fi
}

run_checks() {
  CHECK_NAMES=()
  CHECK_VALUES=()
  CHECK_ACTIONS=()
  scan_toolchain
  check_harnesses
  check_entrypoint
  check_remote_account
  check_human_signins
}

printf 'mode=%s\n' "$MODE"
printf 'role=%s\n' "$ROLE"
printf 'backend=%s\n' "$BACKEND"
printf 'platform=%s\n' "$PLATFORM"

run_checks
if [ "$MODE" = fix ]; then
  fix_toolchain
  fix_entrypoint
  fix_remote_account
  run_checks
fi

GAPS=()
i=0
while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
  printf 'check %s=%s\n' "${CHECK_NAMES[$i]}" "${CHECK_VALUES[$i]}"
  case "${CHECK_VALUES[$i]}" in
    fixable:*|human:*) GAPS+=("$i") ;;
  esac
  i=$((i + 1))
done
for i in ${GAPS[@]+"${GAPS[@]}"}; do
  [ -z "${CHECK_ACTIONS[$i]}" ] || printf 'action: %s: %s\n' "${CHECK_NAMES[$i]}" "${CHECK_ACTIONS[$i]}"
done

if [ "${#GAPS[@]}" -gt 0 ]; then
  NAMES=
  for i in "${GAPS[@]}"; do
    NAMES="${NAMES:+$NAMES }${CHECK_NAMES[$i]}"
  done
  printf 'summary: host bootstrap has remaining gaps (%s)\n' "$NAMES" >&2
  exit 1
fi
printf 'ok: host bootstrap verified for role=%s backend=%s\n' "$ROLE" "$BACKEND"
exit 0
