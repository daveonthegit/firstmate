#!/usr/bin/env bash
# Behavior tests for the agent board watcher (bin/fm-procevent-board.sh) and the
# board posting helper (bin/fm-board-post.sh).
#
# Every scenario runs the scripts through their public commands and the generic
# process-event runner against a FAKE gh on PATH that serves an issue and its
# comments with GitHub's `since` and page semantics and records every call with
# the token it carried. The real gh is never invoked. The suite proves: the
# config file is the opt-in and its defaults, overrides, floor, and refusals
# hold; `ensure` arms only a configured home and is idempotent; the board is
# baselined without replaying history; this firstmate's own posts advance the
# cursor silently; a comment by anyone else produces one announced, acknowledged
# result carrying its author, tag, URL, timestamp, and text; same-second comments
# are deduplicated; an edited comment resurfaces marked edited; a deleted comment
# never breaks the cursor; results are bounded; an unreadable cursor is
# re-baselined and reported; an API failure is one diagnostic with quiet retries
# and one recovery notice; every call runs as the configured account; and the
# posting helper prefixes the tag exactly once and makes no other write.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-board-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_BOARD_TEST_SLEEP=0.2
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

HOMES=()
board_teardown() {
  local home
  for home in ${HOMES[@]+"${HOMES[@]}"}; do
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap board_teardown EXIT

# The fake gh: two logged-in accounts with per-account tokens, the board issue
# and its comments from fixture files, GitHub's inclusive `since` filter and
# 100-per-page paging, and a POST that records the request document.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'PERL'
#!/usr/bin/perl
use strict; use warnings; use JSON::PP;
my $dir = $ENV{FAKE_GH_DIR} or die "FAKE_GH_DIR unset\n";
sub slurp { my $f = shift; open my $h, "<", $f or return undef; local $/; my $s = <$h>; close $h; $s }
sub flag { -e "$dir/$_[0]" }
my @argv = @ARGV;
if ($argv[0] eq "auth" && $argv[1] eq "status") {
  print "github.com\n  Logged in to github.com account davidx-secco (keyring)\n  Logged in to github.com account other-acct (keyring)\n";
  exit 0;
}
if ($argv[0] eq "auth" && $argv[1] eq "token") {
  my ($user) = map { $argv[$_ + 1] } grep { $argv[$_] eq "--user" } 0 .. $#argv;
  exit 1 unless defined $user && ($user eq "davidx-secco" || $user eq "other-acct");
  print "gho_token_for_$user\n"; exit 0;
}
die "unsupported fake gh call: @argv\n" unless $argv[0] eq "api";
my ($method, $path, $input) = ("GET");
for (my $i = 1; $i < @argv; $i++) {
  if ($argv[$i] eq "-X") { $method = $argv[++$i] }
  elsif ($argv[$i] eq "--input") { $input = $argv[++$i] }
  elsif ($argv[$i] =~ /^-/) { die "unsupported fake gh flag $argv[$i]\n" }
  else { $path = $argv[$i] }
}
open my $log, ">>", "$dir/calls.log"; print $log "$method $path token=" . ($ENV{GH_TOKEN} // "none") . "\n"; close $log;
if (flag("api.fail")) { print STDERR slurp("$dir/api.fail"); exit 1 }
my $board = slurp("$dir/board") // "BG-Media-LLC/agent-board/1"; chomp $board;
my ($repo, $issue) = $board =~ m{^(.+)/(\d+)$};
if ($method eq "POST") {
  die "gh: Not Found (HTTP 404)\n" unless $path eq "repos/$repo/issues/$issue/comments";
  my $doc = decode_json(slurp($input));
  open my $p, ">>", "$dir/posts.log"; print $p encode_json($doc), "\n"; close $p;
  print encode_json({ id => 999, html_url => "https://github.com/$repo/issues/$issue#issuecomment-999" }); exit 0;
}
if ($path eq "repos/$repo/issues/$issue") { print slurp("$dir/issue.json"); exit 0 }
if ($path =~ m{^repos/\Q$repo\E/issues/\Q$issue\E/comments\?since=([^&]+)&per_page=(\d+)&page=(\d+)$}) {
  my ($since, $per, $page) = ($1, $2, $3);
  my $all = decode_json(slurp("$dir/comments.json") // "[]");
  my @m = grep { $_->{updated_at} ge $since } @$all;
  my @p = grep { defined } @m[($page - 1) * $per .. $page * $per - 1];
  print encode_json(\@p); exit 0;
}
print STDERR "gh: Not Found (HTTP 404)\n"; exit 1;
PERL
chmod +x "$FAKEBIN/gh"

new_home() {  # <name> -> sets H and D (the fake gh fixture dir); writes a default config
  H="$TMP_ROOT/$1"
  D="$H/fake"
  mkdir -p "$H/state" "$H/config" "$D"
  : > "$D/calls.log"
  printf '{"number":1,"updated_at":"2026-11-01T10:00:00Z"}\n' > "$D/issue.json"
  printf '[%s]\n' "$(comment 100 itamarseg 2026-11-01T10:00:00Z 2026-11-01T10:00:00Z '[Front Desk] OLD-HISTORY')" > "$D/comments.json"
  printf '# board\n' > "$H/config/agent-board"
  HOMES+=("$H")
}

# comment <id> <login> <created> <updated> <body>
comment() {
  perl -MJSON::PP -e 'print JSON::PP->new->canonical->encode({ id => $ARGV[0] + 0, user => { login => $ARGV[1] }, created_at => $ARGV[2], updated_at => $ARGV[3], html_url => "https://github.com/BG-Media-LLC/agent-board/issues/1#issuecomment-$ARGV[0]", body => $ARGV[4] })' "$@"
}
set_comments() { local IFS=,; printf '[%s]\n' "$*" > "$D/comments.json"; }

bd() { FM_HOME="$H" FAKE_GH_DIR="$D" PATH="$FAKEBIN:$BASE_PATH" "$ROOT/bin/fm-procevent-board.sh" "$@"; }
post() { FM_HOME="$H" FAKE_GH_DIR="$D" PATH="$FAKEBIN:$BASE_PATH" "$ROOT/bin/fm-board-post.sh" "$@"; }
pe() { FM_HOME="$H" FAKE_GH_DIR="$D" PATH="$FAKEBIN:$BASE_PATH" "$ROOT/bin/fm-procevent.sh" "$@"; }

RUNNER_PID=
start_runner() {
  FM_HOME="$H" FAKE_GH_DIR="$D" PATH="$FAKEBIN:$BASE_PATH" \
    "$ROOT/bin/fm-procevent.sh" start agent-board > "$H/runner.out" 2>&1 &
  RUNNER_PID=$!
}
wait_runner() {
  for _ in $(seq 1 150); do
    kill -0 "$RUNNER_PID" 2>/dev/null || { wait "$RUNNER_PID" 2>/dev/null; return 0; }
    sleep 0.1
  done
  return 1
}
stop_runner() { pe retire agent-board >/dev/null 2>&1 || true; wait "$RUNNER_PID" 2>/dev/null || true; }

results() {
  local f seq
  for f in "$H/state/procevent-inbox"/agent-board.*.result; do
    [ -e "$f" ] || continue
    seq=${f%.result}; seq=${seq##*.}
    printf '%s\t%s\n' "$seq" "$f"
  done | sort -n | cut -f2-
}
result_count() { results | grep -c . || true; }
last_result() { results | tail -1; }
cursor() { head -1 "$H/state/agent-board-watch/cursor" 2>/dev/null; }
wait_cursor() {  # <ts> <seen>
  for _ in $(seq 1 150); do
    [ "$(cursor)" = "$1"$'\t'"$2" ] && return 0
    sleep 0.1
  done
  return 1
}
comment_polls() { grep -c '^GET repos/BG-Media-LLC/agent-board/issues/1/comments' "$D/calls.log" || true; }
wait_polls() {  # <at-least>
  for _ in $(seq 1 150); do
    [ "$(comment_polls)" -ge "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

# --- configuration: opt-in, defaults, overrides, floor, refusals -------------
new_home cfg
rm -f "$H/config/agent-board"
out=$(bd config)
assert_contains "$out" "configured=no" "with no config/agent-board the board is not opted in"
if bd arm >/dev/null 2>"$TMP_ROOT/cfg.err"; then fail "arm must refuse without config/agent-board"; fi
assert_grep "config/agent-board is absent" "$TMP_ROOT/cfg.err" "the arm refusal names the missing opt-in"
out=$(bd ensure)
[ -z "$out" ] || fail "ensure is silent on an unconfigured home: $out"
assert_absent "$H/state/procevent/agent-board.source" "ensure never arms an unconfigured home"
printf '# opt in\n' > "$H/config/agent-board"
out=$(bd config)
assert_contains "$out" "repo=BG-Media-LLC/agent-board" "the default board repository"
assert_contains "$out" "issue=1" "the default board issue"
assert_contains "$out" "interval=120" "the default interval is two minutes"
assert_contains "$out" "account=davidx-secco" "the default account"
assert_contains "$out" "self_tag=[David's Firstmate]" "the default self tag"
printf 'repo=acme/board\nissue=7\ninterval=30\naccount=other-acct\nself_tag=[Ops Bot]\n' > "$H/config/agent-board"
out=$(bd config)
assert_contains "$out" "repo=acme/board" "repo is configurable"
assert_contains "$out" "issue=7" "issue is configurable"
assert_contains "$out" "interval=60 (floor applied; configured 30)" "an interval below the floor is raised to 60"
assert_contains "$out" "account=other-acct" "account is configurable"
assert_contains "$out" "self_tag=[Ops Bot]" "self_tag is configurable"
for bad in 'interval=soon' 'repo=not a repo' 'issue=0' 'account=-x' 'self_tag=no brackets' 'colour=blue' 'novalue'; do
  printf '%s\n' "$bad" > "$H/config/agent-board"
  if bd config >/dev/null 2>&1; then fail "an invalid config line must be refused: $bad"; fi
  if bd arm >/dev/null 2>&1; then fail "arm must refuse an invalid config: $bad"; fi
done
pass "config/agent-board is the opt-in, with defaults, overrides, a 60s floor, and refusals"

# --- ensure: arms a configured home once, idempotently -------------------------
new_home ensure
out=$(bd ensure)
assert_contains "$out" "armed: agent-board board=BG-Media-LLC/agent-board#1 interval=120" "ensure arms a configured home"
assert_present "$H/state/procevent/agent-board.source" "ensure registers the source"
assert_grep "adapter=board" "$H/state/procevent/agent-board.source" "the source is registered under the board adapter"
before=$(cat "$H/state/procevent/agent-board.source")
out=$(bd ensure)
[ -z "$out" ] || fail "a second ensure is silent: $out"
[ "$(cat "$H/state/procevent/agent-board.source")" = "$before" ] || fail "a second ensure leaves the registration alone"
bd retire >/dev/null
pass "ensure arms only a configured home and is idempotent"

# --- baseline, self posts, then a post by someone else -----------------------
new_home msg
bd arm >/dev/null
start_runner
wait_cursor 2026-11-01T10:00:00Z 100 || fail "the board is baselined at its current state: $(cursor)"
wait_polls 3 || fail "an idle board keeps being polled"
[ "$(result_count)" -eq 0 ] || fail "an idle board produces no result"
kill -0 "$RUNNER_PID" 2>/dev/null || fail "the source keeps polling while nothing is new"
set_comments "$(comment 100 itamarseg 2026-11-01T10:00:00Z 2026-11-01T10:00:00Z '[Front Desk] OLD-HISTORY')" \
  "$(comment 101 davidx-secco 2026-11-01T10:05:00Z 2026-11-01T10:05:00Z "  [David's Firstmate] OWN-POST")"
wait_cursor 2026-11-01T10:05:00Z 101 || fail "this firstmate's own post advances the cursor"
[ "$(result_count)" -eq 0 ] || fail "this firstmate's own post produces no result"
kill -0 "$RUNNER_PID" 2>/dev/null || fail "the source keeps polling after its own post"
set_comments "$(comment 100 itamarseg 2026-11-01T10:00:00Z 2026-11-01T10:00:00Z '[Front Desk] OLD-HISTORY')" \
  "$(comment 101 davidx-secco 2026-11-01T10:05:00Z 2026-11-01T10:05:00Z "[David's Firstmate] OWN-POST")" \
  "$(comment 102 reagan-bot 2026-11-01T10:09:00Z 2026-11-01T10:09:00Z $'[Reagan Pages] please review PR 16\nsecond line')"
wait_runner || fail "the source completes once someone else posts"
R=$(last_result)
[ "$(result_count)" -eq 1 ] || fail "one new comment produces exactly one result"
[ "$(bd classify "$R")" = messages ] || fail "the result classifies as messages"
assert_grep "messages=1" "$R" "the result counts the shown comment"
assert_grep "board=BG-Media-LLC/agent-board#1" "$R" "the result names the board"
assert_grep "### [Reagan Pages] - @reagan-bot - 2026-11-01T10:09:00Z" "$R" "the result carries the poster tag, author, and timestamp"
assert_grep "https://github.com/BG-Media-LLC/agent-board/issues/1#issuecomment-102" "$R" "the result carries the comment URL"
assert_grep "please review PR 16" "$R" "the result carries the comment text"
assert_grep "second line" "$R" "multi-line text is kept"
assert_no_grep "OLD-HISTORY" "$R" "history before the baseline is never replayed"
assert_no_grep "OWN-POST" "$R" "this firstmate's own post is never surfaced"
[ "$(cursor)" = $'2026-11-01T10:09:00Z\t102' ] || fail "autohandle commits the new cursor: $(cursor)"
assert_present "$H/state/procevent-inbox/agent-board.$(basename "$R" | cut -d. -f2).handled" "autohandle acknowledges the result"
assert_grep "procevent:agent-board:" "$H/state/.wake-queue" "the result is announced on the durable wake queue"
if grep -v -E '^GET repos/BG-Media-LLC/agent-board/issues/1(/comments\?since=[0-9TZ:-]+&per_page=100&page=[0-9]+)? token=gho_token_for_davidx-secco$' "$D/calls.log" | grep -q .; then
  fail "the watcher made a call outside the read-only set or as another account: $(cat "$D/calls.log")"
fi
pass "a post by someone else produces one acknowledged result; own posts and history stay silent"

# --- same-second dedup, edits, deletions --------------------------------------
: > "$D/calls.log"
start_runner
wait_polls 2 || fail "the restarted source polls"
[ "$(result_count)" -eq 1 ] || fail "a restart does not redeliver an acknowledged comment"
assert_grep "since=2026-11-01T10:09:00Z" "$D/calls.log" "the restarted source continues from the committed cursor"
set_comments "$(comment 102 reagan-bot 2026-11-01T10:09:00Z 2026-11-01T10:09:00Z '[Reagan Pages] please review PR 16')" \
  "$(comment 103 itamarseg 2026-11-01T10:09:00Z 2026-11-01T10:09:00Z '[Front Desk] SAME-SECOND')"
wait_runner || fail "a same-second comment completes the source"
R=$(last_result)
assert_grep "SAME-SECOND" "$R" "a new comment in the cursor's own second is delivered"
assert_no_grep "please review PR 16" "$R" "an already-seen comment in that second is not repeated"
[ "$(cursor)" = $'2026-11-01T10:09:00Z\t102,103' ] || fail "both same-second ids are remembered: $(cursor)"
start_runner
wait_polls 2 || fail "the source polls after the same-second round"
set_comments "$(comment 102 reagan-bot 2026-11-01T10:09:00Z 2026-11-01T10:20:00Z '[Reagan Pages] EDITED-TEXT')" \
  "$(comment 103 itamarseg 2026-11-01T10:09:00Z 2026-11-01T10:09:00Z '[Front Desk] SAME-SECOND')"
wait_runner || fail "an edit completes the source"
R=$(last_result)
assert_grep "EDITED-TEXT" "$R" "an edited comment is delivered again"
assert_grep "(edited 2026-11-01T10:20:00Z)" "$R" "the edit is marked"
assert_grep "edited=1" "$R" "the header counts the edit"
start_runner
wait_polls 2 || fail "the source polls after the edit round"
# Every earlier comment is deleted; the cursor is a timestamp, so it holds.
set_comments "$(comment 110 itamarseg 2026-11-01T11:00:00Z 2026-11-01T11:00:00Z '[Front Desk] AFTER-DELETE')"
wait_runner || fail "a comment after deletions completes the source"
R=$(last_result)
[ "$(bd classify "$R")" = messages ] || fail "deletions do not break polling"
assert_grep "AFTER-DELETE" "$R" "the next comment after deletions is delivered"
assert_no_grep "EDITED-TEXT" "$R" "deleted comments are not resurfaced"
pass "same-second comments are deduplicated, edits resurface marked, and deletions never break the cursor"

# --- bounded results ------------------------------------------------------------
new_home bound
bd arm >/dev/null
FM_BOARD_MAX_MESSAGES=2 FM_BOARD_MAX_MESSAGE_BYTES=300 start_runner
wait_cursor 2026-11-01T10:00:00Z 100 || fail "baseline"
long=$(printf 'L%.0s' $(seq 1 900))
set_comments "$(comment 201 a 2026-11-01T12:00:01Z 2026-11-01T12:00:01Z '[A] FIRST')" \
  "$(comment 202 b 2026-11-01T12:00:02Z 2026-11-01T12:00:02Z '[B] SECOND')" \
  "$(comment 203 c 2026-11-01T12:00:03Z 2026-11-01T12:00:03Z "[C] $long")"
wait_runner || fail "the bounded source completes"
R=$(last_result)
assert_grep "messages=2" "$R" "at most the configured number of comments is shown"
assert_grep "omitted=1" "$R" "omitted comments are counted"
assert_no_grep "FIRST" "$R" "the oldest comments are the ones omitted"
assert_grep "SECOND" "$R" "the newer comments are kept"
assert_grep "truncated; 904 bytes in full" "$R" "an oversized comment is truncated"
[ "$(wc -c < "$R")" -lt 2000 ] || fail "the bounded result stays small"
[ "$(cursor)" = $'2026-11-01T12:00:03Z\t203' ] || fail "the cursor advances past omitted comments"
pass "results are bounded in count and per-comment size"

# --- unreadable cursor: re-baseline and report once ----------------------------
new_home gap
mkdir -p "$H/state/agent-board-watch"
printf 'garbage\n' > "$H/state/agent-board-watch/cursor"
bd arm >/dev/null
start_runner
wait_runner || fail "an unreadable cursor completes the source"
R=$(last_result)
[ "$(bd classify "$R")" = messages ] || fail "a re-baseline is reported"
assert_grep "gaps=1" "$R" "the result counts the gap"
assert_grep "re-baselined" "$R" "the result says the board was re-baselined"
assert_no_grep "OLD-HISTORY" "$R" "a re-baseline never replays history"
[ "$(cursor)" = $'2026-11-01T10:00:00Z\t100' ] || fail "the cursor is rebased: $(cursor)"
pass "an unreadable cursor is re-baselined without replay and reported once"

# --- API failure: one diagnostic, quiet backoff, one recovery -------------------
new_home diag
bd arm >/dev/null
start_runner
wait_cursor 2026-11-01T10:00:00Z 100 || fail "baseline"
printf 'gh: Not Found (HTTP 404) Authorization: token gho_SECRETSECRETSECRET\n' > "$D/api.fail"
wait_runner || fail "an API failure completes the source with a diagnostic"
R=$(last_result)
[ "$(bd classify "$R")" = diagnostic ] || fail "an API failure classifies as diagnostic"
assert_grep "diagnostic=not-found" "$R" "a 404 is reported as not-found"
assert_no_grep "gho_SECRET" "$R" "a credential never reaches the result"
assert_grep "not-found" "$H/state/agent-board-watch/diagnostic" "autohandle records the reported diagnostic"
: > "$D/calls.log"
start_runner
for _ in $(seq 1 30); do sleep 0.1; done
[ "$(result_count)" -eq 1 ] || fail "a repeating failure is not re-announced"
kill -0 "$RUNNER_PID" 2>/dev/null || fail "the source keeps retrying quietly"
calls=$(grep -c . "$D/calls.log" || true)
[ "$calls" -le 8 ] || fail "retries back off rather than looping tightly: $calls calls in 3s"
[ "$calls" -ge 1 ] || fail "the source keeps retrying"
rm -f "$D/api.fail"
wait_runner || fail "recovery completes the source"
R=$(last_result)
[ "$(bd classify "$R")" = recovered ] || fail "recovery is reported once"
assert_grep "recovered_from=not-found" "$R" "the recovery names what cleared"
assert_absent "$H/state/agent-board-watch/diagnostic" "autohandle clears the recorded diagnostic"
start_runner
wait_polls 2 || fail "the source polls after recovery"
[ "$(result_count)" -eq 2 ] || fail "a healthy board after recovery stays silent"
stop_runner
pass "an API failure is one redacted diagnostic, retried quietly with backoff, then one recovery"

# --- unavailable account --------------------------------------------------------
new_home acct
printf 'account=nobody-here\n' > "$H/config/agent-board"
bd arm >/dev/null
start_runner
wait_runner || fail "an unavailable account completes the source"
R=$(last_result)
assert_grep "diagnostic=account-unavailable" "$R" "an account that is not logged in is diagnosed"
if grep -q 'token=' "$D/calls.log"; then fail "no API call is made without the configured account"; fi
pass "an unavailable account is diagnosed and no call falls back to another account"

# --- the posting helper ---------------------------------------------------------
new_home post
rm -f "$H/config/agent-board"
if printf 'hi\n' | post - >/dev/null 2>"$TMP_ROOT/post.err"; then fail "posting refuses without config/agent-board"; fi
assert_grep "config/agent-board is absent" "$TMP_ROOT/post.err" "the refusal names the missing opt-in"
printf '# opt in\n' > "$H/config/agent-board"
url=$(printf 'Reviewed PR 16: looks good.\n' | post -) || fail "posting from stdin succeeds"
[ "$url" = "https://github.com/BG-Media-LLC/agent-board/issues/1#issuecomment-999" ] || fail "the helper prints the new comment URL: $url"
printf "[David's Firstmate] already tagged\n" > "$TMP_ROOT/body.txt"
post --file "$TMP_ROOT/body.txt" >/dev/null || fail "posting from a file succeeds"
printf 'caf\xc3\xa9 \xe2\x9c\x93\n' | post - >/dev/null || fail "UTF-8 text posts"
expected=$(cat <<'EOF'
{"body":"[David's Firstmate] Reviewed PR 16: looks good."}
{"body":"[David's Firstmate] already tagged"}
{"body":"[David's Firstmate] café ✓"}
EOF
)
[ "$(cat "$D/posts.log")" = "$expected" ] || fail "the posted bodies carry the tag exactly once: $(cat "$D/posts.log")"
[ "$(grep -c . "$D/calls.log")" -eq 3 ] || fail "each post is exactly one call"
if grep -v -E '^POST repos/BG-Media-LLC/agent-board/issues/1/comments token=gho_token_for_davidx-secco$' "$D/calls.log" | grep -q .; then
  fail "the helper made a call other than one comment POST as the configured account: $(cat "$D/calls.log")"
fi
if printf '  \n\n' | post - >/dev/null 2>"$TMP_ROOT/post.err"; then fail "an empty body is refused"; fi
assert_grep "the body is empty" "$TMP_ROOT/post.err" "the empty-body refusal is named"
if head -c 70000 /dev/zero | tr '\0' x | post - >/dev/null 2>"$TMP_ROOT/post.err"; then fail "an oversized body is refused"; fi
assert_grep "comment limit" "$TMP_ROOT/post.err" "the size refusal is named"
printf 'gh: Server Error (HTTP 502)\n' > "$D/api.fail"
if printf 'hi\n' | post - >/dev/null 2>"$TMP_ROOT/post.err"; then fail "a failed post exits nonzero"; fi
assert_grep "failed" "$TMP_ROOT/post.err" "a failed post is reported"
[ "$(grep -c . "$D/posts.log")" -eq 3 ] || fail "refused posts write nothing"
pass "the posting helper prefixes the tag once, posts as the configured account, and refuses bad input"
