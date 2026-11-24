#!/usr/bin/env bash
# tests/fm-host-bootstrap.test.sh - behavioral tests for bin/fm-host-bootstrap.sh
# covering check mode, --fix idempotent installation and entrypoint linking,
# human-only sign-in reporting (Apple/macOS, GitHub, Claude, Antigravity, T3),
# refusal to overwrite non-Firstmate entrypoint files, and safe --ssh forwarding.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-host-bootstrap)
BOOTSTRAP="$ROOT/bin/fm-host-bootstrap.sh"

# Build an isolated fake root with stubbed fm-bootstrap.sh, fm-remote-doctor.sh,
# and fm-t3-mcp.mjs so the test never runs real package installs or modifies
# the test runner's own HOME or launchd state.
FIX_ROOT="$TMP_ROOT/fm-root"
mkdir -p "$FIX_ROOT/bin"
cp "$BOOTSTRAP" "$FIX_ROOT/bin/fm-host-bootstrap.sh"
cp "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-remote-job-lib.sh" "$FIX_ROOT/bin/"
printf 'fixture\n' > "$FIX_ROOT/AGENTS.md"
cat > "$FIX_ROOT/bin/fm-remote-entrypoint.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH

INSTALL_LOG="$TMP_ROOT/install.log"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
: > "$INSTALL_LOG"
: > "$DOCTOR_LOG"

cat > "$FIX_ROOT/bin/fm-bootstrap.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = install ]; then
  shift
  for t in "\$@"; do
    printf '%s\n' "\$t" >> "$INSTALL_LOG"
    : > "$TMP_ROOT/installed-\$t"
  done
  exit 0
fi
if [ ! -f "$TMP_ROOT/installed-tasks-axi" ]; then
  echo "MISSING: tasks-axi (install: npm install -g tasks-axi)"
fi
if [ ! -f "$TMP_ROOT/installed-jq" ]; then
  echo "MISSING: jq (install: brew install jq  # or the platform's package manager)"
fi
exit 0
SH

cat > "$FIX_ROOT/bin/fm-remote-doctor.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DOCTOR_LOG"
for arg in "\$@"; do
  [ "\$arg" = --fix ] && : > "$TMP_ROOT/doctor-fixed"
done
if [ -f "$TMP_ROOT/doctor-fixed" ]; then
  echo "check remote-job-worker=ok: running"
  exit 0
fi
echo "check remote-job-worker=fixable: worker not loaded"
echo "action: remote-job-worker: rerun with --fix"
exit 1
SH

cat > "$FIX_ROOT/bin/fm-t3-mcp.mjs" <<'JS'
console.log(JSON.stringify({ daysLeft: 28, expiresAt: "2026-12-20T00:00:00Z" }));
JS
chmod +x "$FIX_ROOT/bin/"*.sh

FAKE_HOME="$TMP_ROOT/home"
FM_HOME_DIR="$TMP_ROOT/fm-home"
FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_HOME" "$FM_HOME_DIR/config" "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_GH_OK:-0}" = 1 ]
SH
cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKE_BIN/agy" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKE_BIN/node" <<'SH'
#!/usr/bin/env bash
printf '{"daysLeft":28,"expiresAt":"2026-12-20T00:00:00Z"}\n'
SH
cat > "$FAKE_BIN/jq" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKE_BIN/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKE_BIN/launchctl" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_GUI_OK:-0}" = 1 ]
SH
chmod +x "$FAKE_BIN/"*

run_boot() {
  HOME="$FAKE_HOME" \
  FM_HOME="$FM_HOME_DIR" \
  FM_ROOT_OVERRIDE="$FIX_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE="${FM_TEST_PLAT:-Darwin}" \
  PATH="$FAKE_BIN:/usr/bin:/bin" \
  "$FIX_ROOT/bin/fm-host-bootstrap.sh" "$@"
}

# 1. Read-only check mode reports automatable gaps + all human sign-ins without mutating.
rc=0
out=$(run_boot --role both --backend tmux 2>&1) || rc=$?
expect_code 1 "$rc" "check mode with gaps must exit 1"
assert_contains "$out" "mode=check" "must report check mode"
assert_contains "$out" "check tool:tasks-axi=fixable:" "missing automatable tool must be fixable"
assert_contains "$out" "check remote-entrypoint=fixable:" "missing entrypoint symlink must be fixable"
assert_contains "$out" "check remote-account=fixable:" "doctor gap must be fixable"
assert_contains "$out" "check signin-apple-macos=human:" "missing Aqua GUI session must be human"
assert_contains "$out" "check signin-github=human:" "unauthenticated gh must be human"
assert_contains "$out" "check signin-claude=human:" "claude /login must be listed as human"
assert_contains "$out" "check signin-antigravity=human:" "antigravity login must be listed as human"
assert_contains "$out" "check signin-t3code=human:" "missing t3code token must be human"
[ ! -s "$INSTALL_LOG" ] || fail "check mode must never install packages"
[ ! -e "$FAKE_HOME/.local/bin/fm-remote-entrypoint.sh" ] || fail "check mode must not create entrypoint symlink"
pass "check mode is read-only and lists automatable gaps plus all human sign-ins"

