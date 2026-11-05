#!/usr/bin/env bash
# tests/fm-remote-secondmate-t3code.test.sh - a remote second mate whose own
# agent is a thread on its host's T3 Code server, driven against the fake T3
# server in tests/t3-fake-server.mjs:
#
#   A) bin/fm-remote-secondmate-control.sh launch on t3code drives the ordinary
#      host-local secondmate spawn into a thread on that host's T3, using the
#      home's own sign-in, which the launch must leave a regular file.
#   B) A steer lands as a durable inbox record and rings one T3 doorbell; the
#      route-scoped records stay out of the mate's own home state.
#   C) Capture reads the thread, and relaunch is refused by the ordinary
#      control plane exactly as for a local T3 second mate.
#   D) A home whose credential is a link to another home's, or names another
#      machine's T3, is refused for launch and reads unverified.
#   E) A failed run reads dead; the next launch proves the old thread archived
#      before it launches the replacement thread.
#   F) bin/fm-remote-doctor.sh --backend t3code reports the credential and
#      server checks, and names the sign-in when the credential is missing.
#   G) bin/fm-spawn.sh's parent-side gate accepts t3code and proceeds to the
#      remote transport hop, and refuses an unsupported harness before it.
#   H) Host-local retirement archives the thread and removes the home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-t3code)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
ln -sf "$(command -v git)" "$FAKEBIN/git"
ln -sf "$(command -v jq)" "$FAKEBIN/jq"
ln -sf "$(command -v node)" "$FAKEBIN/node"
fm_fake_exit0 "$FAKEBIN" treehouse

SSH_LOG="$TMP_ROOT/ssh-hops.log"
cat > "$FAKEBIN/fake-ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SSH_LOG"
exit 255
SH
chmod +x "$FAKEBIN/fake-ssh"

t3_fake_start "$TMP_ROOT/server"
cleanup() {
  t3_fake_stop
  fm_test_cleanup
}
trap cleanup EXIT
t3_fake_case "$TMP_ROOT/case" '{"projects":[],"threads":{}}'

ID=sm-t3
HOME_DIR="$TMP_ROOT/home-$ID"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/data" "$HOME_DIR/config"
printf '# Firstmate\n' > "$HOME_DIR/AGENTS.md"
printf '%s\n' "$ID" > "$HOME_DIR/.fm-secondmate-home"
printf '# Charter\n\nStand by until steering arrives.\n' > "$HOME_DIR/data/charter.md"
git -C "$HOME_DIR" init -q -b sm/home
git -C "$HOME_DIR" add -A
git -C "$HOME_DIR" -c user.name=t -c user.email=t@example.invalid commit -qm seed
TOKEN="$HOME_DIR/config/t3code-token"
t3_fake_credential "$TOKEN"
TOKEN_BODY=$(cat "$TOKEN")
META="$HOME_DIR/state/parent-route/$ID.meta"
USER_HOME="$TMP_ROOT/user-home"
mkdir -p "$USER_HOME"

