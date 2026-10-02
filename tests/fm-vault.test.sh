#!/usr/bin/env bash
# Behavior tests for bin/fm-vault.sh: the opt-in Obsidian vault export.
# Every case runs against a temp firstmate home and a temp vault; nothing here
# reads or writes a real vault or a real home's config.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-vault)
VAULT_SH="$ROOT/bin/fm-vault.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export FM_VAULT_TODAY=2026-10-02

# A fake tasks-axi that serves `show <id> --full` from $FM_HOME/fake-show/<id>.
cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = show ] || exit 1
f="$PWD/fake-show/$2"
[ -f "$f" ] || { echo "error: not found"; exit 1; }
cat "$f"
SH
chmod +x "$FAKEBIN/tasks-axi"
export PATH="$FAKEBIN:$PATH"

# new_case <name>: fresh home + vault (with a space in its path); sets HOME_DIR, VAULT.
new_case() {
  HOME_DIR="$TMP_ROOT/$1/home"
  VAULT="$TMP_ROOT/$1/My Vault"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/fake-show" "$VAULT"
  printf '%s\n' "$VAULT" > "$HOME_DIR/config/obsidian-vault"
}

vault() {
  FM_HOME="$HOME_DIR" "$VAULT_SH" "$@"
}

# seed_ship_task <id>: meta, brief, status, backlog record, and narrative.
seed_ship_task() {
  local id=$1 repo="$TMP_ROOT/repo-$1"
  mkdir -p "$repo/docs/adr" "$HOME_DIR/data/$id"
  printf '# ADR 7: Keep exports synchronous\n' > "$repo/docs/adr/0007-sync.md"
  printf 'agents\n' > "$repo/AGENTS.md"
  fm_write_meta "$HOME_DIR/state/$id.meta" kind=ship mode=no-mistakes harness=claude \
    model=claude-opus-5-5 "project=$repo" pr=https://github.com/o/r/pull/9 pr_head=deadbeef \
    decision_keys=scope,pending
  printf '# Task\nBuild the widget export. Token ghp_abcdefghijklmnopqrstuvwx.\n\n# Setup\nscaffold text\n' \
    > "$HOME_DIR/data/$id/brief.md"
  printf 'working: setup done\ndone: PR https://github.com/o/r/pull/9 checks green\n' > "$HOME_DIR/state/$id.status"
  cat > "$HOME_DIR/fake-show/$id" <<'EOF'
task:
  id: SEEDID
  title: "Add widget export https://github.com/o/r/pull/9"
  state: in-flight
  kind: ship
  repo: Org/Widget-App
  created: 2026-09-30
  closed: "-"
  links: "pr:https://github.com/o/r/pull/9"
  body: "Contact ops@example.com or +18664916158 about SID HHc9379a0c46ea5142e81ab7567cbe5678.\nSecond line \"quoted\"."
EOF
  cat > "$HOME_DIR/fake-show/$id-decision-scope" <<'EOF'
task:
  id: SEEDID-decision-scope
  title: "Widget: export scope"
  state: done
  kind: captain
  repo: Org/Widget-App
  closed: 2026-10-01
  hold_reason: "Recommend CSV only"
  body: "Resolution recorded by fm-decision-hold.\nDecision digest: abc\nRouted identities: (none)\nResolution mode: answer\n\nCaptain decision:\nDate: 2026-10-01\n\nCSV only for now.\n\nRouted work:\n(none)"
EOF
  "$VAULT_SH" template \
    | sed -e 's/<plain-language title of what changed>/Widget CSV export/' \
          -e 's/<resume keywords[^>]*>/TypeScript, Postgres/' \
          -e 's/<employer tag[^>]*>/personal/' \
          -e 's/<one sentence: the business situation, in plain language>/Staff exported widgets by hand./' \
    > "$HOME_DIR/data/$id/journal.md"
}

snapshot() {
  (cd "$VAULT" && find . -type f -print0 | sort -z | xargs -0 cksum)
}

