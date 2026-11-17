#!/usr/bin/env bash
set -eu
ROOT=$PWD
FIX="$ROOT/.live-remote"
mkdir -p "$FIX/root/bin" "$FIX/account" "$FIX/home"
trap 'rm -rf "$FIX"' EXIT
cp bin/fm-remote-job-lib.sh bin/fm-remote-job-worker.sh "$FIX/root/bin/"
cp AGENTS.md "$FIX/root/AGENTS.md"
cat > "$FIX/root/bin/fm-identity-probe.sh" <<'SH'
#!/bin/bash
set -u
printf 'USER=%s\nLOGNAME=%s\nFM_REMOTE_JOB_ACTIVE=%s\nTOP_SECRET=%s\n' "${USER-<unset>}" "${LOGNAME-<unset>}" "${FM_REMOTE_JOB_ACTIVE-}" "${TOP_SECRET-<unset>}"
printf 'argv=<%s>\n' "$@"
while IFS= read -r line; do printf 'stdin=%s\n' "$line"; done
SH
chmod +x "$FIX/root/bin/"*.sh
git -C "$FIX/root" init -q
git -C "$FIX/root" add bin AGENTS.md
cat > "$FIX/lane.sh" <<'SH'
set -eu
. "$ROOT/bin/fm-remote-job-lib.sh"
fm_remote_job_stage "$ACCOUNT" "$REMOTE" "$INSTANCE" fm-identity-probe.sh 'two words' '$(never executed)' <<<'identity input'
HOME="$ACCOUNT" "$REMOTE/bin/fm-remote-job-worker.sh" --lane "$FM_REMOTE_JOB_ID"
fm_remote_job_wait "$ACCOUNT" "$FM_REMOTE_JOB_ID"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ]
cat "$FM_REMOTE_JOB_STDOUT"
SH
for mode in present absent empty; do
 echo "SCENARIO: real local remote-job lane, login identity $mode; arbitrary ambient secrets must not cross"
 case "$mode" in
 present) IDENTITY=(env USER=local-test-user LOGNAME=local-test-login) ;;
 absent) IDENTITY=(env -u USER -u LOGNAME) ;;
 empty) IDENTITY=(env USER= LOGNAME=) ;;
 esac
 OUT=$("${IDENTITY[@]}" ROOT="$ROOT" ACCOUNT="$FIX/account" REMOTE="$FIX/root" INSTANCE="$FIX/home" TOP_SECRET=must-not-cross FM_ROOT_OVERRIDE="$FIX/root" FM_REMOTE_JOB_STATE_ROOT="$FIX/state-$mode" FM_REMOTE_JOB_QUEUE_TIMEOUT=60 FM_REMOTE_JOB_TIMEOUT=30 bash "$FIX/lane.sh")
 printf '%s\n' "$OUT"
 if [ "$mode" = present ]; then
  grep -Fx 'USER=local-test-user' <<< "$OUT"; grep -Fx 'LOGNAME=local-test-login' <<< "$OUT"
 else
  grep -Fx 'USER=<unset>' <<< "$OUT"; grep -Fx 'LOGNAME=<unset>' <<< "$OUT"
 fi
 grep -Fx 'TOP_SECRET=<unset>' <<< "$OUT"
 grep -Fx 'FM_REMOTE_JOB_ACTIVE=1' <<< "$OUT"
 grep -Fx 'argv=<two words>' <<< "$OUT"
 grep -Fx 'argv=<$(never executed)>' <<< "$OUT"
 grep -Fx 'stdin=identity input' <<< "$OUT"
 echo "RESULT: $mode identity, isolated environment, argv and stdin passed"
done