ctl() {
  PATH="$FAKEBIN:$BASE_PATH" TMUX='' HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' \
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}

route_field() { # <file> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

# --- A) host-local launch -----------------------------------------------------

ctl launch "$ID" claude claude-sonnet-5 - t3code > "$TMP_ROOT/launch.out" 2> "$TMP_ROOT/launch.err"
expect_code 0 "$?" "host-local remote secondmate launch on t3code failed"$'\n'"$(cat "$TMP_ROOT/launch.err")"
assert_grep 'backend=t3code' "$TMP_ROOT/launch.out" "the printed route did not name the t3code backend"$'\n'"$(cat "$TMP_ROOT/launch.out" "$TMP_ROOT/launch.err")"
assert_grep 'harness=claude' "$TMP_ROOT/launch.out" "the printed route lost the claude harness"
THREAD=$(route_field "$TMP_ROOT/launch.out" target)
[ -n "$THREAD" ] || fail "the printed route carried no thread target"
[ "$(route_field "$TMP_ROOT/launch.out" t3_thread_id)" = "$THREAD" ] || fail "the printed route's t3_thread_id must name its target thread"
[ "$(route_field "$META" t3_thread_id)" = "$THREAD" ] || fail "the endpoint record did not bind the launched thread"
[ "$(route_field "$META" backend)" = t3code ] || fail "the endpoint record did not name the t3code backend"
[ -f "$TOKEN" ] && [ ! -L "$TOKEN" ] || fail "the launch replaced the home's own T3 sign-in with a link"
[ "$(cat "$TOKEN")" = "$TOKEN_BODY" ] || fail "the launch changed the home's own T3 sign-in"
[ "$(t3_fake_mutations)" = "t3_project_create t3_thread_launch t3_thread_send" ] \
  || fail "a launch must create the home's project, launch one thread, and send the charter, got '$(t3_fake_mutations)'"
assert_contains "$(t3_fake_calls t3_project_create)" "\"workspaceRoot\":\"$HOME_DIR\"" "the T3 project must be the mate's home"
assert_contains "$(t3_fake_calls t3_thread_send)" "Stand by until steering arrives." "the first message must carry the charter"
[ "$(ctl state "$ID")" = alive ] || fail "the launched thread did not read alive from its host-local route"
ctl route "$ID" > "$TMP_ROOT/route.out" 2>&1 || fail "the route verb failed: $(cat "$TMP_ROOT/route.out")"
[ "$(route_field "$TMP_ROOT/route.out" target)" = "$THREAD" ] || fail "the route verb lost the thread target"
ctl launch "$ID" claude claude-sonnet-5 - t3code > "$TMP_ROOT/relaunch-alive.out" 2>&1 \
  || fail "a launch onto a live thread must return its route: $(cat "$TMP_ROOT/relaunch-alive.out")"
[ "$(route_field "$TMP_ROOT/relaunch-alive.out" target)" = "$THREAD" ] || fail "a launch onto a live thread must reuse it"
[ "$(t3_fake_calls t3_thread_launch | wc -l | tr -d ' ')" = 1 ] || fail "a launch onto a live thread must not launch a second one"
pass "A host-local launch runs the mate as a thread on the host's T3 with the home's own sign-in"

# --- B) steering --------------------------------------------------------------

: > "$T3_FAKE_LOG"
ctl send "$ID" "Work the simulator queue." > "$TMP_ROOT/send.out" 2> "$TMP_ROOT/send.err"
expect_code 0 "$?" "a steer to the T3 mate failed"$'\n'"$(cat "$TMP_ROOT/send.err")"
REC=$(find "$HOME_DIR/state/parent-route/$ID.inbox" -maxdepth 1 -name '*.msg' | head -1)
[ -n "$REC" ] || fail "the steer left no durable inbox record"
assert_grep 'Work the simulator queue.' "$REC" "the inbox record lost the steer body"
[ "$(t3_fake_mutations)" = t3_thread_send ] || fail "a steer must ring exactly one T3 doorbell, got '$(t3_fake_mutations)'"
assert_not_contains "$(t3_fake_calls t3_thread_send)" "Work the simulator queue." "the doorbell must not carry the steer body"
assert_contains "$(t3_fake_calls t3_thread_send)" "\"threadId\":\"$THREAD\"" "the doorbell must reach the mate's thread"
assert_absent "$HOME_DIR/state/t3code-sends" "the doorbell's send record belongs to the route state, not the mate's own home state"
assert_present "$HOME_DIR/state/parent-route/t3code-sends" "the doorbell kept no send record in the route state"
pass "B a steer is a durable inbox record plus one T3 doorbell"

# --- C) capture and relaunch --------------------------------------------------

ctl capture "$ID" 20 > "$TMP_ROOT/capture.out" 2>&1 || fail "capture failed: $(cat "$TMP_ROOT/capture.out")"
assert_grep 'Stand by until steering arrives.' "$TMP_ROOT/capture.out" "capture did not read the thread"
ctl observe "$ID" > "$TMP_ROOT/observe.out" 2>&1 || fail "observe failed: $(cat "$TMP_ROOT/observe.out")"
: > "$T3_FAKE_LOG"
if ctl relaunch "$ID" claude - - > "$TMP_ROOT/relaunch.out" 2>&1; then
  fail "a t3code relaunch must be refused like a local T3 second mate's"
fi
assert_grep 'runs on the t3code backend' "$TMP_ROOT/relaunch.out" "the relaunch refusal did not name the t3code runtime"$'\n'"$(cat "$TMP_ROOT/relaunch.out")"
[ -z "$(t3_fake_mutations)" ] || fail "a refused relaunch must change nothing on T3, got '$(t3_fake_mutations)'"
[ "$(ctl state "$ID")" = alive ] || fail "a refused relaunch must leave the thread alive"
pass "C capture reads the thread and relaunch is refused by the control plane"

# --- D) credential locality ---------------------------------------------------

mv "$TOKEN" "$TMP_ROOT/held-token"
cp "$TMP_ROOT/held-token" "$TMP_ROOT/other-home-token"
chmod 600 "$TMP_ROOT/other-home-token"
ln -s "$TMP_ROOT/other-home-token" "$TOKEN"
[ "$(ctl state "$ID" 2>"$TMP_ROOT/state-linked.err")" = unverified ] || fail "a linked credential must read unverified"
assert_grep 'link to another home' "$TMP_ROOT/state-linked.err" "the unverified read must name the linked credential"
if ctl launch "$ID" claude claude-sonnet-5 - t3code > "$TMP_ROOT/launch-linked.out" 2>&1; then
  fail "a launch must refuse a home whose T3 credential is a link"
fi
assert_grep 'own sign-in' "$TMP_ROOT/launch-linked.out" "the linked-credential refusal must name the home's own sign-in"
rm -f "$TOKEN"
t3_fake_credential "$TOKEN" env-fake-1 "" 600 "http://192.0.2.10:3773"
if ctl launch "$ID" claude claude-sonnet-5 - t3code > "$TMP_ROOT/launch-foreign.out" 2>&1; then
  fail "a launch must refuse a credential for another machine's T3"
fi
assert_grep "not this machine's own T3 server" "$TMP_ROOT/launch-foreign.out" "the refusal must name a non-local T3 origin"
rm -f "$TOKEN"
mv "$TMP_ROOT/held-token" "$TOKEN"
[ "$(ctl state "$ID")" = alive ] || fail "restoring the home's own sign-in must restore access"
pass "D a linked or foreign T3 credential is refused"

# --- E) failed run relaunches through a proven archive -------------------------

FM_T3_THREAD=$THREAD t3_fake_set 'const t = w.threads[process.env.FM_T3_THREAD]; t.status = "failed"; t.activeRunId = null; for (const r of t.runs) r.status = "failed";'
[ "$(ctl state "$ID")" = dead ] || fail "a failed T3 run must read dead"
: > "$T3_FAKE_LOG"
ctl launch "$ID" claude claude-sonnet-5 - t3code > "$TMP_ROOT/launch-dead.out" 2> "$TMP_ROOT/launch-dead.err"
expect_code 0 "$?" "a launch after a failed run must replace the thread"$'\n'"$(cat "$TMP_ROOT/launch-dead.err")"
NEW_THREAD=$(route_field "$TMP_ROOT/launch-dead.out" target)
[ -n "$NEW_THREAD" ] && [ "$NEW_THREAD" != "$THREAD" ] || fail "the replacement must be a new thread, got '$NEW_THREAD'"
case "$(t3_fake_mutations)" in
  t3_thread_organize*t3_thread_launch*) ;;
  *) fail "the failed thread must be archived before the replacement launches, got '$(t3_fake_mutations)'" ;;