test_off_by_default_is_silent() {
  local out rc
  new_case off
  rm -f "$HOME_DIR/config/obsidian-vault"
  out=$(printf 'kind=ship\n' | vault journal t1 --meta - 2>&1); rc=$?
  expect_code 0 "$rc" "journal with no config"
  [ -z "$out" ] || fail "unconfigured journal printed output: $out"
  out=$(vault index 2>&1); rc=$?
  expect_code 0 "$rc" "index with no config"
  [ -z "$out" ] || fail "unconfigured index printed output: $out"
  vault path >/dev/null 2>&1 && fail "path must exit 1 when the feature is off"
  printf 'off\n' > "$HOME_DIR/config/obsidian-vault"
  out=$(vault journal t1 2>&1); rc=$?
  expect_code 0 "$rc" "journal with config set to off"
  [ -z "$(ls -A "$VAULT")" ] || fail "an off vault was written"
  vault template | grep -Fq '## STAR summary' || fail "template must print without any config"
  pass "fm-vault: absent or off config is a silent no-op; template always prints"
}

test_journal_writes_linked_notes_from_records() {
  local out rc note dec
  new_case full
  seed_ship_task t1
  out=$(vault journal t1 2>&1); rc=$?
  expect_code 0 "$rc" "journal t1"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "journal must print one line, got: $out"
  assert_contains "$out" "Journal/Tasks/2026/2026-10-02-t1.md" "journal reports the note path"
  note="$VAULT/Journal/Tasks/2026/2026-10-02-t1.md"
  assert_present "$note" "task note written"
  assert_grep 'title: "Widget CSV export"' "$note" "narrative title wins"
  assert_grep 'project: widget-app' "$note" "project from backlog repo basename"
  assert_grep 'pr: "https://github.com/o/r/pull/9"' "$note" "pr from meta"
  assert_grep 'skills: [typescript, postgres]' "$note" "skills normalized"
  assert_grep 'tags: [task, project/widget-app, employer/personal, skill/typescript, skill/postgres]' "$note" "tags"
  assert_grep 'review: draft' "$note" "notes start as drafts"
  assert_grep 'narrative: incomplete' "$note" "a narrative with template placeholders left is marked incomplete"
  assert_grep 'Staff exported widgets by hand.' "$note" "narrative body copied"
  assert_no_grep 'Delete these comments' "$note" "template guidance comments stripped"
  assert_grep 'Build the widget export.' "$note" "the ask is quoted from the brief"
  assert_no_grep 'scaffold text' "$note" "only the brief Task section is quoted"
  assert_grep 'done: PR https://github.com/o/r/pull/9 checks green' "$note" "final status recorded"
  assert_grep '## Captain notes' "$note" "captain section present"
  dec="$VAULT/Journal/Decisions/2026-10-01-t1-decision-scope.md"
  assert_present "$dec" "resolved decision from decision_keys gets a note"
  assert_grep 'CSV only for now.' "$dec" "decision text recorded"
  assert_grep '[[Journal/Tasks/2026/2026-10-02-t1|Widget CSV export]]' "$dec" "decision links its origin note"
  assert_grep '[[Journal/Decisions/2026-10-01-t1-decision-scope|Widget: export scope]]' "$note" "task note links the decision"
  [ -z "$(find "$VAULT/Journal/Decisions" -name '*pending*')" ] || fail "an unresolved decision must not get a note"
  assert_grep '[ADR 7: Keep exports synchronous]' "$VAULT/Journal/Projects/widget-app.md" "hub links repo ADRs"
  assert_grep '2026-10-02 [[Journal/Tasks/2026/2026-10-02-t1|Widget CSV export]] - ship' "$VAULT/Journal/Projects/widget-app.md" "hub work log"
  assert_grep '2026-10-01 [[Journal/Decisions/2026-10-01-t1-decision-scope|Widget: export scope]] (active)' "$VAULT/Journal/Projects/widget-app.md" "hub decision list"
  assert_grep 'Widget CSV export' "$VAULT/Journal/Months/2026-10.md" "month index"
  assert_grep 'Widget CSV export' "$VAULT/Journal/Skills/postgres.md" "skill index"
  assert_present "$VAULT/Journal/README.md" "journal contract note"
  [ -z "$(find "$VAULT" -mindepth 1 -maxdepth 1 ! -name Journal)" ] || fail "writes escaped Journal/"
  pass "fm-vault: journal writes a linked task note, decision note, hub, month, and skill indexes"
}