# 2. --fix installs missing tools, creates entrypoint symlink, and runs fm-remote-doctor.sh --fix; idempotent on rerun.
rc=0
out=$(FM_TEST_GH_OK=1 FM_TEST_GUI_OK=1 run_boot --fix --role both --backend tmux 2>&1) || rc=$?
# Claude and Antigravity interactive sign-ins remain human steps, so exit is still 1.
expect_code 1 "$rc" "interactive human sign-ins keep exit 1 until completed"
assert_contains "$out" "fix tool:tasks-axi=applied:" "--fix must install missing automatable tool"
assert_contains "$out" "fix remote-entrypoint=applied:" "--fix must create entrypoint symlink"
assert_contains "$out" "fix remote-account=applied:" "--fix must run fm-remote-doctor.sh --fix"
assert_contains "$out" "check remote-entrypoint=ok:" "post-fix recheck must show entrypoint ok"
assert_contains "$out" "check remote-account=ok:" "post-fix recheck must show remote-account ok"
assert_contains "$out" "check signin-github=ok:" "authenticated gh must show ok"
assert_contains "$out" "check signin-apple-macos=ok:" "active Aqua session must show ok"
[ "$(readlink "$FAKE_HOME/.local/bin/fm-remote-entrypoint.sh")" = "$FIX_ROOT/bin/fm-remote-entrypoint.sh" ] \
  || fail "entrypoint symlink must point to the code root entrypoint"

# Rerun --fix: no duplicate installs, same clean state.
install_count_before=$(wc -l < "$INSTALL_LOG" | tr -d ' ')
FM_TEST_GH_OK=1 FM_TEST_GUI_OK=1 run_boot --fix --role both --backend tmux >/dev/null 2>&1 || true
install_count_after=$(wc -l < "$INSTALL_LOG" | tr -d ' ')
assert_equals "$install_count_before" "$install_count_after" "rerunning --fix must not reinstall already-present tools"
pass "--fix installs tools, links entrypoint, delegates doctor, and is idempotent"

# 3. Never overwrites a non-Firstmate file at ~/.local/bin/fm-remote-entrypoint.sh.
rm -f "$FAKE_HOME/.local/bin/fm-remote-entrypoint.sh"
printf 'user-custom-file\n' > "$FAKE_HOME/.local/bin/fm-remote-entrypoint.sh"
out=$(FM_TEST_GH_OK=1 FM_TEST_GUI_OK=1 run_boot --fix --role worker --backend tmux 2>&1 || true)
assert_contains "$out" "check remote-entrypoint=human:" "non-Firstmate file at entrypoint path must be reported as human"
assert_equals "user-custom-file" "$(cat "$FAKE_HOME/.local/bin/fm-remote-entrypoint.sh")" "non-Firstmate file must never be overwritten"
pass "refuses to overwrite a non-Firstmate file at ~/.local/bin/fm-remote-entrypoint.sh"

# 4. --ssh mode forwards safely with agent forwarding disabled and refuses unsafe paths.
SSH_LOG="$TMP_ROOT/ssh.log"
cat > "$FAKE_BIN/fake-ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$SSH_LOG"
exit 0
SH
chmod +x "$FAKE_BIN/fake-ssh"
FM_SSH_BIN="$FAKE_BIN/fake-ssh" "$BOOTSTRAP" --ssh studio2 --remote-root /Users/op/firstmate --fix --role worker --backend herdr
assert_contains "$(cat "$SSH_LOG")" "ForwardAgent=no" "--ssh must disable agent forwarding"
assert_contains "$(cat "$SSH_LOG")" "ClearAllForwardings=yes" "--ssh must clear all forwardings"
assert_contains "$(cat "$SSH_LOG")" "-- studio2 /Users/op/firstmate/bin/fm-host-bootstrap.sh --role worker --fix --backend herdr" \
  "--ssh must invoke the remote root's bootstrap with exact validated arguments"

rc=0
FM_SSH_BIN="$FAKE_BIN/fake-ssh" "$BOOTSTRAP" --ssh studio2 --remote-root relative/path >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" "relative --remote-root must be refused"
rc=0
# shellcheck disable=SC2016 # Literal shell metacharacters are the injection probe.
FM_SSH_BIN="$FAKE_BIN/fake-ssh" "$BOOTSTRAP" --ssh studio2 --remote-root '/tmp/$(bad)' >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" "shell metacharacters in --remote-root must be refused"
pass "--ssh mode forwards safely and rejects unsafe remote roots"

echo "ALL TESTS PASSED"
