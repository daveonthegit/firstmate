#!/usr/bin/env bash
set -euo pipefail
E=~/.no-mistakes/evidence/01M74AWVBSK91QMVMHP860CYG3
A=$FM_HOME
B="$FM_HOME/b"
trap 'rc=$?; printf "%s\n" "$rc" > "$A/scenario-exit"' EXIT
echo '=== real Claude primary: start host A ==='
bin/fm-session-start.sh > "$E/primary-startup-digest.log" 2>&1
. bin/fm-session-lock-lib.sh
fm_session_lock_owned_by_self "$A/state"
echo 'BEFORE TAKEOVER: real harness owns the session lock'
cat "$A/state/.lock"
git -C "$A/remote.git" show main:supervisor.lease

echo '=== competing home B session start must stay read-only and take no lock ==='
FM_HOME="$B" bin/fm-session-start.sh > "$E/competing-startup-digest.log" 2>&1
grep -F 'READ-ONLY SESSION - THIS MACHINE DOES NOT HOLD THE SUPERVISOR LEASE' "$E/competing-startup-digest.log"
test ! -e "$B/state/.lock"
test -f "$B/state/.supervisor-lease-lost"
echo 'Competing home has no session lock'

echo '=== explicit B takeover then A records push ==='
FM_HOME="$B" bin/fm-supervisor-lease.sh steal --owner-approved
printf 'synthetic progress from A\n' >> "$A/data/backlog.md"
git -C "$A/data" commit -qam 'synthetic records progress'
set +e
bin/fm-supervisor-lease.sh push
rc=$?
set -e
echo "Push after takeover exit=$rc"
test "$rc" = 1
if fm_session_lock_owned_by_self "$A/state"; then echo 'ERROR: supervision authority remained'; exit 1; fi
kill -0 "$(cat "$A/state/.lock")"
echo 'AFTER TAKEOVER: harness is still alive but no longer owns supervision'
cat "$A/state/.supervisor-lease-lost" "$A/state/.wake-queue"
git -C "$A/remote.git" show main:supervisor.lease | grep '^host=mac-secondary epoch=2 '
# Wait for the startup worker before the parent lab is removed.
for i in $(seq 1 90); do
 if [ ! -f "$A/state/.startup-network.status" ] || ! grep -q '^state=running$' "$A/state/.startup-network.status"; then break; fi
 sleep 1
done
if [ -f "$A/state/.startup-network.status" ]; then
 cat "$A/state/.startup-network.status"
 ! grep -q '^state=running$' "$A/state/.startup-network.status"
fi
echo 'REAL PRIMARY SCENARIO COMPLETE'