esac
assert_contains "$(t3_fake_calls t3_thread_organize)" "\"threadId\":\"$THREAD\"" "the archive must target the failed thread"
[ "$(FM_T3_THREAD=$THREAD node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(w.threads[process.env.FM_T3_THREAD].archived))' "$T3_FAKE_WORLD")" = true ] \
  || fail "the failed thread must end archived"
THREAD=$NEW_THREAD
[ "$(ctl state "$ID")" = alive ] || fail "the replacement thread did not read alive"
pass "E a failed run is archived before a replacement thread launches"

# --- F) doctor ----------------------------------------------------------------

doctor() { # <home>
  PATH="$FAKEBIN:$BASE_PATH" HOME="$USER_HOME" FM_HOME="$1" \
    "$ROOT/bin/fm-remote-doctor.sh" --backend t3code 2>&1
}
OUT=$(doctor "$HOME_DIR")
assert_contains "$OUT" "required node=" "the t3code doctor must require node"
assert_contains "$OUT" "check t3code=ok:" "the doctor must accept the home's own sign-in"$'\n'"$OUT"
assert_contains "$OUT" "check t3code-server=ok:" "the doctor must accept an answering T3 server"$'\n'"$OUT"
assert_not_contains "$OUT" "check herdr" "the t3code doctor must not check Herdr"
EMPTY_HOME="$TMP_ROOT/unsigned-home"
mkdir -p "$EMPTY_HOME/config"
OUT=$(doctor "$EMPTY_HOME")
assert_contains "$OUT" "check t3code=human: no T3 credential" "a missing sign-in must be a human gap"$'\n'"$OUT"
assert_contains "$OUT" "action: t3code: on that machine, as that account, run '$ROOT/bin/fm-t3-mcp.mjs login --access full-access --token-file $EMPTY_HOME/config/t3code-token'" \
  "the gap must name the exact sign-in for that home"$'\n'"$OUT"
