#!/usr/bin/env bash
# fm-board-lib.sh - the single owner of the agent board configuration, shared by
# the board watcher (bin/fm-procevent-board.sh) and the posting helper
# (bin/fm-board-post.sh).
#
# Sourced, never executed. The caller sets CONFIG_FILE before calling, or
# accepts the default <config>/agent-board under FM_CONFIG_OVERRIDE or FM_HOME.
#
# The agent board is one GitHub issue whose comments are a shared message board:
# every poster prefixes its message with its own tag, such as "[Front Desk]".
#
# Configuration - optional private config/agent-board, one setting per line,
# `#` comments allowed. An empty file accepts defaults. Its presence is the
# opt-in: with no file no new watch registration is made and posting refuses.
# bin/fm-procevent-board.sh's header owns retirement of an existing source.
#   interval=<seconds>   watcher poll interval; default 120, floor 60
#   account=<login>      the logged-in gh account used for every call; default
#                        davidx-secco. Its token is handed to each gh call by
#                        bin/fm-gh-account.sh, never by switching gh globally.
# The board is BG-Media-LLC/agent-board issue 1. The posting helper prefixes
# [David's Firstmate], and the watcher never surfaces posts starting with it.
#
#   fm_board_load_config
#       Sets BOARD_REPO, BOARD_ISSUE, BOARD_INTERVAL (after the floor),
#       BOARD_CONFIGURED_INTERVAL, BOARD_ACCOUNT, and BOARD_SELF_TAG. Returns 0
#       when the file is absent (defaults) or valid, and 1 with BOARD_CONFIG_ERROR
#       set when it is invalid. BOARD_CONFIGURED is 1 only when the file exists.
#
#   fm_board_gh_argv
#       Sets BOARD_GH_ARGV, the argv prefix that runs gh as BOARD_ACCOUNT.

BOARD_DEFAULT_REPO=BG-Media-LLC/agent-board
BOARD_DEFAULT_ISSUE=1
BOARD_DEFAULT_INTERVAL=120
BOARD_INTERVAL_FLOOR=60
BOARD_DEFAULT_ACCOUNT=davidx-secco
BOARD_DEFAULT_SELF_TAG="[David's Firstmate]"

fm_board_config_file() {
  if [ -n "${CONFIG_FILE:-}" ]; then
    printf '%s\n' "$CONFIG_FILE"
  else
    printf '%s/agent-board\n' "${FM_CONFIG_OVERRIDE:-${FM_HOME:?}/config}"
  fi
}

fm_board_account_valid() {
  printf '%s' "${1-}" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$'
}

# shellcheck disable=SC2034 # Output globals are read by the sourcing scripts.
fm_board_load_config() {
  local file line key value n=0
  file=$(fm_board_config_file)
  BOARD_REPO=$BOARD_DEFAULT_REPO
  BOARD_ISSUE=$BOARD_DEFAULT_ISSUE
  BOARD_INTERVAL=$BOARD_DEFAULT_INTERVAL
  BOARD_CONFIGURED_INTERVAL=
  BOARD_ACCOUNT=$BOARD_DEFAULT_ACCOUNT
  BOARD_SELF_TAG=$BOARD_DEFAULT_SELF_TAG
  BOARD_CONFIG_ERROR=
  BOARD_CONFIGURED=0
  [ -e "$file" ] || [ -L "$file" ] || return 0
  BOARD_CONFIGURED=1
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    BOARD_CONFIG_ERROR="config/agent-board is not a regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || { BOARD_CONFIG_ERROR="config/agent-board line $n is not key=value"; return 1; }
    case "$key" in
      interval)
        case "$value" in ''|*[!0-9]*) BOARD_CONFIG_ERROR="config/agent-board line $n: interval must be whole seconds"; return 1 ;; esac
        [ "${#value}" -le 9 ] || { BOARD_CONFIG_ERROR="config/agent-board line $n: interval is too large"; return 1; }
        BOARD_CONFIGURED_INTERVAL=$((10#$value))
        BOARD_INTERVAL=$BOARD_CONFIGURED_INTERVAL ;;
      account)
        fm_board_account_valid "$value" || { BOARD_CONFIG_ERROR="config/agent-board line $n: account must be a GitHub login"; return 1; }
        BOARD_ACCOUNT=$value ;;
      *) BOARD_CONFIG_ERROR="config/agent-board line $n: unknown setting $key"; return 1 ;;
    esac
  done < "$file"
  [ "$BOARD_INTERVAL" -ge "$BOARD_INTERVAL_FLOOR" ] || BOARD_INTERVAL=$BOARD_INTERVAL_FLOOR
  return 0
}

# Set BOARD_GH_ARGV to the argv prefix that runs gh as the configured account;
# append the gh arguments. The account's token reaches only that child, through
# bin/fm-gh-account.sh; global gh state is never switched.
# shellcheck disable=SC2034 # BOARD_GH_ARGV is read by the sourcing scripts.
fm_board_gh_argv() {
  local lib_dir
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  BOARD_GH_ARGV=(env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
    "$lib_dir/fm-gh-account.sh" exec --account "$BOARD_ACCOUNT" -- gh)
}
