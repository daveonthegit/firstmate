#!/usr/bin/env bash
set -u
R=$PWD
D="$R/.gate-lab"
E=~/.no-mistakes/evidence/01M6PKMN43MHXMXK8YNN8EX7Y3
mkdir -p "$D/code"
for n in bin docs .agents; do [ -e "$D/code/$n" ] || ln -s "$R/$n" "$D/code/$n"; done
[ -f "$D/primary/.fm-lab-home" ] || bin/fm-lab-home.sh create "$D/primary"
[ -f "$D/mate/.fm-lab-home" ] || bin/fm-lab-home.sh create "$D/mate"
[ -e "$D/mate/bin" ] || ln -s "$R/bin" "$D/mate/bin"
printf '# Disposable validation home\nDo not start supervision or run fleet lifecycle commands. Respond only with READY.\n' > "$D/mate/AGENTS.md"
printf 'gh-live-t3-pin\n' > "$D/mate/.fm-secondmate-home"
printf 'For this disposable validation, respond READY and perform no other actions.\n' > "$D/mate/data/charter.md"
printf 'BG-Media-LLC davidx-secco\ndaveonthegit daveonthegit\n' > "$D/mate/config/gh-accounts"
printf 'config/\ndata/\nstate/\nprojects/\n.claude/\n' > "$D/mate/.gitignore"
git -C "$D/mate" init -q -b lab
# The synthetic origin reproduces the reported firstmate-owner mismatch; no fetch should occur.
git -C "$D/mate" remote remove origin 2>/dev/null || :
git -C "$D/mate" remote add origin https://github.com/daveonthegit/firstmate.git
mkdir -p "$D/mate/.claude"
printf '{"env":{"FM_GH_ACCOUNT":"daveonthegit","FM_T3CODE_ENV_KEYS":"FM_GH_ACCOUNT"}}\n' > "$D/mate/.claude/settings.local.json"
cp "$D/t3-token" "$D/primary/config/t3code-token"
T3CODE_TELEMETRY_ENABLED=false t3 serve --base-dir "$D/t3" --host 127.0.0.1 --port 19347 --no-browser > "$D/t3-server.log" 2>&1 & p=$!
cleanup() { kill "$p" 2>/dev/null || :; wait "$p" 2>/dev/null || :; }
trap cleanup EXIT
ready=0
for i in {1..30}; do
  if FM_HOME="$D/primary" node bin/fm-t3-mcp.mjs status > "$E/t3-local-status.json" 2> "$D/status.err"; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { tail -10 "$D/status.err"; exit 1; }
node --input-type=module - "$D/t3-token" > "$D/catalog.json" <<'JS'
import {McpSession,readCredential} from './bin/fm-t3-mcp.mjs';
const c=readCredential(process.argv[2]); const s=new McpSession(c.origin,c.access_token); await s.open(); try {console.log(JSON.stringify(await s.call('orchestrator_capabilities',{}),null,2))} finally {await s.close()}
JS
model=$(python3 - "$D/catalog.json" <<'PY'
import json,sys
for p in json.load(open(sys.argv[1]))['providers']:
 if p['providerInstanceId']=='claudeAgent':
  print(p['models'][0]['id']); break
PY
)
printf 'real catalog model=%s\n' "$model"
env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$D/primary" FM_ROOT_OVERRIDE="$D/code" FM_SPAWN_NO_GUARD=1 "$D/code/bin/fm-spawn.sh" gh-live-t3-pin "$D/mate" --harness claude --model "$model" --backend t3code --secondmate > "$E/t3-live-spawn.log" 2>&1
rc=$?
printf 'spawn exit=%s\n' "$rc"
if [ "$rc" = 0 ]; then
  python3 - "$D/mate/.claude/settings.local.json" "$D/primary/state/gh-live-t3-pin.meta" > "$E/t3-live-account-result.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); meta=dict(l.rstrip('\n').split('=',1) for l in open(sys.argv[2]) if '=' in l)
r={'settingsEnv':s.get('env',{}),'metadataAccount':meta.get('gh_account'),'thread':meta.get('t3_thread_id')}
print(json.dumps(r,indent=2))
assert 'FM_GH_ACCOUNT' not in r['settingsEnv']
assert r['metadataAccount'] is None
assert '/gh-bin:' not in r['settingsEnv']['PATH']
PY
  rc=$?
  thread=$(awk -F= '$1=="t3_thread_id" {print $2}' "$D/primary/state/gh-live-t3-pin.meta")
  FM_HOME="$D/primary" node bin/fm-t3-mcp.mjs session-stop --thread "$thread" > "$E/t3-session-stop.json" 2>&1
  sr=$?
  FM_HOME="$D/primary" node bin/fm-t3-mcp.mjs archive --thread "$thread" > "$E/t3-archive.json" 2>&1
  ar=$?
  printf 'assertions=%s session-stop=%s archive=%s\n' "$rc" "$sr" "$ar"
fi
tail -15 "$E/t3-live-spawn.log"
exit "$rc"
