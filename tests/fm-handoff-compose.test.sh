#!/usr/bin/env bash
# Behavior tests for bin/fm-handoff-compose.sh, the hand-off document a
# continuation task reads first: a golden file for a ship whose T3 thread is
# served by tests/t3-fake-server.mjs, the budget bound on a long thread, and
# the document without a transcript tail (no T3 thread, a scout, a failed
# read). Regenerate the golden file with FM_UPDATE_GOLDEN=1 after a deliberate
# format change, and review its diff.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }

COMPOSE="$ROOT/bin/fm-handoff-compose.sh"
GOLDEN="$ROOT/tests/fixtures/fm-handoff-compose/ship.golden"
TMP_ROOT=$(fm_test_tmproot fm-handoff-compose)
trap 't3_fake_stop; fm_test_cleanup' EXIT

# Fixed identity and dates make every commit id in the golden file stable.
export GIT_AUTHOR_NAME='Firstmate Tests' GIT_AUTHOR_EMAIL='tests@example.invalid'
export GIT_COMMITTER_NAME='Firstmate Tests' GIT_COMMITTER_EMAIL='tests@example.invalid'
export GIT_AUTHOR_DATE='2026-11-12T00:00:00Z' GIT_COMMITTER_DATE='2026-11-12T00:00:00Z'

# A home with task <id> on <kind>, its brief, notes, status log, and the
# continuation record for <id>-c2; a ship's copy has two commits past main.
make_home() {  # <name> <id> <kind> [backend] [thread]
  local dir=$TMP_ROOT/$1 id=$2 kind=$3 backend=${4:-tmux} thread=${5:-} home copy head i
  home=$dir/home
  copy=$dir/copy
  mkdir -p "$home/state" "$home/config" "$home/data/$id" "$home/data/$id-c2"
  {
    printf '%s\n' '# Task' "## Captain's intent" "Ship the widget for $id." '' '### Boundary' 'Keep it small.' ''
    printf '%s\n' '## Firstmate spec' '- Touch only `widget.txt`.' '- Out of scope: the gadget.' ''
    printf '%s\n' '# Setup' 'You are in a disposable git worktree.' ''
    printf '%s\n' '# Definition of done' 'Delivery contract: mode=direct-PR'
  } > "$home/data/$id/brief.md"
  printf '%s\n' 'Done: first half.' 'Left: second half.' 'Verify: `cat widget.txt`.' > "$home/data/$id/handoff-notes.md"
  for i in $(seq 1 12); do
    printf 'working [at=%s]: step %s\n' "$((1794470000 + i))" "$i"
  done > "$home/state/$id.status"
  printf 'paused [at=1794470100]: handoff ready fm/%s\n' "$id" >> "$home/state/$id.status"
  {
    printf '%s\n' "kind=$kind" "backend=$backend" "worktree=$copy" "branch=fm/$id"
    [ -z "$thread" ] || printf '%s\n' "t3_thread_id=$thread"
  } > "$home/state/$id.meta"
  if [ "$kind" = ship ]; then
    fm_git_init_commit "$dir/project"
    fm_git_add_origin "$dir/project" "$dir/origin.git"
    git -C "$dir/project" fetch --quiet origin
    git -C "$dir/project" worktree add --quiet -b "fm/$id" "$copy" origin/main
    printf 'first half\n' > "$copy/widget.txt"
    git -C "$copy" add widget.txt
    git -C "$copy" commit -qm 'first half of the widget'
    printf 'scratch\n' > "$copy/wip.txt"
    git -C "$copy" add wip.txt
    git -C "$copy" commit -qm 'wip: hand-off'
    head=$(git -C "$copy" rev-parse HEAD)
    printf '%s\n' schema=fm-continuation.v1 "continued_from=$id" kind=ship to=local remote=origin "branch=fm/$id" "head=$head" \
      > "$home/data/$id-c2/continuation"
  else
    printf '%s\n' schema=fm-continuation.v1 "continued_from=$id" kind=scout to=local > "$home/data/$id-c2/continuation"
  fi
  printf '%s\n' "$dir"
}

compose() {  # <case-dir> <id> [args...] -> stdout in OUT, stderr in ERR, exit in RC
  local dir=$1 id=$2
  shift 2
  OUT=$(FM_HOME="$dir/home" "$COMPOSE" "$id" "$id-c2" "$@" 2>"$dir/stderr")
  RC=$?
  ERR=$(cat "$dir/stderr")
}

