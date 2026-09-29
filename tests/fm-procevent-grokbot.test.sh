#!/usr/bin/env bash
# Behavior tests for the Grok Bot reply adapter of the process-to-event runner
# (bin/fm-procevent-grokbot.sh).
#
# Every scenario runs the adapter through its public commands and the generic
# runner against a FAKE gbot on PATH that reproduces the published thread-delta
# contract (cursor, entryCount, gapReset over a bounded tail). The real gbot is
# never invoked. The suite proves: a new bot message produces one captured,
# announced result and advances the cursor; the captain's own sends are never
# surfaced; a gap reset re-baselines without replaying history; an idle thread
# keeps polling quietly; a missing or unauthenticated gbot yields exactly one
# diagnostic and a later recovery notice; the interval floor holds; the
# read-only allowlist refuses every mutating command; and a restart or re-arm
# continues from the saved cursors. It also proves one failing bot never blocks
# another bot's delivery and is named only once, an unrecognised baseline never
# saves an empty cursor, invalid tuning falls back to the defaults, and a mixed
# gap and messages round still carries its gap count.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v node >/dev/null 2>&1; then
  printf 'skip: node not found (the fake gbot and the adapter parser need it)\n'
  exit 0
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-grokbot-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_GROKBOT_TEST_SLEEP=0.2
# node is linked in alone: its install directory usually also holds the real
# gbot, which this suite must never be able to reach.
mkdir -p "$TMP_ROOT/nodebin"
ln -s "$(command -v node)" "$TMP_ROOT/nodebin/node"
BASE_PATH="$TMP_ROOT/nodebin:/usr/bin:/bin:/usr/sbin:/sbin"
if PATH="$BASE_PATH" command -v gbot >/dev/null 2>&1; then
  printf 'skip: a real gbot is reachable on the base PATH (%s); refusing to risk calling it\n' "$(PATH="$BASE_PATH" command -v gbot)"
  exit 0
fi

