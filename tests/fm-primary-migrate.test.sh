#!/usr/bin/env bash
# tests/fm-primary-migrate.test.sh - behavioral tests for guarded primary
# Firstmate home migration (bin/fm-primary-migrate.sh preflight/export/import).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-primary-migrate)
MIGRATE="$ROOT/bin/fm-primary-migrate.sh"
LEASE="$ROOT/bin/fm-supervisor-lease.sh"

SRC="$TMP_ROOT/src-home"
DST="$TMP_ROOT/dst-home"
BUNDLE="$TMP_ROOT/bundle"
mkdir -p "$SRC/data" "$SRC/state" "$SRC/config" "$SRC/projects" \
  "$DST/data" "$DST/state" "$DST/config" "$DST/projects"

printf 'old-mac\n' > "$SRC/config/machine-id"
printf 'studio1\n' > "$DST/config/machine-id"
printf 'claude\n' > "$SRC/config/crew-harness"
printf 'auto\n' > "$SRC/config/lane-capacity"
printf '{"token":"secret-old-host"}\n' > "$SRC/config/t3code-token"
printf 'FMX_PAIRING_TOKEN=secret\n' > "$SRC/.env"
printf '# Backlog\n\n## Queued\n- [ ] task-a\n' > "$SRC/data/backlog.md"
printf '# Captain\n- prefers concise summaries\n' > "$SRC/data/captain.md"

# Create one remote-backed project and one local-only project.
git init -q --bare "$TMP_ROOT/origins/remote-app.git"
fm_git_init_commit "$TMP_ROOT/seed-remote-app"
git -C "$TMP_ROOT/seed-remote-app" remote add origin "$TMP_ROOT/origins/remote-app.git"
git -C "$TMP_ROOT/seed-remote-app" push -q origin HEAD:main
git --git-dir="$TMP_ROOT/origins/remote-app.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMP_ROOT/origins/remote-app.git" "$SRC/projects/remote-app"

fm_git_init_commit "$SRC/projects/local-notes"
printf 'local commit two\n' > "$SRC/projects/local-notes/note.txt"
git -C "$SRC/projects/local-notes" add note.txt
git -C "$SRC/projects/local-notes" -c user.name='Test' -c user.email='test@example.invalid' commit -qm 'local only commit'
LOCAL_EXPECTED_HEAD=$(git -C "$SRC/projects/local-notes" rev-parse HEAD)
# An unmerged second branch and a tag must survive the bundle round trip too.
git -C "$SRC/projects/local-notes" checkout -qb feature-x
printf 'feature work\n' > "$SRC/projects/local-notes/feature.txt"
git -C "$SRC/projects/local-notes" add feature.txt
git -C "$SRC/projects/local-notes" -c user.name='Test' -c user.email='test@example.invalid' commit -qm 'unmerged feature'
git -C "$SRC/projects/local-notes" tag v-feature
LOCAL_FEATURE_HEAD=$(git -C "$SRC/projects/local-notes" rev-parse HEAD)
git -C "$SRC/projects/local-notes" checkout -q -

cat > "$SRC/data/projects.md" <<'EOF'
- remote-app [direct-PR] - remote app (added 2026-11-01)
- local-notes [local-only] - local notes (added 2026-11-02)
EOF
cat > "$SRC/data/secondmates.md" <<'EOF'
- shuk - shuk domain (host: laptop; root: /Users/op/firstmate; home: /Users/op/shuk; scope: shuk; projects: remote-app; added 2026-11-01)
EOF
cat > "$SRC/data/worker-hosts.md" <<'EOF'
- studio2 - equal worker host (host: studio2-ssh; root: /Users/op/firstmate; home: /Users/op/fm-worker; added 2026-11-24)
EOF
# Remote secondmate record is allowed during migration.
fm_write_meta "$SRC/state/shuk.meta" \
  "kind=secondmate" "remote_host=laptop" "remote_root=/Users/op/firstmate" "remote_home=/Users/op/shuk"

# 1. Preflight refuses in-flight local task, dirty project, unpushed commit, and active away record.
fm_write_meta "$SRC/state/in-flight.meta" "kind=ship" "mode=direct-PR"
touch "$SRC/state/.afk-contract"
printf 'uncommitted\n' >> "$SRC/projects/remote-app/README.md"