test_redaction() {
  local note
  new_case redact
  seed_ship_task t1
  vault journal t1 >/dev/null 2>&1 || fail "journal for redaction case failed"
  note="$VAULT/Journal/Tasks/2026/2026-10-02-t1.md"
  assert_no_grep 'ops@example.com' "$note" "email redacted"
  assert_no_grep '18664916158' "$note" "phone redacted"
  assert_no_grep 'c9379a0c46ea5142e81ab7567cbe5678' "$note" "opaque id redacted"
  assert_no_grep 'ghp_abcdefghijklmnopqrstuvwx' "$note" "token redacted"
  assert_grep '[redacted-email]' "$note" "redaction leaves a marker"
  assert_grep 'Second line "quoted".' "$note" "backlog note decoded"
  assert_grep 'pr: "https://github.com/o/r/pull/9"' "$note" "structured links are not redacted"
  pass "fm-vault: record text is redacted before it reaches the vault"
}

test_idempotent_and_captain_text_survives() {
  local before after note hub
  new_case idem
  seed_ship_task t1
  vault journal t1 >/dev/null 2>&1 || fail "first journal failed"
  note="$VAULT/Journal/Tasks/2026/2026-10-02-t1.md"
  hub="$VAULT/Journal/Projects/widget-app.md"
  printf 'My interview angle.\n' >> "$note"
  sed -i.bak 's/^Captain-written description goes here.*/The widget app is our export tool./' "$hub" && rm -f "$hub.bak"
  printf '\nCaptain footer.\n' >> "$hub"
  before=$(snapshot)
  vault journal t1 >/dev/null 2>&1 || fail "second journal failed"
  vault index >/dev/null 2>&1 || fail "index failed"
  after=$(snapshot)
  [ "$before" = "$after" ] || fail "rerun changed vault bytes"$'\n'"$before"$'\n---\n'"$after"
  assert_grep 'My interview angle.' "$note" "captain notes preserved"
  assert_grep 'The widget app is our export tool.' "$hub" "hub prose preserved"
  assert_grep 'Captain footer.' "$hub" "hub footer preserved"
  [ "$(find "$VAULT/Journal/Tasks" -name '*.md' | wc -l | tr -d ' ')" = 1 ] || fail "rerun duplicated the task note"
  [ -z "$(find "$VAULT" -name '.fm-vault.*')" ] || fail "temp files left behind"
  pass "fm-vault: reruns are byte-identical and keep captain-written text"
}

test_missing_inputs_and_rerun_without_meta() {
  local note out rc
  new_case sparse
  out=$(vault journal bare-task 2>&1); rc=$?
  expect_code 0 "$rc" "journal with no records at all"
  note="$VAULT/Journal/Tasks/2026/2026-10-02-bare-task.md"
  assert_grep 'title: "bare-task"' "$note" "title falls back to the id"
  assert_grep 'narrative: missing' "$note" "missing narrative is marked"
  assert_grep 'No task narrative was captured.' "$note" "missing narrative is explained"
  assert_grep 'pr: "none"' "$note" "no pr recorded"

  printf 'task:\n  id: linked\n  title: "Linked task"\n  repo: alpha\n  closed: 2026-09-29\n  links: "report:x, pr:https://github.com/o/r/pull/12"\n' \
    > "$HOME_DIR/fake-show/linked"
  vault journal linked >/dev/null 2>&1 || fail "journal from backlog links failed"
  note="$VAULT/Journal/Tasks/2026/2026-09-29-linked.md"
  assert_grep 'pr: "https://github.com/o/r/pull/12"' "$note" "pr from backlog links when meta has none"

  new_case keep
  seed_ship_task t2
  vault journal t2 --meta - < "$HOME_DIR/state/t2.meta" >/dev/null 2>&1 || fail "journal from stdin meta failed"
  rm -f "$HOME_DIR/state/t2.meta"
  vault journal t2 >/dev/null 2>&1 || fail "rerun without meta failed"
  note="$VAULT/Journal/Tasks/2026/2026-10-02-t2.md"
  assert_grep 'pr_head: "deadbeef"' "$note" "pr_head kept from the earlier note"
  assert_grep 'mode: no-mistakes' "$note" "mode kept from the earlier note"
  assert_grep 'worker: "claude claude-opus-5-5"' "$note" "worker kept from the earlier note"
  pass "fm-vault: missing inputs degrade gracefully and reruns never blank recorded values"
}

