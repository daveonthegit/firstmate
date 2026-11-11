#!/usr/bin/env bash
# tests/fm-supervisor-lease.test.sh - behavior tests for
# bin/fm-supervisor-lease.sh, the machine-wide supervisor lease kept in a
# home's records repository.
#
# Every case builds two homes with different config/machine-id values whose
# data/ directories are clones of one local bare remote, so the two homes read
# as two machines without any network:
#   - a home whose data/ is not a git repository with a remote is untouched
#   - the second home refuses while the first holds the lease, and stands down
#   - a rejected records push stands a running session down and queues a wake
#   - release then acquire moves the lease to the other home
#   - steal needs the owner flag and bumps the epoch past every epoch seen
#   - an unreachable remote continues only for the recorded holder
#   - a context rebuild confirms without writing and never re-takes the lease
#   - a worker-host home refuses the lease
#   - fm-lock.sh refuses the session lock while the home is stood down
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEASE="$ROOT/bin/fm-supervisor-lease.sh"
LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervisor-lease-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

# new_pair <name>: a bare records remote seeded with one backlog commit, and two
# homes (a = machine m-a, b = machine m-b) whose data/ clones it. Echoes the
# world directory.
new_pair() {
  local w="$TMP_ROOT/$1" h
  mkdir -p "$w"
  git init -q --bare -b main "$w/remote.git"
  fm_git_init_commit "$w/seed"
  git -C "$w/seed" remote add origin "$w/remote.git"
  git -C "$w/seed" push -q origin main
  for h in a b; do
    mkdir -p "$w/$h/state" "$w/$h/config"
    printf 'm-%s\n' "$h" > "$w/$h/config/machine-id"
    git clone -q "$w/remote.git" "$w/$h/data"
  done
  printf '%s\n' "$w"
}

lease() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" bash "$LEASE" "$@" 2>&1
}

remote_lease() {  # <world>
  git -C "$1/remote.git" show main:supervisor.lease 2>/dev/null
}

test_off_home_is_untouched() {
  local w="$TMP_ROOT/off" out status
  # A plain directory, a directory inside an outer repository (as data/ sits
  # inside the firstmate checkout), and a repository without a remote.
  mkdir -p "$w/plain/data" "$w/plain/state"
  fm_git_init_commit "$w/outer"
  mkdir -p "$w/outer/data" "$w/outer/state"
  fm_git_init_commit "$w/noremote/data"
  mkdir -p "$w/noremote/state"
  for home in "$w/plain" "$w/outer" "$w/noremote"; do
    status=0
    out=$(lease "$home" acquire) || status=$?
    expect_code 0 "$status" "acquire in a home without a records remote"
    assert_equals "" "$out" "acquire printed output in a home without a records remote"
    [ ! -e "$home/data/supervisor.lease" ] || fail "acquire wrote a lease in $home"
    [ ! -e "$home/state/.supervisor-lease-lost" ] || fail "acquire recorded a stand-down in $home"
    out=$(lease "$home" status)
    assert_contains "$out" "mode: off" "status did not report the lease off for $home"
    status=0
    out=$(lease "$home" push) || status=$?
    expect_code 0 "$status" "push in a home without a records remote"
  done
  [ -z "$(git -C "$w/noremote/data" status --porcelain)" ] || fail "acquire changed a repository without a remote"
  pass "a home whose data/ is not a git repository with a remote gets no lease, no output, and no refusal"
}

test_second_home_refuses() {
  local w out status
  w=$(new_pair refuse)
  status=0
  out=$(lease "$w/a" acquire) || status=$?
  expect_code 0 "$status" "first home acquire"
  assert_contains "$out" "held by this machine at epoch 1" "first home did not take epoch 1"
  assert_contains "$(remote_lease "$w")" "host=m-a epoch=1" "the lease never reached the remote"
  assert_contains "$(cat "$w/a/data/supervisor.lease")" "host=m-a epoch=1" "the local lease file was not updated"
  [ -z "$(git -C "$w/a/data" status --porcelain)" ] || fail "acquire left data/ dirty"

  status=0
  out=$(lease "$w/b" acquire) || status=$?
  expect_code 1 "$status" "second home acquire"
  assert_contains "$out" "refused: the lease is held by m-a at epoch 1" "second home did not name the holder"
  assert_contains "$out" "stay read-only" "second home refusal did not say read-only"
  [ -f "$w/b/state/.supervisor-lease-lost" ] || fail "a refusal did not record a stand-down"
  assert_contains "$(remote_lease "$w")" "host=m-a epoch=1" "a refused acquire moved the remote lease"
  pass "the second home refuses while the first holds the lease and records a stand-down"
}

