#!/usr/bin/env bash
# tests/fm-worker-host-seed-doctor.test.sh - seeding and checking a worker host
# home from the primary (docs/remote-workers.md "Prepare the worker host").
#
# The primary runs the real bin/fm-worker-host-seed.sh and
# bin/fm-worker-host-doctor.sh; their bin/fm-on.sh calls go through a fake ssh
# into the real fixed entrypoint and remote job worker, which run the real
# bin/fm-worker-host-home.sh against a worker host home on this machine. The
# account readiness probe (bin/fm-remote-doctor.sh) is answered by the fake ssh,
# because the real one would inspect and repair the runner's own account;
# tests/fm-remote-doctor.test.sh owns its behavior. The entrypoint resolves the
# account's real HOME, so the host's code root is a committed copy of this
# checkout whose bin/, first on every remote job's PATH, holds a fake
# no-mistakes: no fixture project is ever registered with the shared
# no-mistakes daemon.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found (the fake ssh decodes argv with it)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-worker-host-seed-doctor)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
HOST="$TMP_ROOT/hosts/m1"
REMOTE_ROOT="$TMP_ROOT/remote-root"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
NM_LOG="$TMP_ROOT/no-mistakes.log"
T3_PIDS=()
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$TMP_ROOT/hosts" "$REMOTE_ROOT"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
cleanup() {
  local pid
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" || true
  fi
  for pid in ${T3_PIDS[@]+"${T3_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_remove_tree "$TMP_ROOT"
}
trap cleanup EXIT

# The host's code root: this checkout's tracked tree as a real repository, plus
# a fake no-mistakes that records each init and adds the remote a real init
# adds. A guard refuses the run if any other no-mistakes would be reached.
(
  cd "$ROOT" || exit 1
  git ls-files -z | xargs -0 tar -cf -
) | (cd "$REMOTE_ROOT" && tar -xf -)
cat > "$REMOTE_ROOT/bin/no-mistakes" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$1" "\$(basename "\$PWD")" >> '$NM_LOG'
[ "\$1" = init ] || exit 0
git remote add no-mistakes "$TMP_ROOT/nm-gate.git"
SH
chmod +x "$REMOTE_ROOT/bin/no-mistakes"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" add -A
git -C "$REMOTE_ROOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'remote fixture root'
: > "$NM_LOG"
# Guard: a remote job resolves no-mistakes on the PATH the job library builds
# for this root and the real account home; only the fake may answer.
fm_remote_job_compose_operator_path "$(cd ~ && pwd -P)" >/dev/null
JOB_PATH=$(fm_remote_job_build_child_path "$REMOTE_ROOT")
[ "$(PATH="$JOB_PATH" command -v no-mistakes)" = "$REMOTE_ROOT/bin/no-mistakes" ] \
  || fail "a remote job would reach a real no-mistakes; refusing to run"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "${FM_FAKE_SSH_DOWN:-}" != 1 ] || exit 255
[ "$1" = m1-mac ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
command_name=$(perl -MMIME::Base64=decode_base64 -e 'my @a = split(/\0/, decode_base64($ARGV[0])); print $a[0]' "$4")
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf '%s\n' "${FM_FAKE_ACCOUNT:-ready}" >> "$FM_FAKE_ACCOUNT_LOG"
  case "${FM_FAKE_ACCOUNT:-ready}" in
    human)
      printf 'check gui-session=human: no Aqua login session exists for uid 501\n'
      printf 'action: gui-session: log that account in once at the console\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: gui-session\n' >&2
      exit 1
      ;;
  esac
  printf 'check remote-job-worker=ok: running\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

primary() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_FAKE_ACCOUNT_LOG="$TMP_ROOT/account.log" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$@"
}

run() { # <command...>: sets OUT and RC
  RC=0
  OUT=$(primary "$@" 2>&1) || RC=$?
}

# Three projects on the primary: a no-mistakes project it has cloned, a
# direct-PR Forgejo project it has not, and a local-only project.
for project in alpha beta gamma; do
  git init -q --bare "$TMP_ROOT/origins/$project.git"
  fm_git_init_commit "$TMP_ROOT/src-$project"
  git -C "$TMP_ROOT/src-$project" remote add origin "$TMP_ROOT/origins/$project.git"
  git -C "$TMP_ROOT/src-$project" push -q origin HEAD:main
  git --git-dir="$TMP_ROOT/origins/$project.git" symbolic-ref HEAD refs/heads/main