# A thread whose transcript holds <count> messages after the launch message,
# each about <size> bytes, with tool items between them.
seed_thread() {  # <thread-id> <count> <size>
  FM_T3_THREAD=$1 FM_T3_COUNT=$2 FM_T3_SIZE=$3 t3_fake_set '
const n = Number(process.env.FM_T3_COUNT), size = Number(process.env.FM_T3_SIZE);
const body = (label) => label + ": " + "w".repeat(Math.max(0, size - label.length - 2));
const items = [{ type: "user_message", status: "completed", text: "# Task\nLaunch brief for the old worker." }];
for (let i = 1; i <= n; i++) {
  items.push({ type: "command_execution", status: "completed", text: "git status" });
  items.push({ type: i % 2 ? "assistant_message" : "user_message", status: "completed", text: body("message " + i) });
}
items.push({ type: "proposed_plan", status: "completed", text: "Plan: finish the second half." });
items.push({ type: "user_message", status: "completed", text: "Firstmate is handing this task off." });
items.push({ type: "assistant_message", status: "completed", text: "Committed, pushed, and wrote my notes.\n```sh\ngit push origin fm/old\n```" });
w.threads = w.threads || {};
w.threads[process.env.FM_T3_THREAD] = { threadId: process.env.FM_T3_THREAD, projectId: "p", status: "idle", activeRunId: null, archived: false,
  worktreePath: "/wt", pendingRequestCount: 0, parentThreadId: null, relationshipToParent: null, items, runs: [] };'
}

test_ship_document_matches_golden_file() {
  local dir normalized
  dir=$(make_home golden old-h2 ship t3code thread-h2)
  t3_fake_case "$TMP_ROOT/cases/golden"
  t3_fake_credential "$dir/home/config/t3code-token"
  seed_thread thread-h2 120 90
  compose "$dir" old-h2 --reason 'context exhausted' --budget-tokens 1500
  expect_code 0 "$RC" "compose: $ERR"
  [ -z "$ERR" ] || fail "a composed document within budget warns nothing, got: $ERR"
  [ "$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')" -le 6000 ] || fail "the document exceeds its 1500-token budget"
  normalized=$(printf '%s\n' "$OUT" | sed "s#$TMP_ROOT#<tmp>#g")
  if [ "${FM_UPDATE_GOLDEN:-0}" = 1 ]; then
    mkdir -p "$(dirname "$GOLDEN")"
    printf '%s\n' "$normalized" > "$GOLDEN"
  fi
  printf '%s\n' "$normalized" > "$dir/actual"
  diff -u "$GOLDEN" "$dir/actual" >&2 || fail "the composed hand-off document differs from $GOLDEN"
  pass "a ship's hand-off document carries the brief, status, commits, notes, and a budgeted transcript tail exactly as the golden file"
}

test_default_budget_bounds_a_long_thread() {
  local dir size
  dir=$(make_home long old-l2 ship t3code thread-long)
  t3_fake_case "$TMP_ROOT/cases/long"
  t3_fake_credential "$dir/home/config/t3code-token"
  seed_thread thread-long 400 2000
  compose "$dir" old-l2
  expect_code 0 "$RC" "compose: $ERR"
  size=$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')
  [ "$size" -le 48000 ] || fail "the document is $size bytes, past the default 12000-token budget"
  [ "$size" -ge 40000 ] || fail "the document is $size bytes; the tail should fill most of the default budget"
  assert_contains "$OUT" "Launch brief for the old worker." "the first user message survives a long thread"
  assert_contains "$OUT" "Firstmate is handing this task off." "the last user message survives a long thread"
  assert_contains "$OUT" "Committed, pushed, and wrote my notes." "the last assistant message survives a long thread"
  assert_contains "$OUT" "message 400: " "the newest messages fill the rest"
  assert_not_contains "$OUT" "message 1: " "old middle messages are left out"
  pass "the default budget bounds the whole document while keeping the anchor messages of a long thread"
}

test_document_without_a_transcript_tail() {
  local dir
  dir=$(make_home plain old-p2 ship tmux)
  compose "$dir" old-p2
  expect_code 0 "$RC" "compose without T3: $ERR"
  assert_not_contains "$OUT" "## Transcript tail" "a task with no T3 thread has no transcript section"
  assert_contains "$OUT" "## Carried commits" "a ship without T3 still gets its commit summary"
  assert_contains "$OUT" "wip: hand-off" "the commit summary lists the carried commits"

  dir=$(make_home scout old-s2 scout)
  compose "$dir" old-s2
  expect_code 0 "$RC" "compose for a scout: $ERR"
  assert_not_contains "$OUT" "## Carried commits" "a scout carries no commits"
  assert_contains "$OUT" "The previous interim report is" "a scout's document points at its interim report"
  assert_contains "$OUT" "Ship the widget for old-s2." "a scout's document carries the intent verbatim"

  dir=$(make_home failed old-f2 ship t3code thread-missing)
  t3_fake_case "$TMP_ROOT/cases/failed"
  t3_fake_credential "$dir/home/config/t3code-token"
  compose "$dir" old-f2
  expect_code 0 "$RC" "a failed transcript read does not block the hand-off: $ERR"
  assert_contains "$OUT" "Unavailable: reading T3 thread thread-missing failed" "the document says the tail is unavailable"
  assert_contains "$ERR" "warning: no transcript tail for old-f2" "a failed read warns on stderr"

  rm "$dir/home/data/old-f2/handoff-notes.md"
  compose "$dir" old-f2
  expect_code 1 "$RC" "missing notes must refuse"
  assert_contains "$ERR" "no nonempty notes" "missing notes are named"
  pass "the document leaves out the tail with no T3 thread, has no commits for a scout, and notes a failed read"
}