test_rejected_push_stands_down() {
  local w out status
  w=$(new_pair reject)
  lease "$w/a" acquire >/dev/null || fail "first acquire failed"
  printf 'work\n' >> "$w/a/data/README.md"
  git -C "$w/a/data" commit -qam "records change"

  # A remote hook that declines every update is a rejected push.
  printf '#!/bin/sh\necho declined >&2\nexit 1\n' > "$w/remote.git/hooks/pre-receive"
  chmod +x "$w/remote.git/hooks/pre-receive"
  status=0
  out=$(lease "$w/a" push) || status=$?
  expect_code 1 "$status" "push rejected by the remote"
  assert_contains "$out" "STOOD DOWN: the records push was rejected" "a rejected push did not stand down"
  [ -f "$w/a/state/.supervisor-lease-lost" ] || fail "a rejected push recorded no stand-down"
  grep -q 'supervisor-lease-lost' "$w/a/state/.wake-queue" 2>/dev/null \
    || fail "a rejected push queued no wake"
  rm -f "$w/remote.git/hooks/pre-receive"

  status=0
  out=$(lease "$w/a" push) || status=$?
  expect_code 1 "$status" "push after a stand-down"
  assert_contains "$out" "already stood down" "a stood-down home pushed records"

  # The lease moved under a running session: the other home stole it.
  w=$(new_pair moved)
  lease "$w/a" acquire >/dev/null || fail "first acquire failed"
  lease "$w/b" steal --owner-approved >/dev/null || fail "steal failed"
  printf 'work\n' >> "$w/a/data/README.md"
  git -C "$w/a/data" commit -qam "records change"
  status=0
  out=$(lease "$w/a" push) || status=$?
  expect_code 1 "$status" "push after the lease moved"
  assert_contains "$out" "STOOD DOWN: the lease moved to host=m-b epoch=2" "a moved lease did not stand down"
  assert_contains "$(remote_lease "$w")" "host=m-b epoch=2" "a stood-down push changed the remote lease"

  # A rejected push while acquiring is a refusal, and leaves data/ unchanged.
  w=$(new_pair acquire-reject)
  printf '#!/bin/sh\nexit 1\n' > "$w/remote.git/hooks/pre-receive"
  chmod +x "$w/remote.git/hooks/pre-receive"
  status=0
  out=$(lease "$w/a" acquire) || status=$?
  expect_code 1 "$status" "acquire with a rejected push"
  assert_contains "$out" "the records push was rejected" "acquire did not report the rejected push"
  [ ! -e "$w/a/data/supervisor.lease" ] || fail "a rejected acquire wrote the local lease file"
  assert_equals "$(git -C "$w/remote.git" rev-parse main)" "$(git -C "$w/a/data" rev-parse HEAD)" "a rejected acquire moved data/"
  pass "a rejected records push stands the session down, queues a wake, and blocks further pushes"
}

test_release_then_acquire() {
  local w out status
  w=$(new_pair release)
  lease "$w/a" acquire >/dev/null || fail "first acquire failed"
  status=0
  out=$(lease "$w/b" release) || status=$?
  expect_code 1 "$status" "release by a non-holder"
  assert_contains "$out" "not held by this machine" "a non-holder released the lease"

  status=0
  out=$(lease "$w/a" release) || status=$?
  expect_code 0 "$status" "release by the holder"
  assert_contains "$out" "released at epoch 2" "release did not advance the epoch"
  assert_contains "$(remote_lease "$w")" "host=none epoch=2" "the release never reached the remote"
  [ -f "$w/a/state/.supervisor-lease-lost" ] || fail "the releasing home did not stand down"

  status=0
  out=$(lease "$w/b" acquire) || status=$?
  expect_code 0 "$status" "acquire after release"
  assert_contains "$out" "held by this machine at epoch 3" "the other home did not take the released lease"
  [ ! -e "$w/b/state/.supervisor-lease-lost" ] || fail "a successful acquire left a stand-down record"

  status=0
  out=$(lease "$w/a" acquire) || status=$?
  expect_code 1 "$status" "the old holder acquires after the move"
  assert_contains "$out" "held by m-b at epoch 3" "the old holder did not see the new holder"
  pass "release then acquire moves the lease to the other home at the next epoch"
}