HOMES=()
grokbot_teardown() {
  local home
  for home in ${HOMES[@]+"${HOMES[@]}"}; do
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap grokbot_teardown EXIT

# The fake gbot: records every argv, serves thread-<ref>.json fixtures through
# the same bounded-tail delta rules the real CLI applies, and answers without
# --gateway from a local "files" roster so a fallback would be visible.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN" "$TMP_ROOT/nogbot"
cat > "$FAKEBIN/gbot" <<'JS'
#!/usr/bin/env node
const fs = require("fs"), path = require("path");
const dir = process.env.FAKE_GBOT_DIR;
const argv = process.argv.slice(2);
fs.appendFileSync(path.join(dir, "calls.log"), argv.join(" ") + "\n");
const flag = (n) => fs.existsSync(path.join(dir, n));
const opt = (n) => { const i = argv.indexOf(n); return i === -1 ? undefined : argv[i + 1]; };
const fail = (m) => { process.stderr.write(m + "\n"); process.exit(1); };
const print = (v) => { process.stdout.write(JSON.stringify(v) + "\n"); process.exit(0); };
if (!argv.includes("--gateway")) print([{ id: "local-files", name: "LocalFiles", kind: "bot" }]);
if (flag("gateway.fail")) fail("Gateway error 502 (Authorization: Bearer sk-live-SECRET)");
const cmd = argv[0];
if (cmd === "doctor") {
  const usable = !flag("doctor.unusable");
  print({ resolved: null, found: [], candidates: [], gatewayAuthPresent: usable,
    grokBotAppSession: usable ? { present: true, usable: true } : { present: true, usable: false, error: "decrypt failed", code: "KEYCHAIN_DENIED" },
    note: "" });
}
if (cmd === "bots" && argv[1] === "list") print(JSON.parse(fs.readFileSync(path.join(dir, "bots.json"), "utf8")));
if (cmd === "thread") {
  const ref = argv[1];
  if (flag("thread-" + ref + ".fail")) fail("Gateway error 404: unknown bot " + ref);
  if (flag("thread-" + ref + ".bad")) print({ unexpected: true });
  const file = path.join(dir, "thread-" + ref + ".json");
  const all = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : [];
  const limit = Math.min(Math.max(parseInt(opt("--limit") || "40", 10), 1), 200);
  const page = all.slice(-limit);
  const target = { id: ref, name: "Name-" + ref, isGroup: false };
  const last = (es, fb = "") => { for (let i = es.length - 1; i >= 0; i--) if (es[i].id) return es[i].id; return fb; };
  const after = opt("--after");
  if (after === undefined) print({ target, transcript: { entries: page } });
  const i = page.findIndex((e) => e.id === after);
  if (i === -1) print({ target, transcript: { entries: page }, cursor: last(page), entryCount: page.length, gapReset: true });
  const entries = page.slice(i + 1);
  print({ target, transcript: { entries }, cursor: last(entries, after), entryCount: entries.length, gapReset: false });
}
fail("unsupported fake gbot command: " + argv.join(" "));
JS
chmod +x "$FAKEBIN/gbot"

new_home() {  # <name> -> sets H and D (the fake gbot's fixture dir)
  H="$TMP_ROOT/$1"
  D="$H/fake"
  mkdir -p "$H/state" "$H/config" "$D"
  : > "$D/calls.log"
  printf '[{"id":"bot-a","name":"Alpha","kind":"bot"}]\n' > "$D/bots.json"
  printf '[]\n' > "$D/thread-bot-a.json"
  HOMES+=("$H")
}

gb() { FM_HOME="$H" FAKE_GBOT_DIR="$D" PATH="$FAKEBIN:$BASE_PATH" "$ROOT/bin/fm-procevent-grokbot.sh" "$@"; }
pe() { FM_HOME="$H" FAKE_GBOT_DIR="$D" PATH="$FAKEBIN:$BASE_PATH" "$ROOT/bin/fm-procevent.sh" "$@"; }

# Start the runner for the grokbot source in the background, the way reconcile
# would, with an explicit PATH so gbot presence is under test control.
RUNNER_PID=
start_runner() {  # [path]
  FM_HOME="$H" FAKE_GBOT_DIR="$D" PATH="${1:-$FAKEBIN:$BASE_PATH}" \
    "$ROOT/bin/fm-procevent.sh" start grokbot > "$H/runner.out" 2>&1 &
  RUNNER_PID=$!
}

wait_runner() {  # <tries>
  local n=${1:-150}
  for _ in $(seq 1 "$n"); do
    kill -0 "$RUNNER_PID" 2>/dev/null || { wait "$RUNNER_PID" 2>/dev/null; return 0; }
    sleep 0.1
  done
  return 1
}

stop_runner() { pe retire grokbot >/dev/null 2>&1 || true; wait "$RUNNER_PID" 2>/dev/null || true; }

results() {
  local inbox="$H/state/procevent-inbox" f seq
  for f in "$inbox"/grokbot.*.result; do
    [ -e "$f" ] || continue
    seq=${f%.result}; seq=${seq##*.}
    printf '%s\t%s\n' "$seq" "$f"
  done | sort -n | cut -f2-
}
result_count() { results | grep -c . || true; }
last_result() { results | tail -1; }

thread_polls() { grep -c '^thread bot-a --after' "$D/calls.log" || true; }
cursor_of() { awk -F '\t' -v r="$1" '$1 == r { print $2 }' "$H/state/grokbot-watch/cursors.tsv" 2>/dev/null; }

wait_cursor() {  # <ref> <value>
  for _ in $(seq 1 150); do
    [ "$(cursor_of "$1")" = "$2" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_polls() {  # <at-least>
  for _ in $(seq 1 150); do
    [ "$(thread_polls)" -ge "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

bot_msg()  { printf '{"id":"%s","kind":"send-message","role":"assistant","message":"%s","timestamp":"2026-09-29T12:00:0%sZ"}' "$1" "$2" "${3:-0}"; }
user_msg() { printf '{"id":"%s","kind":"user-message","role":"user","clientNonce":"n-%s","prompt":"%s"}' "$1" "$1" "$2"; }

# --- configuration: default, override, floor, invalid -----------------------
new_home cfg
out=$(gb config)
assert_contains "$out" "interval=1800" "the default interval is 30 minutes"
assert_contains "$out" "bots=all" "with no config every listed bot is watched"
printf 'interval=600\nbot=Alpha\nbot=bot-b\n' > "$H/config/grokbot-watch"
out=$(gb config)
assert_contains "$out" "interval=600" "config/grokbot-watch overrides the interval"
assert_contains "$out" "bot=Alpha" "config/grokbot-watch names the watched bots"
assert_contains "$out" "bot=bot-b" "every bot= line is watched"
printf 'interval=30\n' > "$H/config/grokbot-watch"
out=$(gb config)
assert_contains "$out" "interval=120 (floor applied; configured 30)" "an interval below the floor is raised to 120"
out=$(gb arm)
assert_contains "$out" "armed: grokbot interval=120" "arm applies the floor"
assert_present "$H/state/procevent/grokbot.source" "arm registers the source"
assert_grep "--gbot" "$H/state/procevent/grokbot.source" "arm records the resolved gbot path"
gb retire >/dev/null
printf 'interval=soon\n' > "$H/config/grokbot-watch"
if gb config 2>"$TMP_ROOT/cfg.err"; then fail "an invalid interval must be refused"; fi
assert_grep "interval must be whole seconds" "$TMP_ROOT/cfg.err" "the refusal names the bad setting"
pass "config defaults to 1800s, honours overrides, and enforces the 120s floor"

# --- read-only allowlist ----------------------------------------------------
new_home allow
gb check-argv doctor --json --gateway >/dev/null || fail "doctor must be allowed"
gb check-argv bots list --json --gateway >/dev/null || fail "bots list must be allowed"
gb check-argv thread Alpha --after e1 --limit 200 --json --gateway --no-history >/dev/null \
  || fail "a bounded thread read must be allowed"
for forbidden in \
  "send Alpha hello --json --gateway" \
  "send --reply-mode auto Alpha hi --json --gateway" \
  "bots create Beta --json --gateway" \
  "bots update Alpha --json --gateway" \
  "bots delete Alpha --json --gateway" \
  "groups list --json --gateway" \
  "skills add ./x --json --gateway" \
  "skills remove x --json --gateway" \
  "approvals respond Alpha e1 r1 accept --json --gateway" \
  "codex send t hi --json --gateway" \
  "chatgpt-desktop send hi --json --gateway" \
  "claude send hi --json --gateway" \
  "thread Alpha --json" \
  "thread Alpha --gateway" \
  "thread Alpha --files --json --gateway" \
  "thread --after e1 --json --gateway" \
  "thread Alpha --reply-mode auto --json --gateway" \
  "doctor --json --gateway --files"; do
  # shellcheck disable=SC2086 # each case is deliberately word-split into argv
  if gb check-argv $forbidden >"$TMP_ROOT/allow.out"; then
    fail "the allowlist must refuse: gbot $forbidden"
  fi
  assert_grep "refused:" "$TMP_ROOT/allow.out" "the refusal is reported for: gbot $forbidden"
done
pass "the read-only allowlist refuses every mutating or fallback gbot command"

# --- new bot message: result, cursor advance, captain sends ignored ---------
new_home msg
printf '[%s,%s]\n' "$(user_msg u1 'old captain prompt')" "$(bot_msg b1 'old bot history')" > "$D/thread-bot-a.json"
gb arm >/dev/null
start_runner
wait_cursor bot-a b1 || fail "a first-seen bot is baselined at its current tail"
wait_polls 3 || fail "an idle thread keeps being polled"
[ "$(result_count)" -eq 0 ] || fail "an idle thread must not produce a result"
kill -0 "$RUNNER_PID" 2>/dev/null || fail "the source must keep polling while nothing is new"
printf '[%s,%s,%s,%s]\n' "$(user_msg u1 'old captain prompt')" "$(bot_msg b1 'old bot history')" \
  "$(user_msg u2 'CAPTAIN-SECRET-PROMPT')" "$(bot_msg b2 'fresh bot reply' 5)" > "$D/thread-bot-a.json"
wait_runner || fail "the source completes once a bot posts"
R=$(last_result)
[ "$(result_count)" -eq 1 ] || fail "one bot message produces exactly one result"
[ "$(gb classify "$R")" = messages ] || fail "the result classifies as messages"
assert_grep "fresh bot reply" "$R" "the result carries the new bot message"
assert_grep "Name-bot-a" "$R" "the result names the bot"
assert_grep "2026-09-29T12:00:05Z" "$R" "the result carries the message timestamp"
assert_grep "$(printf 'advance\tbot-a\tb1\tb2')" "$R" "the result carries the cursor advance"
assert_no_grep "CAPTAIN-SECRET-PROMPT" "$R" "the captain's own send is never surfaced"
assert_no_grep "old bot history" "$R" "history before the baseline is never replayed"
[ "$(cursor_of bot-a)" = b2 ] || fail "autohandle commits the new cursor"
assert_present "$H/state/procevent-inbox/grokbot.$(basename "$R" | cut -d. -f2).handled" "autohandle acknowledges the result"
assert_grep "procevent:grokbot:" "$H/state/.wake-queue" "the result is announced on the durable wake queue"
if grep -v -E '^(doctor --json --gateway|bots list --json --gateway|thread bot-a (--after [^ ]+ )?--limit [0-9]+ --json --gateway --no-history)$' "$D/calls.log" | grep -q .; then
  fail "the adapter made a gbot call outside the read-only set: $(cat "$D/calls.log")"
fi
pass "a new bot message produces one result, advances the cursor, and ignores captain sends"

# --- restart after acknowledgement continues from the saved cursor ----------
: > "$D/calls.log"
start_runner
wait_polls 2 || fail "the restarted source polls"
[ "$(result_count)" -eq 1 ] || fail "a restart must not redeliver acknowledged messages"
assert_grep "thread bot-a --after b2" "$D/calls.log" "the restarted source continues from the committed cursor"
stop_runner
gb arm >/dev/null
printf '[%s,%s,%s]\n' "$(bot_msg b1 'old bot history')" "$(bot_msg b2 'fresh bot reply' 5)" \
  "$(bot_msg b3 'after rearm' 7)" > "$D/thread-bot-a.json"
start_runner
wait_runner || fail "the re-armed source completes on the next bot message"
R=$(last_result)
[ "$(result_count)" -eq 2 ] || fail "the re-armed source produces one more result"
assert_grep "after rearm" "$R" "the re-armed result carries only the new message"
assert_no_grep "fresh bot reply" "$R" "the re-armed result does not repeat the acknowledged message"
[ "$(cursor_of bot-a)" = b3 ] || fail "the re-armed result advances the cursor"
pass "a restart or re-arm after acknowledgement continues from the saved cursors"

# --- captain-only activity advances silently --------------------------------
new_home captain
printf '[%s]\n' "$(bot_msg b1 'history')" > "$D/thread-bot-a.json"
gb arm >/dev/null
start_runner
wait_cursor bot-a b1 || fail "baseline"
printf '[%s,%s]\n' "$(bot_msg b1 'history')" "$(user_msg u9 'captain only')" > "$D/thread-bot-a.json"
wait_cursor bot-a u9 || fail "captain-only activity advances the cursor"
[ "$(result_count)" -eq 0 ] || fail "captain-only activity produces no result"
kill -0 "$RUNNER_PID" 2>/dev/null || fail "the source keeps polling after captain-only activity"
stop_runner
pass "the captain's own sends advance the cursor without waking firstmate"

# --- gap reset re-baselines without replay ----------------------------------
new_home gap
printf '[%s,%s]\n' "$(bot_msg x1 'REPLAYED-HISTORY-ONE')" "$(bot_msg x2 'REPLAYED-HISTORY-TWO')" > "$D/thread-bot-a.json"
mkdir -p "$H/state/grokbot-watch"
printf 'bot-a\tvanished-entry\n' > "$H/state/grokbot-watch/cursors.tsv"
gb arm >/dev/null
start_runner
wait_runner || fail "a gap reset completes the source"
R=$(last_result)
[ "$(gb classify "$R")" = gap ] || fail "a lost cursor classifies as gap"
assert_grep "gap reset" "$R" "the result says the cursor was lost"
assert_grep "re-baselined" "$R" "the result says the bot was re-baselined"
assert_no_grep "REPLAYED-HISTORY" "$R" "a gap reset never replays the tail as new messages"
[ "$(cursor_of bot-a)" = x2 ] || fail "a gap reset rebases the cursor to the current tail"
pass "gapReset re-baselines to the current tail without replaying history"

# --- bounded results --------------------------------------------------------
new_home bound
gb arm >/dev/null
FM_GROKBOT_MAX_MESSAGES=3 FM_GROKBOT_MAX_MESSAGE_BYTES=300 start_runner
wait_cursor bot-a - || fail "an empty thread baselines as empty"
long=$(printf 'L%.0s' $(seq 1 900))
printf '[%s,%s,%s,%s,%s]\n' "$(bot_msg m1 one)" "$(bot_msg m2 two)" "$(bot_msg m3 three)" \
  "$(bot_msg m4 four)" "$(bot_msg m5 "$long")" > "$D/thread-bot-a.json"
wait_runner || fail "the bounded source completes"
R=$(last_result)
assert_grep "messages=3" "$R" "at most the configured number of messages is shown"
assert_grep "omitted=2" "$R" "the omitted messages are counted"
assert_no_grep "entry m1" "$R" "the oldest messages are the ones omitted"
assert_grep "entry m5" "$R" "the newest message is kept"
assert_grep "truncated" "$R" "an oversized message is truncated"
[ "$(wc -c < "$R")" -lt 4000 ] || fail "the bounded result stays small"
[ "$(cursor_of bot-a)" = m5 ] || fail "the cursor still advances past omitted messages"
pass "results are bounded in message count and per-message size"

# --- gbot missing: one diagnostic, quiet backoff, then recovery -------------
new_home missing
FM_HOME="$H" PATH="$TMP_ROOT/nogbot:$BASE_PATH" "$ROOT/bin/fm-procevent-grokbot.sh" arm >/dev/null 2>&1
start_runner "$TMP_ROOT/nogbot:$BASE_PATH"
wait_runner || fail "a missing gbot completes the source with a diagnostic"
R=$(last_result)
[ "$(gb classify "$R")" = diagnostic ] || fail "a missing gbot classifies as diagnostic"
assert_grep "diagnostic=gbot-missing" "$R" "the diagnostic names the missing gbot"
assert_grep "gbot-missing" "$H/state/grokbot-watch/diagnostic" "autohandle records the reported diagnostic"
start_runner "$TMP_ROOT/nogbot:$BASE_PATH"
sleep 1.5
[ "$(result_count)" -eq 1 ] || fail "a repeated failure must not re-announce the same diagnostic"
kill -0 "$RUNNER_PID" 2>/dev/null || fail "the source keeps retrying quietly with backoff"
cp "$FAKEBIN/gbot" "$TMP_ROOT/nogbot/gbot"
wait_runner || fail "the source completes once gbot is available again"
R=$(last_result)
[ "$(gb classify "$R")" = recovered ] || fail "a cleared failure reports recovery"
assert_grep "recovered_from=gbot-missing" "$R" "the recovery names what cleared"
assert_absent "$H/state/grokbot-watch/diagnostic" "recovery clears the recorded diagnostic"
rm -f "$TMP_ROOT/nogbot/gbot"
pass "a missing gbot yields one diagnostic, quiet backoff, and one recovery notice"

# --- unauthenticated and gateway errors -------------------------------------
new_home auth
: > "$D/doctor.unusable"
gb arm >/dev/null
start_runner
wait_runner || fail "an unusable session completes the source with a diagnostic"
R=$(last_result)
assert_grep "diagnostic=unauthenticated" "$R" "an unusable session is reported as unauthenticated"
assert_grep "KEYCHAIN_DENIED" "$R" "the diagnostic carries gbot's session code"
if grep -v '^doctor --json --gateway$' "$D/calls.log" | grep -q .; then
  fail "nothing but doctor may run while the session is unusable"
fi
new_home gateway
gb arm >/dev/null
: > "$D/gateway.fail"
start_runner
wait_runner || fail "a gateway error completes the source with a diagnostic"
R=$(last_result)
[ "$(gb classify "$R")" = diagnostic ] || fail "a gateway error classifies as diagnostic"
assert_no_grep "sk-live-SECRET" "$R" "a credential in gbot's error text is never persisted"
[ "$(result_count)" -eq 1 ] || fail "one gateway failure produces one diagnostic"
pass "unauthenticated and gateway failures each produce one redacted diagnostic"

# --- one failing bot never blocks another, and is named only once -----------
new_home onebad
printf '[{"id":"bot-a","name":"Alpha","kind":"bot"},{"id":"bot-b","name":"Beta","kind":"bot"}]\n' > "$D/bots.json"
printf '[%s]\n' "$(bot_msg b1 'history')" > "$D/thread-bot-a.json"
printf '[%s]\n' "$(bot_msg c1 'beta history')" > "$D/thread-bot-b.json"
mkdir -p "$H/state/grokbot-watch"
printf 'bot-a\tb1\nbot-b\tc1\n' > "$H/state/grokbot-watch/cursors.tsv"
printf '[%s,%s]\n' "$(bot_msg b1 'history')" "$(bot_msg b2 'alpha still delivers' 3)" > "$D/thread-bot-a.json"
: > "$D/thread-bot-b.fail"
gb arm >/dev/null
start_runner
wait_runner || fail "a round with one failing bot still completes"
R=$(last_result)
[ "$(gb classify "$R")" = messages ] || fail "the other bot's messages are still delivered"
assert_grep "alpha still delivers" "$R" "the healthy bot's message is in the result"
assert_grep "$(printf 'bot-error\tbot-b\tBeta\tgateway-error')" "$R" "the failing bot is named with its code"
assert_grep "bot_errors=1" "$R" "the header counts the newly failing bot"
[ "$(cursor_of bot-a)" = b2 ] || fail "the healthy bot's cursor is committed"
[ "$(cursor_of bot-b)" = c1 ] || fail "the failing bot's cursor is left alone"
assert_grep "bot-b" "$H/state/grokbot-watch/bot-errors" "autohandle records the reported bot failure"
: > "$D/calls.log"
start_runner
wait_polls 2 || fail "the source keeps polling while the same bot keeps failing"
[ "$(result_count)" -eq 1 ] || fail "a bot that keeps failing must not be re-announced on its own"
printf '[%s,%s,%s]\n' "$(bot_msg b1 'history')" "$(bot_msg b2 'alpha still delivers' 3)" \
  "$(bot_msg b3 'alpha again' 4)" > "$D/thread-bot-a.json"
wait_runner || fail "the next healthy message completes the source"
R=$(last_result)
[ "$(result_count)" -eq 2 ] || fail "the next healthy message produces one more result"
assert_grep "alpha again" "$R" "the next result carries the new message"
assert_no_grep "bot-error" "$R" "the same failing bot is not re-announced"
assert_grep "bot_errors=0" "$R" "the header counts no newly failing bot"
rm -f "$D/thread-bot-b.fail"
start_runner
for _ in $(seq 1 150); do
  [ -e "$H/state/grokbot-watch/bot-errors" ] || break
  sleep 0.1
done
assert_absent "$H/state/grokbot-watch/bot-errors" "a bot that polls again clears its failure record"
[ "$(result_count)" -eq 2 ] || fail "a recovery alone produces no result"
stop_runner
pass "one failing bot is skipped and named once while the other bots still deliver"

# --- an unrecognised baseline never saves an empty cursor --------------------
new_home badbase
printf '[%s]\n' "$(bot_msg b1 'history')" > "$D/thread-bot-a.json"
: > "$D/thread-bot-a.bad"
gb arm >/dev/null
start_runner
wait_runner || fail "an unrecognised baseline document completes the source"
R=$(last_result)
[ "$(gb classify "$R")" = bot-error ] || fail "an unrecognised baseline is that bot's failure"
assert_grep "$(printf 'bot-error\tbot-a\tAlpha\tunexpected-response')" "$R" "the bot-error names the bot and the code"
if awk -F '\t' '$1 == "bot-a"' "$H/state/grokbot-watch/cursors.tsv" 2>/dev/null | grep -q .; then
  fail "an unrecognised baseline must not save a cursor"
fi
rm -f "$D/thread-bot-a.bad"
start_runner
wait_cursor bot-a b1 || fail "the bot is baselined once its document is readable again"
[ "$(result_count)" -eq 1 ] || fail "a successful baseline produces no result"
stop_runner
new_home emptycursor
printf '[%s]\n' "$(bot_msg b1 'EARLIER-HISTORY')" > "$D/thread-bot-a.json"
mkdir -p "$H/state/grokbot-watch"
printf 'bot-a\t\n' > "$H/state/grokbot-watch/cursors.tsv"
gb arm >/dev/null
start_runner
wait_runner || fail "an unreadable saved cursor completes the source"
R=$(last_result)
[ "$(gb classify "$R")" = gap ] || fail "an unreadable saved cursor is re-baselined as a gap"
assert_grep "gaps=1" "$R" "the re-baseline is counted as a gap"
assert_no_grep "EARLIER-HISTORY" "$R" "the re-baseline replays nothing"
[ "$(cursor_of bot-a)" = b1 ] || fail "an unreadable saved cursor is rebased to the current tail"
pass "an unrecognised baseline never saves an empty cursor, and an unreadable one is re-baselined"

# --- invalid tuning falls back to the defaults ------------------------------
new_home tuning
gb arm >/dev/null
FM_GROKBOT_MAX_MESSAGES=lots FM_GROKBOT_MAX_MESSAGE_BYTES=-5 FM_GROKBOT_CALL_TIMEOUT=0 start_runner
wait_cursor bot-a - || fail "invalid tuning still lets the bot baseline"
mid=$(printf 'M%.0s' $(seq 1 600))
printf '[%s,%s,%s]\n' "$(bot_msg t1 one)" "$(bot_msg t2 two)" "$(bot_msg t3 "$mid")" > "$D/thread-bot-a.json"
wait_runner || fail "invalid tuning still delivers messages"
R=$(last_result)
assert_grep "messages=3" "$R" "an invalid message cap falls back to the default"
assert_grep "omitted=0" "$R" "nothing is omitted under the default cap"
assert_no_grep "truncated" "$R" "an invalid per-message bound falls back to the default"
pass "invalid tuning values fall back to their defaults"

# --- a mixed gap and messages round carries the gap count -------------------
new_home mixed
printf '[{"id":"bot-a","name":"Alpha","kind":"bot"},{"id":"bot-b","name":"Beta","kind":"bot"}]\n' > "$D/bots.json"
printf '[%s]\n' "$(bot_msg x1 'GAP-HISTORY')" > "$D/thread-bot-a.json"
printf '[%s,%s]\n' "$(bot_msg c1 'beta history')" "$(bot_msg c2 'beta fresh' 2)" > "$D/thread-bot-b.json"
mkdir -p "$H/state/grokbot-watch"
printf 'bot-a\tvanished-entry\nbot-b\tc1\n' > "$H/state/grokbot-watch/cursors.tsv"
gb arm >/dev/null
start_runner
wait_runner || fail "a mixed round completes the source"
R=$(last_result)
[ "$(gb classify "$R")" = messages ] || fail "a mixed round classifies as messages"
assert_grep "gaps=1" "$R" "a mixed round still carries its gap count"
assert_grep "beta fresh" "$R" "a mixed round delivers the new message"
assert_no_grep "GAP-HISTORY" "$R" "a mixed round replays no gap history"
pass "a mixed gap and messages round carries the gap count"