rc=0
out=$(FM_HOME="$SRC" "$MIGRATE" preflight 2>&1) || rc=$?
expect_code 1 "$rc" "preflight must refuse active task, away record, and dirty clone"
assert_contains "$out" "blocker: away or quiet supervision posture is active" "must flag active away record"
assert_contains "$out" "blocker: local ship task 'in-flight' is still in flight" "must flag in-flight local ship"
assert_contains "$out" "blocker: projects/remote-app has uncommitted or untracked changes" "must flag dirty clone"
assert_contains "$out" "migrate: remote_secondmates=shuk" "remote secondmate must be allowed and listed"

# Commit locally without pushing -> must still refuse unpushed commits on remote-backed project.
rm -f "$SRC/state/in-flight.meta" "$SRC/state/.afk-contract"
git -C "$SRC/projects/remote-app" add -A
git -C "$SRC/projects/remote-app" -c user.name='Test' -c user.email='test@example.invalid' commit -qm 'unpushed local work'
rc=0
out=$(FM_HOME="$SRC" "$MIGRATE" preflight 2>&1) || rc=$?
expect_code 1 "$rc" "preflight must refuse unpushed commits on remote-backed project"
assert_contains "$out" "blocker: projects/remote-app (direct-PR) has unpushed local commits" "must refuse unpushed commits"

# Pushing only to a local no-mistakes gate is not pushing to origin -> still refused.
git init -q --bare "$TMP_ROOT/gates/remote-app.git"
git -C "$SRC/projects/remote-app" remote add no-mistakes "$TMP_ROOT/gates/remote-app.git"
git -C "$SRC/projects/remote-app" push -q no-mistakes HEAD:refs/heads/fm/gated
git -C "$SRC/projects/remote-app" fetch -q no-mistakes
rc=0
out=$(FM_HOME="$SRC" "$MIGRATE" preflight 2>&1) || rc=$?
expect_code 1 "$rc" "preflight must refuse commits that reached only the local gate, not origin"
assert_contains "$out" "blocker: projects/remote-app (direct-PR) has unpushed local commits" "gate-only commits must count as unpushed"

# Push the commit -> preflight now passes.
git -C "$SRC/projects/remote-app" push -q origin HEAD:main
git -C "$SRC/projects/remote-app" fetch -q origin
out=$(FM_HOME="$SRC" "$MIGRATE" preflight 2>&1)
assert_contains "$out" "ok: preflight passed" "clean home must pass preflight"
assert_contains "$out" "migrate: local_bundle_projects=local-notes" "local-only project must be queued for bundle"
assert_contains "$out" "migrate: remote_clone_projects=remote-app" "remote project must be recorded for re-clone"
pass "preflight refuses unlanded work and passes when clean"

# 2. Supervisor lease: export refuses while lease is still held by source machine, passes after release.
git init -q --bare "$TMP_ROOT/records-origin.git"
git -C "$SRC/data" init -q -b main
git -C "$SRC/data" remote add origin "$TMP_ROOT/records-origin.git"
git -C "$SRC/data" add -A
git -C "$SRC/data" -c user.name='Test' -c user.email='test@example.invalid' commit -qm 'initial records'
git -C "$SRC/data" push -q -u origin main
FM_HOME="$SRC" "$LEASE" acquire >/dev/null

rc=0
out=$(FM_HOME="$SRC" "$MIGRATE" export "$BUNDLE" 2>&1) || rc=$?
expect_code 1 "$rc" "export must refuse while supervisor lease is still held"
assert_contains "$out" "supervisor lease is still held by 'old-mac'" "must tell operator to release lease first"
[ ! -e "$BUNDLE" ] || fail "refused export must leave no bundle behind"

FM_HOME="$SRC" "$LEASE" release >/dev/null
out=$(FM_HOME="$SRC" "$MIGRATE" export "$BUNDLE" 2>&1)
assert_contains "$out" "ok: exported primary migration bundle" "export must succeed after lease release"
[ -f "$BUNDLE/manifest.json" ] || fail "manifest.json missing"
[ -f "$BUNDLE/config/crew-harness" ] || fail "portable config must be exported"
[ ! -e "$BUNDLE/config/t3code-token" ] || fail "t3code-token must never be exported"
[ ! -e "$BUNDLE/config/machine-id" ] || fail "machine-id must never be exported"
[ ! -e "$BUNDLE/config/lane-capacity" ] || fail "lane-capacity must never be exported"
[ ! -e "$BUNDLE/.env" ] || fail ".env must never be exported"
[ -f "$BUNDLE/local-projects/local-notes.bundle" ] || fail "local-only project bundle must be created"
pass "export gates on supervisor-lease release, excludes machine-bound/secret files, and bundles local-only projects"