done
git init -q --bare "$TMP_ROOT/nm-gate.git"
git clone -q "$TMP_ROOT/origins/alpha.git" "$PARENT/projects/alpha"
ALPHA_LINE='- alpha [no-mistakes] - the alpha service (added 2026-11-01)'
BETA_LINE='- beta [direct-PR forge=forgejo] - the beta site (added 2026-11-02)'
cat > "$PARENT/data/projects.md" <<EOF
$ALPHA_LINE
$BETA_LINE
- gamma [local-only] - private notes (added 2026-11-03)
EOF
cat > "$PARENT/data/worker-hosts.md" <<EOF
Worker hosts for this primary.
- m1 - always-on M1 worker host (host: m1-mac; root: $REMOTE_ROOT; home: $HOST; added 2026-11-10)
- inroot - a host whose home sits inside its code root (host: m1-mac; root: $REMOTE_ROOT; home: $REMOTE_ROOT/inroot-home; added 2026-11-10)
EOF
BETA_ORIGIN="$TMP_ROOT/origins/beta.git"

# --- refusals before anything reaches the host ---------------------------------

run "$ROOT/bin/fm-worker-host-doctor.sh" mbp
expect_code 1 "$RC" "an unregistered host must be refused"
assert_contains "$OUT" "no worker host mbp" "the refusal does not name the missing record"
run "$ROOT/bin/fm-worker-host-seed.sh" m1 alpha
expect_code 1 "$RC" "a seed with no lane cap must be refused"
assert_contains "$OUT" "--lanes <cap> is required" "the refusal does not ask for the lane cap"
run "$ROOT/bin/fm-worker-host-seed.sh" m1 --lanes 2 gamma
expect_code 1 "$RC" "a local-only project must be refused"
assert_contains "$OUT" "local-only" "the refusal does not name the local-only posture"
assert_absent "$HOST" "a refused seed created the host home"
assert_absent "$TMP_ROOT/account.log" "a refused seed reached the host"
pass "unregistered hosts, a missing lane cap, and local-only projects are refused before any SSH"

# --- the doctor before any seed -------------------------------------------------

run "$ROOT/bin/fm-worker-host-doctor.sh" m1 alpha
expect_code 1 "$RC" "the doctor must fail on an unseeded host"
assert_contains "$OUT" "account: ok: remote second-mate readiness confirmed" "the account verdict was not relayed"
assert_contains "$OUT" "mode=check" "the home check did not run"
assert_contains "$OUT" "check home=fixable: $HOST does not exist" "the missing home was not reported"
assert_contains "$OUT" "check clone:alpha=fixable" "the missing clone was not reported"
assert_absent "$HOST" "a check-only doctor created the home"
pass "the doctor reports an unseeded host's gaps and changes nothing"

# --- account readiness gates the seed -------------------------------------------

FM_FAKE_ACCOUNT=human run "$ROOT/bin/fm-worker-host-seed.sh" m1 --lanes 2 alpha
expect_code 1 "$RC" "a seed on an unready account must fail"
assert_contains "$OUT" "account: check gui-session=human" "the account gap was not relayed"
assert_contains "$OUT" "its home was not changed" "the seed did not say it left the home alone"
assert_absent "$HOST" "a seed on an unready account created the home"
FM_FAKE_SSH_DOWN=1 run "$ROOT/bin/fm-worker-host-seed.sh" m1 --lanes 2 alpha
expect_code 255 "$RC" "an unreachable host must report unknown completion"
assert_contains "$OUT" "state is unknown" "the unreachable outcome was not named"
pass "the seed waits for account readiness and reports an unreachable host as unknown"

# --- the seed -----------------------------------------------------------------------

run "$ROOT/bin/fm-worker-host-seed.sh" m1 --lanes 2 --capacity alpha=1 alpha "beta=$BETA_ORIGIN"
expect_code 0 "$RC" "the seed failed: $OUT"
for dir in data state config projects; do
  [ -d "$HOST/$dir" ] && [ ! -L "$HOST/$dir" ] || fail "the seed did not create $dir/"