test_filled_narrative_is_marked_captured() {
  local note
  new_case filled
  mkdir -p "$HOME_DIR/data/f1"
  printf -- '---\ntitle: Faster exports\nskills: [bash]\n---\n## STAR summary\n- **Situation:** Exports were slow.\n' \
    > "$HOME_DIR/data/f1/journal.md"
  vault journal f1 >/dev/null 2>&1 || fail "journal for filled narrative failed"
  note="$VAULT/Journal/Tasks/2026/2026-10-02-f1.md"
  assert_grep 'narrative: captured' "$note" "a filled narrative is marked captured"
  assert_grep 'Exports were slow.' "$note" "filled narrative copied"
  pass "fm-vault: narrative state distinguishes captured from incomplete"
}

test_captain_reviewed_note_is_never_rewritten() {
  local note before
  new_case reviewed
  seed_ship_task t1
  vault journal t1 >/dev/null 2>&1 || fail "journal failed"
  note="$VAULT/Journal/Tasks/2026/2026-10-02-t1.md"
  sed -i.bak 's/^review: draft$/review: captain-reviewed/; s/^# Widget CSV export$/# Widget CSV export, edited/' "$note" && rm -f "$note.bak"
  before=$(cksum < "$note")
  printf 'title: Something else\n' > "$HOME_DIR/data/t1/journal.md"
  vault journal t1 >/dev/null 2>&1 || fail "journal on reviewed note failed"
  [ "$(cksum < "$note")" = "$before" ] || fail "captain-reviewed note was rewritten"
  pass "fm-vault: a captain-reviewed note is left alone"
}

test_scout_report_is_indexed_not_copied() {
  local inv
  new_case scout
  mkdir -p "$HOME_DIR/data/s1"
  printf '# Report\nSECRET-REPORT-BODY\n' > "$HOME_DIR/data/s1/report.md"
  fm_write_meta "$HOME_DIR/state/s1.meta" kind=scout harness=codex
  vault journal s1 >/dev/null 2>&1 || fail "scout journal failed"
  inv="$VAULT/Journal/Investigations.md"
  assert_grep "\`$HOME_DIR/data/s1/report.md\`" "$inv" "report path indexed"
  ! grep -rq 'SECRET-REPORT-BODY' "$VAULT" || fail "report body was copied into the vault"
  assert_grep '## Investigations' "$VAULT/Journal/Months/2026-10.md" "month has investigations"
  grep -A1 '## Investigations' "$VAULT/Journal/Months/2026-10.md" | grep -Fq 's1' || fail "scout listed under investigations"
  pass "fm-vault: scout reports are indexed by path and never copied"
}

test_decision_subcommand() {
  local out rc dfile note
  new_case decision
  dfile="$TMP_ROOT/decision.txt"
  printf 'Date: 2026-09-20\nShip the CSV first.\n' > "$dfile"
  out=$(vault decision orig-a fmt --decision-file "$dfile" 2>&1); rc=$?
  expect_code 0 "$rc" "decision with a decision file"
  note="$VAULT/Journal/Decisions/2026-09-20-orig-a-decision-fmt.md"
  assert_present "$note" "decision note dated from its Date line"
  assert_grep 'Ship the CSV first.' "$note" "decision text"
  out=$(vault decision orig-a open 2>&1); rc=$?
  expect_code 1 "$rc" "unresolved decision"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "unresolved decision must print one line: $out"
  assert_contains "$out" "no recorded captain decision" "unresolved decision reason"
  pass "fm-vault: decision records a dated note and skips unresolved holds with one line"
}

