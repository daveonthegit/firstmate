#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M74AWVBSK91QMVMHP860CYG3
W="$ROOT/.validation/world"
mkdir -p "$W"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
pair() {
  local label=$1 h
  P="$W/$label"; mkdir -p "$P"
  git init -q --bare -b main "$P/remote.git"
  git init -q -b main "$P/seed"
  printf 'synthetic records\n' > "$P/seed/README.md"
  git -C "$P/seed" add .; git -C "$P/seed" commit -qm seed
  git -C "$P/seed" remote add origin "$P/remote.git"; git -C "$P/seed" push -q origin main
  for h in a b; do
    "$ROOT/bin/fm-lab-home.sh" create "$P/$h" >/dev/null
    printf 'mac-%s\n' "$h" > "$P/$h/config/machine-id"
    git clone -q "$P/remote.git" "$P/$h/data"
  done
}
run() {
  local home=$1 expected=$2; shift 2
  echo "+ FM_HOME=$home bin/fm-supervisor-lease.sh $* (expected exit $expected)"
  set +e
  FM_HOME="$home" bash "$ROOT/bin/fm-supervisor-lease.sh" "$@"
  rc=$?; set -e
  echo "exit=$rc"; test "$rc" = "$expected"
}
record() { echo 'REMOTE RECORD:'; git -C "$P/remote.git" show main:supervisor.lease; }
lock_refused() {
  set +e; FM_HOME="$P/a" bash "$ROOT/bin/fm-lock.sh"; rc=$?; set -e
  echo "lock exit=$rc"; test "$rc" = 1
  test -f "$P/a/state/.supervisor-lease-lost"
}
echo '=== competing acquisition, release, steal and context rebuild ==='
pair transfer
run "$P/a" 0 acquire
run "$P/b" 1 acquire
record
run "$P/b" 2 steal
run "$P/b" 0 steal --owner-approved
record
git -C "$P/remote.git" show main:supervisor.lease | grep '^host=mac-b epoch=2 '
run "$P/a" 1 acquire --reemit
run "$P/b" 0 release
record
before=$(git -C "$P/remote.git" rev-parse main)
run "$P/b" 1 acquire --reemit
test "$before" = "$(git -C "$P/remote.git" rev-parse main)"
run "$P/a" 0 acquire
run "$P/a" 0 status
record

echo '=== rejected records push revokes supervision and queues wake ==='
pair push
run "$P/a" 0 acquire
printf 'work\n' >> "$P/a/data/README.md"; git -C "$P/a/data" commit -qam work
printf '#!/bin/sh\necho lab-rejected >&2\nexit 1\n' > "$P/remote.git/hooks/pre-receive"; chmod +x "$P/remote.git/hooks/pre-receive"
run "$P/a" 1 push
lock_refused
cat "$P/a/state/.wake-queue"
run "$P/a" 1 push
record
rm "$P/remote.git/hooks/pre-receive"

echo '=== successful records push preserves lease bytes ==='
pair unchanged
run "$P/a" 0 acquire
before=$(git -C "$P/remote.git" show main:supervisor.lease)
printf 'synthetic progress\n' >> "$P/a/data/README.md"; git -C "$P/a/data" commit -qam progress
run "$P/a" 0 push
record
test "$before" = "$(git -C "$P/remote.git" show main:supervisor.lease)"
git -C "$P/remote.git" show main:README.md

echo '=== remote unavailable: holder only, explicit offline override ==='
pair offline
run "$P/a" 0 acquire
git -C "$P/b/data" fetch -q origin
mv "$P/remote.git" "$P/remote.gone"
run "$P/a" 0 acquire
run "$P/b" 1 acquire
run "$P/a" 3 push
test ! -e "$P/a/state/.supervisor-lease-lost"
run "$P/b" 0 steal --owner-approved
mv "$P/remote.gone" "$P/remote.git"
run "$P/b" 0 acquire
record

echo '=== guards: reserved identity, worker role, ambiguous remote, off home ==='
pair guards
before=$(git -C "$P/remote.git" rev-parse main)
printf 'none\n' > "$P/a/config/machine-id"
run "$P/a" 1 acquire
run "$P/a" 1 steal --owner-approved
printf 'mac-a\n' > "$P/a/config/machine-id"
touch "$P/a/.fm-worker-host"
run "$P/a" 1 acquire
run "$P/a" 1 steal --owner-approved
run "$P/a" 1 push
rm "$P/a/.fm-worker-host"
git -C "$P/a/data" remote add extra "$P/remote.git"
for verb in acquire release push; do run "$P/a" 1 "$verb"; done
run "$P/a" 1 steal --owner-approved
test "$before" = "$(git -C "$P/remote.git" rev-parse main)"
"$ROOT/bin/fm-lab-home.sh" create "$W/off" >/dev/null
run "$W/off" 0 acquire
run "$W/off" 0 status
test ! -e "$W/off/data/supervisor.lease"

echo '=== lifecycle races and uncertain release delivery (real Git hooks) ==='
for verb in release steal; do
 for fault in moved race rejected adoption timeout; do
  if [ "$verb" = steal ] && { [ "$fault" = moved ] || [ "$fault" = timeout ]; }; then continue; fi
  pair "$verb-$fault"
  run "$P/a" 0 acquire
  args=("$verb"); [ "$verb" != steal ] || args+=(--owner-approved)
  case "$fault" in
   moved) run "$P/b" 0 steal --owner-approved ;;
   race)
    printf '#!/bin/bash\nrm -f "%s/remote.git/hooks/pre-receive"\nenv -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_QUARANTINE_PATH FM_HOME="%s/b" bash "%s/bin/fm-supervisor-lease.sh" steal --owner-approved >&2\n' "$P" "$P" "$ROOT" > "$P/remote.git/hooks/pre-receive"
    chmod +x "$P/remote.git/hooks/pre-receive" ;;
   rejected)
    printf '#!/bin/sh\necho lab-rejected >&2\nexit 1\n' > "$P/remote.git/hooks/pre-receive"; chmod +x "$P/remote.git/hooks/pre-receive" ;;
   adoption)
    printf '#!/bin/sh\ntouch "%s/a/data/.git/refs/heads/main.lock"\n' "$P" > "$P/remote.git/hooks/post-receive"; chmod +x "$P/remote.git/hooks/post-receive" ;;
   timeout)
    printf '#!/bin/sh\nsleep 4\n' > "$P/remote.git/hooks/post-receive"; chmod +x "$P/remote.git/hooks/post-receive"
    export FM_SUPERVISOR_LEASE_TIMEOUT=1 ;;
  esac
  echo "FAULT=$fault VERB=$verb"
  run "$P/a" 1 "${args[@]}"
  unset FM_SUPERVISOR_LEASE_TIMEOUT
  lock_refused
  record
  if [ "$fault" = race ]; then git -C "$P/remote.git" show main:supervisor.lease | grep '^host=mac-b epoch=2 '; fi
  rm -f "$P/remote.git/hooks/post-receive" "$P/a/data/.git/refs/heads/main.lock"
  if [ "$fault" = timeout ]; then sleep 5; fi
 done
done
echo 'ALL LIVE CLI SCENARIOS COMPLETED'
