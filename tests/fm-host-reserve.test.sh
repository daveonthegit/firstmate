#!/usr/bin/env bash
# tests/fm-host-reserve.test.sh - behavioral tests for owner-reserved host
# pause/reduce controls (bin/fm-host-reserve.sh) and their integration with
# bin/fm-capacity.sh and bin/fm-placement.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-host-reserve)
RESERVE="$ROOT/bin/fm-host-reserve.sh"
CAPACITY="$ROOT/bin/fm-capacity.sh"
PLACEMENT="$ROOT/bin/fm-placement.sh"

make_home() { # <name> [lanes]
  local home="$TMP_ROOT/$1" n=${2:-0} i=0
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  while [ "$i" -lt "$n" ]; do
    fm_write_meta "$home/state/task-$i.meta" "kind=ship" "mode=no-mistakes"
    i=$((i + 1))
  done
  printf '%s\n' "$home"
}

write_beat() { # <file> [avail-gb] [total-gb]
  local avail=${2:-48} total=${3:-64}
  cat > "$1" <<JSON
{"schema":"lookout.beat","schema_version":"1.0","host":"studio-host","interval_s":15,
 "machine":{"id":"studio-host","load":{"l1":1.0,"runq_per_core":0.06},
  "mem":{"avail_gb":$avail,"total_gb":$total,"swap_rate_pps_1m":0,"psi_some10":0},
  "disks":[{"label":"disk","free_gb":500}],"on_battery":false,
  "pressure":{"level":"ok","why":[]},"beat":{"errors":[]}}}
JSON
}

make_probes() { # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$fakebin/uname"
  cat > "$fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
case "$2" in
  vm.loadavg) echo "{ 1.00 1.00 1.00 }" ;;
  kern.memorystatus_level) echo 75 ;;
  hw.logicalcpu) echo 18 ;;
  hw.memsize) echo 68719476736 ;;
  kern.memorystatus_vm_pressure_level) echo 1 ;;
  kern.boottime) echo "{ sec = 1700000000, usec = 0 }" ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/getconf"
  cat > "$fakebin/df" <<'SH'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 1048576000 1048576 524288000 1% /fake"
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/vm_stat"
  cat > "$fakebin/pmset" <<'SH'
#!/usr/bin/env bash
case "$2" in
  batt) printf "Now drawing from 'AC Power'\n" ;;
  therm) printf "Note: No thermal warning level has been recorded\nCPU_Speed_Limit = 100\n" ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/ioreg"
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

PROBES=$(make_probes "$TMP_ROOT/probes")

# 1. Pause and release on fixed cap without touching running task records.
home=$(make_home fixed 2)
write_beat "$home/beat.json" 48 64
printf '12\npressure-file %s\nadmit-spawns\n' "$home/beat.json" > "$home/config/lane-capacity"

out=$(FM_HOME="$home" "$RESERVE" status)
assert_contains "$out" "host-reserve: local state=none" "initial status must be none"

out=$(FM_HOME="$home" "$RESERVE" pause --reason "gaming session")
assert_contains "$out" "state=paused" "pause must report paused"
assert_contains "$out" "reason=gaming session" "pause must preserve reason"

out=$(PATH="$PROBES:$PATH" FM_HOME="$home" "$CAPACITY")
assert_contains "$out" "capacity: free_lanes=0 reason=reserve lanes=2 target=12 " "pause must close all free lanes with reason=reserve"
assert_contains "$out" "Reserve: pause (gaming session)." "human report must show pause reserve"

rc=0
out=$(PATH="$PROBES:$PATH" FM_HOME="$home" "$CAPACITY" --spawn-gate 2>&1) || rc=$?
expect_code 75 "$rc" "spawn gate must defer while paused"
assert_contains "$out" "captain reserve: gaming session" "deferral must name pause reason"

doc=$(PATH="$PROBES:$PATH" FM_HOME="$home" "$CAPACITY" --json)
assert_equals 'present|pause|gaming session' \
  "$(printf '%s' "$doc" | jq -r '[.reserve.flag, .reserve.override.mode, .reserve.override.reason] | join("|")')" \
  "json output must expose active pause override"

[ -f "$home/state/task-0.meta" ] && [ -f "$home/state/task-1.meta" ] \
  || fail "pause must never touch running task metadata"

