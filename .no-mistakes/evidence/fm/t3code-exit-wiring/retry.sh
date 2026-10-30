#!/bin/bash
set -eu
ROOT=$PWD; LAB=$ROOT/.test-t3-live
export FM_HOME=$LAB/home
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
T=$(awk -F= '$1=="t3_thread_id"{print $2}' "$FM_HOME/state/t3live.meta")
rm -f "$LAB/proxy-port"
node "$LAB/proxy.mjs" > "$LAB/proxy.log" 2>&1 &
P=$!
cp "$FM_HOME/config/t3code-token" "$LAB/original-token"
trap 'kill "$P" 2>/dev/null || true; wait "$P" 2>/dev/null || true; cp "$LAB/original-token" "$FM_HOME/config/t3code-token"; rm -f "$LAB/original-token"' EXIT
while [ ! -f "$LAB/proxy-port" ]; do sleep .2; done
printf 'Reply exactly READY. Do not use tools or modify any file.\n' > "$LAB/message"
bin/fm-t3-mcp.mjs send --thread "$T" --message-file "$LAB/message" --client-request-id "scratch-reopen-first-$$"
bin/fm-t3-mcp.mjs wait --thread "$T" --timeout-ms 60000
python3 - <<'PY'
import json,os
p=os.environ['FM_HOME']+'/config/'
c=json.load(open(p+'t3code-token'));c['origin']='http://127.0.0.1:'+open('.test-t3-live/proxy-port').read()
f=p+'t3code-token';open(f,'w').write(json.dumps(c));os.chmod(f,0o600)
PY
export FM_T3CODE_TOKEN_FILE=$FM_HOME/config/t3code-token
set +e
bin/fm-control.sh t3live exit
rc=$?
set -e
[ "$rc" = 1 ]
# Age the persisted retry record; no clock or server state is changed.
touch -t 202001010000 "$FM_HOME/state/t3code-stops/"*
# The real server opens a different provider session after the first stop.
bin/fm-t3-mcp.mjs send --thread "$T" --message-file "$LAB/message" --client-request-id "scratch-reopen-second-$$"
bin/fm-t3-mcp.mjs wait --thread "$T" --timeout-ms 60000
bin/fm-control.sh t3live exit
# If replay preserved that newer session, a fresh exit must still detach it.
bin/fm-control.sh t3live exit
bin/fm-control.sh t3live exit
bin/fm-t3-mcp.mjs state --thread "$T"
python3 - <<'PY'
print(open('.test-t3-live/proxy.log').read())
PY