test_confinement_and_usage() {
  local out rc outside
  new_case confine
  out=$(vault journal ../escape 2>&1); rc=$?
  expect_code 2 "$rc" "traversal id is a usage error"
  out=$(vault decision ok ../bad 2>&1); rc=$?
  expect_code 2 "$rc" "traversal key is a usage error"
  outside="$TMP_ROOT/confine/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$VAULT/Journal"
  out=$(vault journal t1 2>&1); rc=$?
  expect_code 1 "$rc" "symlinked Journal refused"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "refusal must be one line: $out"
  assert_contains "$out" "symlinked" "symlink refusal reason"
  [ -z "$(ls -A "$outside")" ] || fail "write escaped through a symlinked Journal"
  rm -f "$VAULT/Journal"
  mkdir -p "$VAULT/Journal/Tasks/2026"
  ln -s "$outside/victim.md" "$VAULT/Journal/Tasks/2026/2026-10-02-t9.md"
  out=$(vault journal t9 2>&1); rc=$?
  expect_code 1 "$rc" "symlinked note refused"
  assert_absent "$outside/victim.md" "write followed a symlinked note"
  printf 'relative/vault\n' > "$HOME_DIR/config/obsidian-vault"
  out=$(vault journal t1 2>&1); rc=$?
  expect_code 1 "$rc" "relative vault path refused"
  printf '%s\n' "$TMP_ROOT/confine/missing" > "$HOME_DIR/config/obsidian-vault"
  out=$(vault journal t1 2>&1); rc=$?
  expect_code 1 "$rc" "missing vault refused"
  assert_contains "$out" "fm-vault:" "one-line fm-vault report"
  pass "fm-vault: writes are confined to the vault's Journal/ and bad input is refused"
}

test_unwritable_vault_fails_open() {
  local out rc
  if [ "$(id -u)" = 0 ]; then
    pass "fm-vault: unwritable vault case skipped under root (permissions are not enforced)"
    return 0
  fi
  new_case readonly
  chmod 555 "$VAULT"
  out=$(vault journal t1 2>&1); rc=$?
  chmod 755 "$VAULT"
  expect_code 1 "$rc" "unwritable vault"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "unwritable vault must print one line: $out"
  assert_contains "$out" "fm-vault:" "unwritable vault report"
  pass "fm-vault: an unwritable vault fails with exactly one line"
}

test_vault_git_is_opt_in() {
  local remote count
  fm_git_identity
  new_case git
  git -C "$VAULT" init -q
  printf 'captain\n' > "$VAULT/Me.md"
  git -C "$VAULT" add Me.md && git -C "$VAULT" commit -qm seed
  seed_ship_task t1
  vault journal t1 >/dev/null 2>&1 || fail "journal in git vault failed"
  count=$(git -C "$VAULT" rev-list --count HEAD)
  [ "$count" = 1 ] || fail "vault git was committed without opt-in"
  [ -z "$(git -C "$VAULT" diff --cached --name-only)" ] || fail "vault index was staged without opt-in"

  printf 'staged by captain\n' > "$VAULT/Draft.md"
  git -C "$VAULT" add Draft.md
  printf 'commit\n' > "$HOME_DIR/config/obsidian-vault-git"
  vault index >/dev/null 2>&1 || fail "index with commit opt-in failed"
  [ "$(git -C "$VAULT" rev-list --count HEAD)" = 2 ] || fail "commit opt-in made no commit"
  git -C "$VAULT" show --name-only --format= HEAD | grep -v '^Journal/' | grep -q . \
    && fail "vault commit included paths outside Journal/"
  git -C "$VAULT" diff --cached --name-only | grep -Fxq Draft.md || fail "captain's staged file was disturbed"

  remote="$TMP_ROOT/git/remote.git"
  git init -q --bare "$remote"
  git -C "$VAULT" remote add origin "$remote"
  git -C "$VAULT" push -q -u origin HEAD >/dev/null 2>&1 || fail "fixture push failed"
  printf 'push\n' > "$HOME_DIR/config/obsidian-vault-git"
  printf '\nmore narrative\n' >> "$HOME_DIR/data/t1/journal.md"
  vault journal t1 >/dev/null 2>&1 || fail "journal with push opt-in failed"
  [ "$(git -C "$remote" rev-parse HEAD)" = "$(git -C "$VAULT" rev-parse HEAD)" ] || fail "push opt-in did not push"
  pass "fm-vault: vault git is untouched by default; commit and push are opt-in and Journal-only"
}

test_off_by_default_is_silent
test_journal_writes_linked_notes_from_records
test_redaction
test_idempotent_and_captain_text_survives
test_missing_inputs_and_rerun_without_meta
test_filled_narrative_is_marked_captured
test_captain_reviewed_note_is_never_rewritten
test_scout_report_is_indexed_not_copied
test_decision_subcommand
test_confinement_and_usage
test_unwritable_vault_fails_open
test_vault_git_is_opt_in