out=$(FM_HOME="$home" "$RESERVE" release)
assert_contains "$out" "released" "release must confirm removal"
out=$(FM_HOME="$home" "$RESERVE" release)
assert_contains "$out" "already clear" "second release must be idempotent"

out=$(PATH="$PROBES:$PATH" FM_HOME="$home" "$CAPACITY")
assert_contains "$out" "capacity: free_lanes=10 reason=ok lanes=2 target=12 " "release must restore normal open lanes"
pass "pause and release close and restore fixed-cap admission without touching running tasks"

# 2. Reduce mode: shrinks max_lanes and raises keep_gb floor in fixed and auto mode.
out=$(FM_HOME="$home" "$RESERVE" reduce --max-lanes 4 --keep-gb 32 --reason "game server")
assert_contains "$out" "state=reduced max_lanes=4 keep_gb=32 reason=game server" "reduce must report limits"

out=$(PATH="$PROBES:$PATH" FM_HOME="$home" "$CAPACITY")
assert_contains "$out" "capacity: free_lanes=2 reason=ok lanes=2 target=4 " "reduce max-lanes=4 with 2 running must leave 2 open"

# When running lanes already meet or exceed reduced max_lanes, new spawns defer while running lanes stay intact.
fm_write_meta "$home/state/task-2.meta" "kind=ship" "mode=no-mistakes"
fm_write_meta "$home/state/task-3.meta" "kind=ship" "mode=no-mistakes"
out=$(PATH="$PROBES:$PATH" FM_HOME="$home" "$CAPACITY")
assert_contains "$out" "capacity: free_lanes=0 reason=full lanes=4 target=4 " "4 running against reduced cap 4 must be full"

# When available memory drops below keep_gb + 1 GB, memory constraint closes admission.
write_beat "$home/beat.json" 32.5 64
out=$(PATH="$PROBES:$PATH" FM_HOME="$home" "$CAPACITY")
assert_contains "$out" "capacity: free_lanes=0 reason=memory lanes=4 target=4 " "keep_gb floor must enforce memory constraint"

# Auto mode honors reduced max_lanes ceiling and keep_gb memory floor.
auto_home=$(make_home auto-reduce 1)
write_beat "$auto_home/beat.json" 48 64
printf 'auto\nmax-lanes 16\npressure-file %s\n' "$auto_home/beat.json" > "$auto_home/config/lane-capacity"
FM_HOME="$auto_home" "$RESERVE" reduce --max-lanes 3 --keep-gb 36 --reason "hosting server" >/dev/null
out=$(PATH="$PROBES:$PATH" FM_HOME="$auto_home" "$CAPACITY")
assert_contains "$out" "capacity: free_lanes=2 reason=ok lanes=1 target=3 " "auto mode must respect reduced max_lanes=3 ceiling"
FM_HOME="$auto_home" "$RESERVE" release >/dev/null
pass "reduce mode shrinks fixed and auto capacity and enforces keep_gb floor"

# 3. Timed reservation expiry auto-releases in fm-capacity.sh.
exp_home=$(make_home expired 0)
write_beat "$exp_home/beat.json" 48 64
printf '8\npressure-file %s\n' "$exp_home/beat.json" > "$exp_home/config/lane-capacity"
FM_HOME="$exp_home" "$RESERVE" pause --until 1000 --reason "old game" >/dev/null
out=$(FM_HOME="$exp_home" "$RESERVE" status)
assert_contains "$out" "state=expired" "past --until must report expired"
out=$(PATH="$PROBES:$PATH" FM_HOME="$exp_home" "$CAPACITY")
assert_contains "$out" "capacity: free_lanes=8 reason=ok lanes=0 target=8 " "expired reservation must not block admission"
pass "expired timed reservations self-release cleanly"

# 4. Malformed or symlinked state/host-reserve fails closed.
bad_home=$(make_home malformed 0)
write_beat "$bad_home/beat.json" 48 64
printf '8\npressure-file %s\n' "$bad_home/beat.json" > "$bad_home/config/lane-capacity"
printf 'mode=bogus\n' > "$bad_home/state/host-reserve"
out=$(PATH="$PROBES:$PATH" FM_HOME="$bad_home" "$CAPACITY")
assert_contains "$out" "capacity: free_lanes=0 reason=reserve " "malformed state/host-reserve must fail closed"
rc=0
FM_HOME="$bad_home" "$RESERVE" status >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" "status on malformed reservation must exit 1"
rm -f "$bad_home/state/host-reserve"
ln -s /etc/hosts "$bad_home/state/host-reserve"
rc=0
FM_HOME="$bad_home" "$RESERVE" pause --reason "test" >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" "symlinked state/host-reserve must be refused"
pass "malformed and symlinked reservation files fail closed"