test_steal_bumps_epoch() {
  local w out status
  w=$(new_pair steal)
  lease "$w/a" acquire >/dev/null || fail "first acquire failed"
  lease "$w/a" acquire >/dev/null || fail "second acquire failed"
  assert_contains "$(remote_lease "$w")" "host=m-a epoch=2" "a holder's fresh acquire did not advance the epoch"

  status=0
  out=$(lease "$w/b" steal) || status=$?
  expect_code 2 "$status" "steal without the owner flag"
  assert_contains "$(remote_lease "$w")" "host=m-a epoch=2" "steal without the owner flag moved the lease"

  lease "$w/b" acquire >/dev/null && fail "acquire should refuse before the steal"
  status=0
  out=$(lease "$w/b" steal --owner-approved) || status=$?
  expect_code 0 "$status" "steal with the owner flag"
  assert_contains "$out" "held by this machine at epoch 3" "steal did not bump the epoch"
  assert_contains "$(remote_lease "$w")" "host=m-b epoch=3" "the steal never reached the remote"
  [ ! -e "$w/b/state/.supervisor-lease-lost" ] || fail "steal left the refusal's stand-down record"
  pass "steal needs the owner flag and bumps the epoch past every epoch seen"
}

test_unreachable_remote() {
  local w out status
  w=$(new_pair unreachable)
  lease "$w/a" acquire >/dev/null || fail "first acquire failed"
  git -C "$w/b/data" fetch -q origin
  mv "$w/remote.git" "$w/remote.gone"

  status=0
  out=$(lease "$w/a" acquire) || status=$?
  expect_code 0 "$status" "holder acquire with the remote unreachable"
  assert_contains "$out" "UNCONFIRMED" "an unconfirmed lease was not flagged"
  assert_contains "$out" "epoch 1 per the local copy" "the unconfirmed holder did not keep its epoch"

  status=0
  out=$(lease "$w/b" acquire) || status=$?
  expect_code 1 "$status" "non-holder acquire with the remote unreachable"
  assert_contains "$out" "only fm-supervisor-lease.sh steal --owner-approved overrides this" "the refusal did not name the override"

  status=0
  out=$(lease "$w/a" push) || status=$?
  expect_code 3 "$status" "push with the remote unreachable"
  [ ! -e "$w/a/state/.supervisor-lease-lost" ] || fail "an unreachable push stood the session down"

  # The owner's word lets the other home take it while the remote is down; the
  # next acquire publishes it once the remote is back.
  status=0
  out=$(lease "$w/b" steal --owner-approved) || status=$?
  expect_code 0 "$status" "steal with the remote unreachable"
  assert_contains "$out" "UNCONFIRMED: stolen locally at epoch 2" "an offline steal was not flagged unconfirmed"
  status=0
  out=$(lease "$w/b" acquire) || status=$?
  expect_code 0 "$status" "acquire after an offline steal"
  mv "$w/remote.gone" "$w/remote.git"
  status=0
  out=$(lease "$w/b" acquire) || status=$?
  expect_code 0 "$status" "acquire once the remote is back"
  assert_contains "$(remote_lease "$w")" "host=m-b epoch=3" "the offline steal was not published"
  pass "an unreachable remote continues only for the recorded holder, and an offline steal publishes later"
}

