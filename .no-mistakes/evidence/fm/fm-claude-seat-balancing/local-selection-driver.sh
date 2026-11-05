#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB="$ROOT/.test-seat-tmp"
export FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" FM_BACKEND_CONFIG_DIR="$LAB/home/config"
mkdir -p "$FM_BACKEND_CONFIG_DIR" "$FM_STATE_OVERRIDE" "$LAB/profile-a" "$LAB/profile-b" "$LAB/project"
. "$ROOT/bin/backends/t3code.sh"
export FM_T3CODE_QUOTA_SNAPSHOT="$LAB/quota.json"
T3CODE_TELEMETRY_ENABLED=false t3 serve --host 127.0.0.1 --port 47863 --base-dir "$LAB/t3" --no-browser > "$LAB/t3-server.log" 2>&1 & server=$!
cleanup() { kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; }
trap cleanup EXIT
sleep 15
node --input-type=module <<'JS'
import fs from 'node:fs';
const a=JSON.parse(fs.readFileSync('.test-seat-tmp/auth.json'));
const env=JSON.parse(fs.readFileSync('.test-seat-tmp/t3_environment_read.json'));
fs.writeFileSync('.test-seat-tmp/home/config/t3code-token',JSON.stringify({origin:'http://127.0.0.1:47863',access_token:a.token,expires_at:Date.parse(a.expiresAt),environment_id:env.environmentId}),{mode:0o600});
JS
fm_backend_t3code_mcp status
project=unused-explicit-model
export PROJECT_ID=$project
node --input-type=module <<'JS'
import {McpSession} from './bin/fm-t3-mcp.mjs';import fs from 'node:fs';
const a=JSON.parse(fs.readFileSync('.test-seat-tmp/auth.json'));const s=new McpSession('http://127.0.0.1:47863',a.token);
try{await s.open();const c=await s.call('orchestrator_capabilities',{});console.log('Disposable real T3 Claude catalog:',JSON.stringify(c.providers.filter(p=>p.driverKind==='claudeAgent').map(p=>({instance:p.providerInstanceId,constraints:p.constraints}))));}finally{await s.close();}
JS
printf 'claude=unconfigured-seat-a %s/profile-a\nclaude=claudeAgent %s/profile-b\n' "$LAB" "$LAB" > "$FM_BACKEND_CONFIG_DIR/t3code-instances"
snapshot() {
  node - "$LAB" "$1" <<'JS'
const fs=require('fs');const [lab,mode]=process.argv.slice(2);const lane=(path,scopes)=>({provider:'claude',accountLocator:{path},quotaSemantics:{status:'known',effectiveAvailability:scopes}});const scope=(name,p,rem=70)=>({scope:name,selection:{spendPriority:p},effectivePercentRemaining:rem,runway:{status:rem===0?'exhausted_now':'through_reset'}});let a=[scope('all_models',.9)],b=[scope('all_models',.3)];if(mode==='fable-exhausted')a.push(scope('model:fable',.9,0));if(mode==='unknown'){fs.writeFileSync(lab+'/quota.json','{}');process.exit(0)}fs.writeFileSync(lab+'/quota.json',JSON.stringify({providers:[lane(lab+'/profile-a',a),lane(lab+'/profile-b',b)]}));
JS
}
assert_choice() { local out=$1 expected=$2; printf '%s\n' "$out"; node -e 'const d=JSON.parse(process.argv[1]);if(d.instance!==process.argv[2])throw Error(`expected ${process.argv[2]}, got ${d.instance}`)' "$out" "$expected"; }
printf '\nSCENARIO: quota prefers the seat with higher spend priority\n'
snapshot healthy
assert_choice "$(fm_backend_t3code_instance_choose claude claude-sonnet-5-5 "$project")" unconfigured-seat-a
printf '\nSCENARIO: family quota bounds constrain explicit model choice\n'
snapshot fable-exhausted
assert_choice "$(fm_backend_t3code_instance_choose claude claude-fable-5-1 "$project")" claudeAgent
printf '\nSCENARIO: selected seat validates against real catalog independently of invalid unselected first seat\n'
selection=$(fm_backend_t3code_model_selection claude claude-fable-5-1 high "$project" claudeAgent)
printf 'Resolved selection: %s\n' "$selection"
node -e 'const d=JSON.parse(process.argv[1]);if(d.instanceId!=="claudeAgent"||d.model!=="claude-fable-5-1"||!d.options.some(o=>o.id==="effort"&&o.value==="high"))throw Error("effort not preserved")' "$selection"
set +e
fm_backend_t3code_model_selection claude claude-fable-5-1 high "$project" unconfigured-seat-a
rc=$?
set -e
printf 'Selected unusable seat refusal exit=%s (expected nonzero)\n' "$rc"
[ "$rc" -ne 0 ]
printf '\nSCENARIO: concurrent unknown-quota choices balance six-to-six\n'
snapshot unknown
rm -f "$FM_STATE_OVERRIDE/t3code-rotation-claude"
pids=()
for i in {1..12}; do fm_backend_t3code_instance_choose claude claude-fable-5-1 "$project" > "$LAB/concurrent-$i.json" & pids+=("$!"); done
for p in "${pids[@]}"; do wait "$p"; done
node - "$LAB" <<'JS'
const fs=require('fs'),lab=process.argv[2],counts={};for(let i=1;i<=12;i++){const d=JSON.parse(fs.readFileSync(`${lab}/concurrent-${i}.json`));counts[d.instance]=(counts[d.instance]||0)+1;}console.log('Concurrent selections:',JSON.stringify(counts));if(counts.claudeAgent!==6||counts['unconfigured-seat-a']!==6)throw Error('unbalanced rotation');
JS
printf '\nSCENARIO: shared-quota mode ignores model-exhausted snapshot and rotates\n'
printf '{"shared_quota":true}\n' > "$FM_BACKEND_CONFIG_DIR/crew-dispatch.json"
snapshot fable-exhausted
rm -f "$FM_STATE_OVERRIDE/t3code-rotation-claude"
assert_choice "$(fm_backend_t3code_instance_choose claude claude-fable-5-1 "$project")" unconfigured-seat-a
assert_choice "$(fm_backend_t3code_instance_choose claude claude-fable-5-1 "$project")" claudeAgent
printf '\nSCENARIO: actual usage marks veto until expiry even with shared quota\n'
fm_backend_t3code_mark_exhausted unconfigured-seat-a
assert_choice "$(fm_backend_t3code_instance_choose claude claude-fable-5-1 "$project")" claudeAgent
printf '%s\n' "$(( $(date +%s) - 18001 ))" > "$FM_STATE_OVERRIDE/t3code-exhausted/unconfigured-seat-a"
assert_choice "$(fm_backend_t3code_instance_choose claude claude-fable-5-1 "$project")" unconfigured-seat-a
printf '\nSCENARIO: malformed quota policy refuses and corrected policy retries\n'
printf '{"shared_quota":"true"}\n' > "$FM_BACKEND_CONFIG_DIR/crew-dispatch.json"
set +e
fm_backend_t3code_instance_choose claude claude-fable-5-1 "$project"
rc=$?
set -e
printf 'Malformed shared_quota refusal exit=%s (expected nonzero)\n' "$rc"
[ "$rc" -ne 0 ]
printf '{"shared_quota":true}\n' > "$FM_BACKEND_CONFIG_DIR/crew-dispatch.json"
assert_choice "$(fm_backend_t3code_instance_choose claude claude-fable-5-1 "$project")" claudeAgent
printf '\nLOCAL CHOOSER SCENARIOS COMPLETE; no agent turn or production credentials used.\n'