# The public document's byte limit comes from the handoff contract, not
# token estimation; oversized optional material must never clip the brief.
test_budget_sacrifices_optional_material() {
  local dir size
  dir=$(make_home oversized old-b2 ship t3code thread-budget)
  t3_fake_case "$TMP_ROOT/cases/budget"
  t3_fake_credential "$dir/home/config/t3code-token"
  seed_thread thread-budget 2 30
  node -e 'process.stdout.write("worker-note-".repeat(5000))' > "$dir/home/data/old-b2/handoff-notes.md"
  compose "$dir" old-b2
  expect_code 0 "$RC" "oversized notes: $ERR"
  size=$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')
  [ "$size" -le 48000 ] || fail "oversized notes breached budget: $size"
  assert_contains "$OUT" "Notes cut to fit; full notes: $dir/home/data/old-b2/handoff-notes.md" "cut notes link to the durable original"
  assert_contains "$OUT" "Ship the widget for old-b2." "intent survives intact"
  assert_contains "$OUT" '- Out of scope: the gadget.' "spec survives intact"
  assert_contains "$OUT" 'details omitted' "git detail yields before notes"
  assert_not_contains "$OUT" 'step 12' "status yields before notes"
  assert_not_contains "$OUT" '## Transcript tail' "transcript yields before notes"
  [ "$(wc -c < "$dir/home/data/old-b2/handoff-notes.md" | tr -d ' ')" -eq 60000 ] || fail "original notes changed"

  compose "$dir" old-b2 --budget-tokens 100
  expect_code 1 "$RC" "mandatory material cannot fit"
  [ -z "$OUT" ] || fail "refusal printed a partial document"
  assert_contains "$ERR" 'mandatory intent/spec and headings require' "refusal names mandatory size"
  assert_contains "$ERR" '--budget-tokens 100 allows 400 bytes' "refusal names budget and flag"
  pass "oversized optional material yields; oversized mandatory material refuses"
}

test_small_tail_budget() {
  local dir size tokens
  dir=$(make_home small old-t2 scout)
  compose "$dir" old-t2
  expect_code 0 "$RC" "baseline: $ERR"
  size=$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')
  tokens=$(((size + 900 + 3) / 4))
  printf 'backend=t3code\nt3_thread_id=thread-small\n' >> "$dir/home/state/old-t2.meta"
  t3_fake_case "$TMP_ROOT/cases/small"
  t3_fake_credential "$dir/home/config/t3code-token"
  seed_thread thread-small 0 0
  compose "$dir" old-t2 --budget-tokens "$tokens"
  expect_code 0 "$RC" "small tail: $ERR"
  [ "$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')" -le "$((tokens * 4))" ] || fail "small tail exceeds budget"
  assert_contains "$OUT" 'Firstmate is handing this task off.' "short anchors fit below 1024 bytes"
  assert_contains "$OUT" 'Committed, pushed, and wrote my notes.' "assistant anchor fits below 1024 bytes"
  pass "small remaining budgets still carry fitting transcript anchors"
}

test_fences_and_failure_notices_are_budgeted() {
  local dir
  dir=$(make_home fences old-c2 scout t3code thread-fences)
  t3_fake_case "$TMP_ROOT/cases/fences"
  t3_fake_credential "$dir/home/config/t3code-token"
  FM_T3_THREAD=thread-fences t3_fake_set '
w.threads = { "thread-fences": { threadId: "thread-fences", projectId: "p", status: "idle", activeRunId: null, archived: false,
  worktreePath: "/wt", pendingRequestCount: 0, parentThreadId: null, relationshipToParent: null,
  items: [{ type: "user_message", status: "completed", text: "`".repeat(3000) }], runs: [] } };'
  compose "$dir" old-c2 --budget-tokens 1500
  expect_code 0 "$RC" "long transcript fence: $ERR"
  [ "$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')" -le 6000 ] || fail "transcript fences breached budget"
  printf 't3_thread_id=missing-%s\n' "$(node -e 'process.stdout.write("x".repeat(7000))')" >> "$dir/home/state/old-c2.meta"
  compose "$dir" old-c2 --budget-tokens 1500
  expect_code 0 "$RC" "failed transcript: $ERR"
  [ "$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')" -le 6000 ] || fail "failure notice breached budget"
  pass "dynamic fences and transcript failure notices cannot breach the document budget"
}

t3_fake_start "$TMP_ROOT/server"
fm_test_run \
  test_ship_document_matches_golden_file \
  test_default_budget_bounds_a_long_thread \
  test_document_without_a_transcript_tail \
  test_budget_sacrifices_optional_material \
  test_small_tail_budget \
  test_fences_and_failure_notices_are_budgeted