test_reemit_never_writes_or_retakes() {
  local w out status before
  w=$(new_pair reemit)
  lease "$w/a" acquire >/dev/null || fail "first acquire failed"
  before=$(git -C "$w/remote.git" rev-parse main)
  status=0
  out=$(lease "$w/a" acquire --reemit) || status=$?
  expect_code 0 "$status" "reemit by the holder"
  assert_contains "$out" "confirmed, unchanged" "reemit did not confirm"
  assert_equals "$before" "$(git -C "$w/remote.git" rev-parse main)" "reemit wrote to the records remote"

  lease "$w/a" release >/dev/null || fail "release failed"
  status=0
  out=$(lease "$w/a" acquire --reemit) || status=$?
  expect_code 1 "$status" "reemit after release"
  assert_contains "$(remote_lease "$w")" "host=none epoch=2" "reemit re-took a released lease"
  pass "a context rebuild confirms without writing and never re-takes a released lease"
}

test_worker_host_refuses() {
  local w out status
  w=$(new_pair worker-host)
  : > "$w/a/.fm-worker-host"
  for verb in acquire push; do
    status=0
    out=$(lease "$w/a" "$verb") || status=$?
    expect_code 1 "$status" "$verb in a worker-host home"
    assert_contains "$out" "worker-host home" "$verb did not name the worker-host refusal"
  done
  status=0
  out=$(lease "$w/a" steal --owner-approved) || status=$?
  expect_code 1 "$status" "steal in a worker-host home"
  [ -z "$(remote_lease "$w")" ] || fail "a worker-host home wrote the lease"
  pass "a worker-host home refuses the supervisor lease"
}

test_reserved_identity_refuses() {
  local w source verb out status before
  for source in config localhost hostname; do
    w=$(new_pair "reserved-$source")
    before=$(git -C "$w/remote.git" rev-parse main)
    mkdir -p "$w/tools"
    printf '#!/bin/sh\nprintf "none\\n"\n' > "$w/tools/scutil"
    cp "$w/tools/scutil" "$w/tools/hostname"
    chmod +x "$w/tools/scutil" "$w/tools/hostname"
    if [ "$source" = hostname ]; then
      printf '#!/bin/sh\nexit 1\n' > "$w/tools/scutil"
    fi
    if [ "$source" = config ]; then
      printf 'none\n' > "$w/a/config/machine-id"
    else
      rm "$w/a/config/machine-id"
    fi
    for verb in acquire steal; do
      status=0
      if [ "$verb" = steal ]; then
        out=$(PATH="$w/tools:$PATH" lease "$w/a" steal --owner-approved) || status=$?
      else
        out=$(PATH="$w/tools:$PATH" lease "$w/a" acquire) || status=$?
      fi
      expect_code 1 "$status" "$verb with reserved $source identity"
      assert_equals "$before" "$(git -C "$w/remote.git" rev-parse main)" "reserved identity changed the remote"
      [ ! -e "$w/a/data/supervisor.lease" ] || fail "reserved identity published a lease"
    done
  done
  pass "configured and fallback identities cannot publish the free-record sentinel"
}

test_multiple_remotes_refuse() {
  local w verb out status before
  w=$(new_pair multiple-remotes)
  before=$(git -C "$w/remote.git" rev-parse main)
  git -C "$w/a/data" remote add extra "$w/remote.git"
  for verb in acquire release push steal; do
    status=0
    if [ "$verb" = steal ]; then
      out=$(lease "$w/a" steal --owner-approved) || status=$?
    else
      out=$(lease "$w/a" "$verb") || status=$?
    fi
    expect_code 1 "$status" "$verb with two remotes and an upstream"
    assert_contains "$out" "exactly one records remote" "multiple remotes were accepted"
    assert_equals "$before" "$(git -C "$w/remote.git" rev-parse main)" "ambiguous remote was written"
  done
  pass "every mutating verb refuses multiple remotes even with an upstream"
}

