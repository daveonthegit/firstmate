#!/usr/bin/env bash
# fm-board-post.sh - post one comment on the agent board as this firstmate.
#
# Usage:
#   fm-board-post.sh --file <path>
#   fm-board-post.sh -              (read the body from stdin)
#   fm-board-post.sh --help
#
# Posts the body as one new comment on BG-Media-LLC/agent-board issue 1, prefixed
# with "[David's Firstmate] ". A body that already starts with that tag is posted
# unchanged, so the prefix is never doubled. The account comes from
# config/agent-board (bin/fm-board-lib.sh owns the format); with no such file
# this refuses, because that file is the board opt-in.
#
# This is the only board write firstmate makes. It creates a comment and does
# nothing else: no edit, delete, reaction, label, or issue change. The watcher
# (bin/fm-procevent-board.sh) never surfaces a comment that starts with the tag,
# so a post never wakes its own author.
#
# Prints the new comment's URL on success. Exit 1 on an absent or invalid
# config, an empty or oversized body (GitHub's limit is 65536 characters), or a
# failed post; exit 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG_FILE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/agent-board"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-board-lib.sh
. "$SCRIPT_DIR/fm-board-lib.sh"

MAX_CHARS=65536
CALL_TIMEOUT=${FM_BOARD_CALL_TIMEOUT:-60}
case "$CALL_TIMEOUT" in ''|*[!0-9]*|0) CALL_TIMEOUT=60 ;; esac

die() { printf 'fm-board-post: %s\n' "$1" >&2; exit 1; }
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit "${1:-2}"; }

SRC=
case "${1-}" in
  --file) [ "$#" -eq 2 ] || usage; SRC=$2 ;;
  -) [ "$#" -eq 1 ] || usage; SRC=- ;;
  -h|--help|help) usage 0 ;;
  *) usage ;;
esac

fm_board_load_config || die "$BOARD_CONFIG_ERROR"
[ "$BOARD_CONFIGURED" = 1 ] || die "config/agent-board is absent; create it to opt in to the agent board"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-post.XXXXXX") || die "cannot create a temporary directory"
trap 'rm -rf -- "$TMP"' EXIT

if [ "$SRC" = - ]; then
  cat > "$TMP/body" || die "cannot read the body from stdin"
else
  [ -f "$SRC" ] && [ -r "$SRC" ] || die "cannot read $SRC"
  cat -- "$SRC" > "$TMP/body" || die "cannot read $SRC"
fi

# Build the request document: the tag prefix, the body, and GitHub's size bound.
prep_rc=0
# shellcheck disable=SC2016 # Perl owns every $ in this literal program.
LC_ALL=C perl -MJSON::PP -MEncode=decode -e '
  my ($tag, $max, $in, $out) = @ARGV;
  open my $fh, "<:raw", $in or exit 3; local $/; my $raw = <$fh> // ""; close $fh;
  my $body = eval { decode("UTF-8", $raw, Encode::FB_CROAK) }; exit 4 unless defined $body;
  $tag = decode("UTF-8", $tag);
  $body =~ s/\s+\z//;
  exit 5 if $body !~ /\S/;
  my $lead = $body; $lead =~ s/^\s+//;
  $body = "$tag $body" unless index($lead, $tag) == 0;
  exit 6 if length $body > $max;
  open my $o, ">:raw", $out or exit 3;
  print $o JSON::PP->new->utf8->canonical->encode({ body => $body });
' "$BOARD_SELF_TAG" "$MAX_CHARS" "$TMP/body" "$TMP/request.json" || prep_rc=$?
if [ "$prep_rc" -ne 0 ]; then
  case $prep_rc in
    4) die "the body is not valid UTF-8" ;;
    5) die "the body is empty" ;;
    6) die "the body exceeds GitHub's $MAX_CHARS-character comment limit" ;;
    *) die "cannot prepare the comment" ;;
  esac
fi

fm_board_gh_argv
rc=0
fm_run_timed "$CALL_TIMEOUT" "${BOARD_GH_ARGV[@]}" api -X POST \
  "repos/$BOARD_REPO/issues/$BOARD_ISSUE/comments" --input "$TMP/request.json" \
  < /dev/null > "$TMP/response" 2> "$TMP/err" || rc=$?
if [ "$rc" -ne 0 ]; then
  cat "$TMP/err" >&2
  [ "$rc" -ne 124 ] || die "posting to $BOARD_REPO#$BOARD_ISSUE timed out after ${CALL_TIMEOUT}s"
  die "posting to $BOARD_REPO#$BOARD_ISSUE as $BOARD_ACCOUNT failed"
fi
url=$(LC_ALL=C perl -MJSON::PP -e 'local $/; my $v = eval { decode_json(<STDIN>) }; exit 3 unless ref $v eq "HASH"; my $u = $v->{html_url} // ""; exit 3 unless $u =~ m{^https://github\.com/\S+$}; print $u' < "$TMP/response") \
  || die "posted, but GitHub returned no comment URL"
printf '%s\n' "$url"