# 5. Placement skips a paused host and prefers the unreserved host, plus remote --host delegation via fm-on.sh.
CASE="$TMP_ROOT/placement"
PRIMARY="$CASE/primary"
WORKER="$CASE/worker"
mkdir -p "$PRIMARY/data" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/projects" \
  "$WORKER/data" "$WORKER/state" "$WORKER/config" "$WORKER/projects"
: > "$WORKER/.fm-worker-host"
printf 'manual\n' > "$WORKER/config/backlog-backend"
fm_git_init_commit "$PRIMARY/projects/app"
fm_git_init_commit "$WORKER/projects/app"
write_beat "$PRIMARY/beat.json" 48 64
write_beat "$WORKER/beat.json" 48 64
printf '8\npressure-file %s\n' "$PRIMARY/beat.json" > "$PRIMARY/config/lane-capacity"
printf '8\npressure-file %s\n' "$WORKER/beat.json" > "$WORKER/config/lane-capacity"
# Make primary busier (4 of 8 running) so worker (0 of 8) normally wins.
for i in 1 2 3 4; do fm_write_meta "$PRIMARY/state/p-$i.meta" "kind=ship" "mode=no-mistakes"; done
cat > "$PRIMARY/data/worker-hosts.md" <<EOF
- studio2 - equal Mac Studio worker host (host: studio2-ssh; root: $ROOT; home: $WORKER; added 2026-11-24)
EOF

cat > "$CASE/fake-ssh" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "\$1" = studio2-ssh ] || exit 91
[ "\$2" = fm-remote-entrypoint.sh ] || exit 92
decode() { printf '%s' "\$1" | base64 --decode 2>/dev/null || printf '%s' "\$1" | base64 -D; }
root=\$(decode "\$4")
home=\$(decode "\$5")
argv=()
while IFS= read -r -d '' arg; do argv+=("\$arg"); done < <(decode "\$6")
env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \\
  PATH="$PROBES:\$PATH" FM_HOME="\$home" FM_ROOT_OVERRIDE="\$root" \\
  "\$root/bin/\${argv[0]}" "\${argv[@]:1}"
SH
chmod +x "$CASE/fake-ssh"

# Before pause, studio2 (8/8 free) wins over primary (4/8 free).
out=$(PATH="$PROBES:$PATH" FM_HOME="$PRIMARY" FM_SSH_BIN="$CASE/fake-ssh" "$PLACEMENT" app)
assert_contains "$out" "order: studio2 local" "unreserved worker host with more room must rank first"

# Pause studio2 remotely from primary via --host studio2.
out=$(PATH="$PROBES:$PATH" FM_HOME="$PRIMARY" FM_SSH_BIN="$CASE/fake-ssh" "$RESERVE" pause --host studio2 --reason "gaming")
assert_contains "$out" "state=paused reason=gaming" "remote pause via --host must succeed"

out=$(PATH="$PROBES:$PATH" FM_HOME="$PRIMARY" FM_SSH_BIN="$CASE/fake-ssh" "$RESERVE" status --all)
assert_contains "$out" "host-reserve: local state=none" "status --all must include local"
assert_contains "$out" "host-reserve: studio2 state=paused reason=gaming" "status --all must include remote worker host"

out=$(PATH="$PROBES:$PATH" FM_HOME="$PRIMARY" FM_SSH_BIN="$CASE/fake-ssh" "$PLACEMENT" app)
assert_contains "$out" "worker host studio2 does not admit - reserve" "placement must skip paused worker host"
assert_contains "$out" "order: local" "placement must fall back to local when worker is paused"

# Release remotely and verify studio2 ranks first again.
PATH="$PROBES:$PATH" FM_HOME="$PRIMARY" FM_SSH_BIN="$CASE/fake-ssh" "$RESERVE" release --host studio2 >/dev/null
out=$(PATH="$PROBES:$PATH" FM_HOME="$PRIMARY" FM_SSH_BIN="$CASE/fake-ssh" "$PLACEMENT" app)
assert_contains "$out" "order: studio2 local" "releasing worker host must restore balanced placement"
pass "remote --host pause/status/release integrates cleanly with automatic placement"

echo "ALL TESTS PASSED"