done
assert_equals m1 "$(cat "$HOST/.fm-worker-host")" "the marker does not name the worker host"
assert_equals manual "$(cat "$HOST/config/backlog-backend")" "the backlog backend is not manual"
assert_equals 2 "$(cat "$HOST/config/lane-capacity")" "the lane cap was not written"
assert_grep "alpha 1" "$HOST/config/project-capacity" "the project capacity was not written"
assert_equals "$TMP_ROOT/origins/alpha.git" "$(git -C "$HOST/projects/alpha" remote get-url origin)" "alpha was not cloned from the primary's origin"
assert_equals "$BETA_ORIGIN" "$(git -C "$HOST/projects/beta" remote get-url origin)" "beta was not cloned from the named origin"
assert_equals "$ALPHA_LINE
$BETA_LINE" "$(cat "$HOST/data/projects.md")" "the host registry is not the primary's records"
git -C "$HOST/projects/alpha" remote get-url no-mistakes >/dev/null 2>&1 || fail "alpha was not initialized for no-mistakes"
! git -C "$HOST/projects/beta" remote get-url no-mistakes >/dev/null 2>&1 || fail "a direct-PR project was initialized for no-mistakes"
assert_equals "init alpha" "$(cat "$NM_LOG")" "no-mistakes init did not run exactly once, in alpha"
assert_absent "$HOST/.fm-secondmate-home" "the home was made a second-mate home"
assert_absent "$HOST/.fm-secondmate-parent" "the home was given a second-mate parent"
assert_absent "$HOST/config/t3code-token" "a T3 credential was copied to the host"
assert_absent "$HOST/AGENTS.md" "the home was made a Firstmate checkout"
assert_equals "" "$(find "$HOST/state" -mindepth 1 -print)" "the seed wrote state into the host home"
assert_contains "$OUT" "check t3-credential=skip" "a primary without T3 still demanded a host sign-in"
assert_contains "$OUT" "ok: worker host home ready at $HOST" "the seed did not end ready"
pass "the seed builds the home: layout, marker, manual backlog, capacity, clones, records, and no-mistakes init"

run "$ROOT/bin/fm-worker-host-seed.sh" m1 --lanes 2 --capacity alpha=1 alpha "beta=$BETA_ORIGIN"
expect_code 0 "$RC" "a repeated seed failed: $OUT"
assert_not_contains "$OUT" "fix " "a repeated seed changed something"
assert_equals "init alpha" "$(cat "$NM_LOG")" "a repeated seed initialized no-mistakes again"
pass "a repeated seed converges without changing anything"

# --- drift, check, and repair ----------------------------------------------------------

rm -f "$HOST/.fm-worker-host"
printf '%s\n%s\n' "$ALPHA_LINE" '- beta [no-mistakes] - the beta site (added 2026-11-02)' > "$HOST/data/projects.md"
run "$ROOT/bin/fm-worker-host-doctor.sh" m1
expect_code 1 "$RC" "the doctor must fail on a drifted home"
assert_contains "$OUT" "check marker=fixable" "the missing marker was not reported"
assert_contains "$OUT" "check registry:beta=fixable: data/projects.md registers beta differently" "the drifted record was not reported"
assert_contains "$OUT" "check registry:alpha=ok" "the matching record was not confirmed"
assert_not_contains "$OUT" "gamma" "a local-only project was checked"
assert_absent "$HOST/.fm-worker-host" "a check-only doctor wrote the marker"
run "$ROOT/bin/fm-worker-host-doctor.sh" m1 --fix
expect_code 0 "$RC" "the doctor did not repair the drift: $OUT"
assert_contains "$OUT" "fix marker=applied" "the marker repair was not reported"
assert_equals m1 "$(cat "$HOST/.fm-worker-host")" "the marker was not restored"
assert_equals "$ALPHA_LINE
$BETA_LINE" "$(cat "$HOST/data/projects.md")" "the primary's record was not restored"
pass "with no project named, the doctor checks every project the host holds and --fix repairs drift"

# --- declarations are never overwritten ------------------------------------------------

run "$ROOT/bin/fm-worker-host-seed.sh" m1 --lanes 3 --capacity alpha=2 alpha
expect_code 1 "$RC" "a different lane cap must not pass"
assert_contains "$OUT" "check lane-capacity=human: $HOST/config/lane-capacity caps lanes at 2, not the requested 3" "the lane conflict was not reported"
assert_contains "$OUT" "already declares alpha is 1 not 2" "the project capacity conflict was not reported"
assert_equals 2 "$(cat "$HOST/config/lane-capacity")" "an existing lane cap was overwritten"
pass "an existing capacity declaration is reported, never overwritten"

# --- a second-mate home and a home inside the code root are left alone ----------------