test_release_and_steal_failures_stand_down() {
  local w verb scenario out status
  local original_path="$PATH"
  local -a args
  for verb in release steal; do
    args=("$verb")
    [ "$verb" != steal ] || args+=(--owner-approved)
    for scenario in moved diverged race rejected timeout adoption; do
      if [ "$verb" = steal ] && { [ "$scenario" = moved ] || [ "$scenario" = timeout ]; }; then
        continue
      fi
      w=$(new_pair "$verb-$scenario")
      lease "$w/a" acquire >/dev/null || fail "first acquire failed"
      case "$scenario" in
        moved|diverged)
          lease "$w/b" steal --owner-approved >/dev/null || fail "other home steal failed"
          if [ "$scenario" = diverged ]; then
            printf 'work\n' >> "$w/a/data/README.md"
            git -C "$w/a/data" commit -qam "local records"
          fi
          ;;
        rejected)
          printf '#!/bin/sh\nexit 1\n' > "$w/remote.git/hooks/pre-receive"
          chmod +x "$w/remote.git/hooks/pre-receive"
          ;;
      esac
      mkdir -p "$w/tools"
      cat > "$w/tools/git" <<'WRAPPER'
#!/usr/bin/env bash
if [ "${3:-}" = push ]; then
  case "$TEST_SCENARIO" in
    race)
      FM_HOME="$TEST_WORLD/b" PATH="$TEST_ORIGINAL_PATH" bash "$TEST_LEASE" steal --owner-approved >&2 || exit 1
      ;;
    timeout)
      "$TEST_REAL_GIT" "$@" >&2 || exit 1
      exit 124
      ;;
  esac
fi
if [ "$TEST_SCENARIO" = adoption ] && [ "${3:-}" = update-ref ] && [ "${4:-}" = refs/heads/main ]; then
  exit 1
fi
exec "$TEST_REAL_GIT" "$@"
WRAPPER
      chmod +x "$w/tools/git"
      status=0
      out=$(TEST_SCENARIO="$scenario" TEST_WORLD="$w" TEST_LEASE="$LEASE" \
        TEST_REAL_GIT="$(command -v git)" TEST_ORIGINAL_PATH="$original_path" PATH="$w/tools:$original_path" \
        lease "$w/a" "${args[@]}") || status=$?
      expect_code 1 "$status" "$verb after $scenario"
      [ -f "$w/a/state/.supervisor-lease-lost" ] || fail "$verb after $scenario left supervision active: $out"
      status=0
      out=$(FM_HOME="$w/a" bash "$LOCK" 2>&1) || status=$?
      expect_code 1 "$status" "session lock after $verb $scenario"
      if [ "$verb" = release ] && { [ "$scenario" = timeout ] || [ "$scenario" = adoption ]; }; then
        assert_contains "$(remote_lease "$w")" "host=none epoch=2" "release did not reach the remote"
        lease "$w/b" acquire >/dev/null || fail "other home could not acquire after release"
      fi
      if [ "$scenario" = race ]; then
        assert_contains "$(remote_lease "$w")" "host=m-b epoch=2" "racing takeover did not win"
      fi
    done
  done
  pass "release and steal failures revoke supervision, including uncertain release delivery"
}

test_lock_refuses_while_stood_down() {
  local w out status
  w=$(new_pair lock)
  lease "$w/a" acquire >/dev/null || fail "first acquire failed"
  lease "$w/b" acquire >/dev/null && fail "second acquire should refuse"
  status=0
  out=$(FM_HOME="$w/b" bash "$LOCK" 2>&1) || status=$?
  expect_code 1 "$status" "fm-lock.sh in a stood-down home"
  assert_contains "$out" "stood down from the supervisor lease" "fm-lock.sh did not name the stand-down"
  [ ! -e "$w/b/state/.lock" ] || fail "fm-lock.sh wrote a lock in a stood-down home"
  out=$(FM_HOME="$w/b" bash "$LOCK" status 2>&1)
  assert_contains "$out" "refused while this home is stood down" "lock status did not report the stand-down"
  pass "fm-lock.sh refuses the session lock while the home is stood down"
}

fm_test_run \
  test_off_home_is_untouched \
  test_second_home_refuses \
  test_rejected_push_stands_down \
  test_release_then_acquire \
  test_steal_bumps_epoch \
  test_unreachable_remote \
  test_reemit_never_writes_or_retakes \
  test_worker_host_refuses \
  test_reserved_identity_refuses \
  test_multiple_remotes_refuse \
  test_release_and_steal_failures_stand_down \
  test_lock_refuses_while_stood_down