# 3. Import refuses same machine-id, then succeeds with distinct machine-id and restores all data + local-only commits.
printf 'old-mac\n' > "$DST/config/machine-id"
rc=0
out=$(FM_HOME="$DST" "$MIGRATE" import "$BUNDLE" 2>&1) || rc=$?
expect_code 1 "$rc" "import must refuse when destination machine-id matches source"
assert_contains "$out" "matches source machine" "refusal must explain machine-id collision"

printf 'studio1\n' > "$DST/config/machine-id"
out=$(FM_HOME="$DST" "$MIGRATE" import "$BUNDLE" --clone-projects 2>&1)
assert_contains "$out" "ok: imported primary migration bundle from old-mac" "import must succeed"
assert_contains "$out" "transfer .env securely" "checklist must remind about .env"
assert_contains "$out" "re-attach remote secondmate shuk" "checklist must name remote secondmate re-attach"
assert_contains "$out" "verify worker host studio2" "checklist must name worker host verification"
[ -f "$DST/data/backlog.md" ] && [ -f "$DST/data/captain.md" ] || fail "data/ records must be restored"
[ -f "$DST/config/crew-harness" ] || fail "portable config must be restored"
[ ! -e "$DST/config/t3code-token" ] || fail "t3code-token must not appear in destination"
assert_equals "$LOCAL_EXPECTED_HEAD" "$(git -C "$DST/projects/local-notes" rev-parse HEAD)" \
  "local-only project must keep exact commit history"
assert_equals "$LOCAL_FEATURE_HEAD" "$(git -C "$DST/projects/local-notes" rev-parse --verify -q refs/heads/feature-x)" \
  "an unmerged local branch must survive restore as a local branch"
assert_equals "$LOCAL_FEATURE_HEAD" "$(git -C "$DST/projects/local-notes" rev-parse --verify -q 'refs/tags/v-feature^{commit}')" \
  "a local tag must survive restore"
assert_equals "" "$(git -C "$DST/projects/local-notes" remote)" "a restored local-only project must have no remote"
assert_equals "$(git -C "$SRC/projects/remote-app" rev-parse HEAD)" "$(git -C "$DST/projects/remote-app" rev-parse HEAD)" \
  "remote project must clone cleanly from origin"

# Second import into now-populated destination must refuse.
rc=0
out=$(FM_HOME="$DST" "$MIGRATE" import "$BUNDLE" 2>&1) || rc=$?
expect_code 1 "$rc" "import into already-populated home must refuse"
assert_contains "$out" "already exists and is non-empty" "refusal must explain populated destination"
pass "import enforces destination safety, restores data/config/projects, and prints operator checklist"

# 4. A records repository cloned into data/ before import (the documented flow) is kept, not refused.
DST2="$TMP_ROOT/dst2-home"
mkdir -p "$DST2/state" "$DST2/config" "$DST2/projects"
printf 'studio1\n' > "$DST2/config/machine-id"
git clone -q -b main "$TMP_ROOT/records-origin.git" "$DST2/data"
[ -s "$DST2/data/backlog.md" ] || fail "fixture: cloned records repo must carry a non-empty backlog"
out=$(FM_HOME="$DST2" "$MIGRATE" import "$BUNDLE" 2>&1)
assert_contains "$out" "keeping it intact" "a pre-cloned records repository must be kept"
assert_contains "$out" "ok: imported primary migration bundle from old-mac" "import into a pre-cloned records repo must succeed"
assert_equals "$(git -C "$SRC/data" rev-parse HEAD)" "$(git -C "$DST2/data" rev-parse HEAD)" "the records clone must be untouched"

# A records clone that lacks the exported records commit is refused.
DST3="$TMP_ROOT/dst3-home"
mkdir -p "$DST3/state" "$DST3/config" "$DST3/projects"
printf 'studio1\n' > "$DST3/config/machine-id"
fm_git_init_commit "$DST3/data"
rc=0
out=$(FM_HOME="$DST3" "$MIGRATE" import "$BUNDLE" 2>&1) || rc=$?
expect_code 1 "$rc" "a records clone missing the exported head must be refused"
assert_contains "$out" "does not contain source records commit" "refusal must name the missing records commit"
[ ! -e "$DST3/projects/local-notes" ] || fail "a refused import must not restore projects"
pass "import keeps a pre-cloned records repository that contains the exported records head"

echo "ALL TESTS PASSED"