: > "$HOST/.fm-secondmate-home"
rm -f "$HOST/.fm-worker-host"
run "$ROOT/bin/fm-worker-host-doctor.sh" m1 --fix
expect_code 1 "$RC" "a second-mate home must not pass"
assert_contains "$OUT" "check secondmate=human" "the second-mate marker was not reported"
assert_absent "$HOST/.fm-worker-host" "the doctor changed a second-mate home"
rm -f "$HOST/.fm-secondmate-home"
run "$ROOT/bin/fm-worker-host-doctor.sh" m1 --fix
expect_code 0 "$RC" "the doctor did not recover once the second-mate marker was gone: $OUT"
run "$ROOT/bin/fm-worker-host-doctor.sh" inroot --fix
expect_code 1 "$RC" "a home inside the code root must not pass"
assert_contains "$OUT" "remote root and home must be separate" "the nested home was not refused"
assert_absent "$REMOTE_ROOT/inroot-home" "the doctor created a home inside the code root"
pass "a second-mate home and a home inside the code root are reported and never changed"

# --- T3: days left, version, and capabilities against the primary -----------------------

if ! command -v node >/dev/null 2>&1; then
  pass "skip: node not found, so the T3 checks are not exercised"
  echo "all fm-worker-host-seed-doctor tests passed"
  exit 0
fi

start_t3() { # <dir> <world-json>: a fresh fake T3 server; leaves T3_FAKE_* pointing at it
  T3_FAKE_PID=
  t3_fake_start "$1"
  T3_PIDS+=("$T3_FAKE_PID")
  t3_fake_case "$1/world" "$2"
}

FORK_WORLD='{"serverVersion":"0.1.7+fork.1","launchEnvironment":true,"sessionStop":true,"keepAlive":true}'
start_t3 "$TMP_ROOT/t3-primary" "$FORK_WORLD"
t3_fake_credential "$PARENT/config/t3code-token"
t3_fake_credential "$HOST/config/t3code-token"
run "$ROOT/bin/fm-worker-host-doctor.sh" m1
expect_code 0 "$RC" "a host on the primary's T3 build must pass: $OUT"
case "$OUT" in
  *"check t3-credential=ok: 30 days left (expires "*|*"check t3-credential=ok: 29."?" days left (expires "*) ;;
  *) fail "the host's days left were not reported: $OUT" ;;
esac
assert_contains "$OUT" "check t3-version=ok: T3 0.1.7+fork.1, the same build as the primary" "the version match was not reported"
assert_contains "$OUT" "covering the primary's launchEnvironment sessionStop keepAlive" "the capability match was not reported"
pass "a host on the primary's T3 build reports its days left, version, and capabilities as matching"

start_t3 "$TMP_ROOT/t3-host" '{"serverVersion":"0.1.7","launchEnvironment":true}'
t3_fake_credential "$HOST/config/t3code-token"
run "$ROOT/bin/fm-worker-host-doctor.sh" m1 --fix
expect_code 1 "$RC" "a host on another T3 build must not pass"
assert_contains "$OUT" "check t3-version=human: this host runs T3 0.1.7, but the primary runs 0.1.7+fork.1" "the version mismatch was not reported"
assert_contains "$OUT" "check t3-capabilities=human: this host's T3 lacks sessionStop keepAlive" "the missing capabilities were not reported"
pass "a host on another T3 build is reported, and --fix leaves T3 to the operator"

t3_fake_credential "$HOST/config/t3code-token" env-fake-1 "$(( ($(date +%s) - 3600) * 1000 ))"
run "$ROOT/bin/fm-worker-host-doctor.sh" m1
expect_code 1 "$RC" "an expired host sign-in must not pass"
assert_contains "$OUT" "check t3-credential=human:" "the expired sign-in was not reported"
assert_contains "$OUT" "expired" "the expiry was not named"
rm -f "$HOST/config/t3code-token"
run "$ROOT/bin/fm-worker-host-doctor.sh" m1 --fix
expect_code 1 "$RC" "a host with no sign-in must not pass when the primary runs T3"
assert_contains "$OUT" "check t3-credential=human: this home has no T3 sign-in, and the primary runs T3" "the missing sign-in was not reported"
assert_absent "$HOST/config/t3code-token" "the doctor created a T3 credential on the host"
pass "an expired or missing host sign-in is the operator's step, never copied from the primary"

echo "all fm-worker-host-seed-doctor tests passed"