assert_contains "$OUT" "check t3code-server=human:" "the server check waits on the credential"
t3_fake_credential "$EMPTY_HOME/config/t3code-token" env-fake-1 "" 600 "http://127.0.0.1:9"
OUT=$(doctor "$EMPTY_HOME")
assert_contains "$OUT" "check t3code=ok:" "a loopback credential passes the offline check"
assert_contains "$OUT" "check t3code-server=human:" "an unreachable T3 server must be a human gap"$'\n'"$OUT"
pass "F the doctor checks the home's own T3 sign-in and its server"

# --- G) parent-side remote spawn ----------------------------------------------

PARENT="$TMP_ROOT/parent"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects"
cat > "$PARENT/data/secondmates.md" <<EOF
- $ID - Remote T3 mate (host: remote-host; root: $ROOT; home: $HOME_DIR; scope: remote t3 verification; projects: none; added 2026-11-05)
EOF
parent_spawn() { # <harness>
  PATH="$FAKEBIN:$BASE_PATH" TMUX='' FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$PARENT/state" FM_DATA_OVERRIDE="$PARENT/data" \
    FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" HOME="$TMP_ROOT/parent-user-home" \
    "$ROOT/bin/fm-spawn.sh" "$ID" --secondmate --harness "$1" --backend t3code
}
: > "$SSH_LOG"
parent_spawn omp > "$TMP_ROOT/spawn-omp.out" 2> "$TMP_ROOT/spawn-omp.err" \
  && fail "the parent must refuse an omp second mate on t3code"
assert_grep 'runs only the claude or codex harness' "$TMP_ROOT/spawn-omp.err" "the refusal must name the t3code harness limit"
[ ! -s "$SSH_LOG" ] || fail "an unsupported t3code harness must be refused before the remote hop"
parent_spawn claude > "$TMP_ROOT/spawn.out" 2> "$TMP_ROOT/spawn.err" \
  && fail "the parent-side spawn should surface the unreachable remote transport"
assert_grep 'readiness could not be confirmed; preserved route' "$TMP_ROOT/spawn.err" \
  "the t3code remote spawn did not pass the backend gate to the transport hop"$'\n'"$(cat "$TMP_ROOT/spawn.err")"
[ -s "$SSH_LOG" ] || fail "the t3code remote spawn never reached the remote transport hop"
pass "G the parent-side remote spawn gate accepts t3code for claude and refuses other harnesses first"

# --- H) host-local retirement -------------------------------------------------

if ! command -v lsof >/dev/null 2>&1; then
  echo "note: H skipped: lsof is required to prove the T3 mate's home is quiet before retirement"
else
  : > "$T3_FAKE_LOG"
  ctl retire "$ID" > "$TMP_ROOT/retire.out" 2>&1
  expect_code 0 "$?" "host-local retirement of a T3 mate failed"$'\n'"$(cat "$TMP_ROOT/retire.out")"
  assert_contains "$(t3_fake_calls t3_thread_organize)" "\"threadId\":\"$THREAD\"" "retirement must archive the mate's thread"
  assert_absent "$HOME_DIR" "retirement left the T3 mate's home behind"
  pass "H host-local retirement archives the thread and removes the home"
fi

echo "ALL TESTS PASSED"
