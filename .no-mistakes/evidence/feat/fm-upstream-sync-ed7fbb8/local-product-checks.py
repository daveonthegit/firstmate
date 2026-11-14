import json, os, pathlib, subprocess, time
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M7CF729TEKTFDZA3QD5ECVS9')
P=ROOT/'.live-validation'
H=P/'home'
for d in ['state','config','data','projects']:(H/d).mkdir(parents=True,exist_ok=True)
env=dict(os.environ,FM_HOME=str(H),FM_ROOT_OVERRIDE=str(P))
for k in ['FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','GROK_AGENT','GROK_HOOK_EVENT']:env.pop(k,None)
log=[]
def run(name, argv, payload=None, extra=None, rc=0):
    result=subprocess.run(argv,input=payload,text=True,capture_output=True,env=dict(env,**(extra or {})),timeout=60)
    log.append(f'## {name}\n$ '+ ' '.join(map(str,argv))+f'\nexit={result.returncode}\n{result.stdout}{result.stderr}')
    (E/'local-product-transcript.md').write_text('\n'.join(log))
    assert result.returncode==rc,(name,result)
    return result.stdout
T=P/'transcript.jsonl'
def usage(n):T.write_text(json.dumps({'message':{'usage':{'input_tokens':n,'cache_read_input_tokens':0,'cache_creation_input_tokens':0}}})+'\n')
payload=json.dumps({'session_id':'disposable-primary','transcript_path':str(T)})
cmd=[str(P/'bin/fm-stow-guard.sh')]
usage(310000)
assert run('Absent opt-in: no block and no state',cmd,payload)==''
assert not (H/'state/.stow-guard.json').exists()
(H/'config/stow-guard').touch()
x=json.loads(run('Opted-in Stop at 310000 tokens requests stow',cmd,payload))
assert x['decision']=='block' and '/stow' in x['reason']
assert run('Repeated Stop in same crossing is silent',cmd,payload)==''
usage(100000)
assert run('Low-context Stop rearms the crossing',cmd,payload)==''
usage(310000)
assert json.loads(run('Next high-context crossing asks again',cmd,payload))['decision']=='block'
for key in ['GROK_AGENT','GROK_HOOK_EVENT']:
    (H/'state/.stow-guard.json').unlink(missing_ok=True)
    assert run('Foreign-host guard: '+key,cmd,payload,{key:'1'})==''
    assert not (H/'state/.stow-guard.json').exists()
assert run('Cursor payload stays inert',cmd,json.dumps({'cursor_version':'1','transcript_path':str(T)}))==''
assert not (H/'state/.stow-guard.json').exists()
T.write_text(json.dumps({'timestamp':'2026-01-01T00:00:00Z','message':{'content':[{'type':'tool_use','name':'Skill','input':{'skill':'stow'}}]}})+'\n')
assert json.loads(run('A stow older than 24h requests a new full pass',cmd,payload,{'FM_STOW_GUARD_NOW':'1767312001'}))['decision']=='block'
assert run('Age request is throttled for one hour',cmd,payload,{'FM_STOW_GUARD_NOW':'1767312002'})==''
# The actual worktree is intentionally not a plain primary checkout.
assert run('Task worktree scope refuses a primary Stop block',[str(ROOT/'bin/fm-stow-guard.sh')],payload,{'FM_ROOT_OVERRIDE':str(ROOT)})==''
(H/'config/lane-capacity').write_text('auto\nmax-lanes 3\n')
run('Real host adaptive capacity report',[str(ROOT/'bin/fm-capacity.sh')])
cap=json.loads(run('Real host adaptive capacity JSON',[str(ROOT/'bin/fm-capacity.sh'),'--json']))
assert cap
run('Real host publishes adaptive budget and status',[str(ROOT/'bin/fm-capacity.sh'),'--publish'])
log.append('## Persisted lane-capacity.json public report (including cap.status)\n'+(H/'state/lane-capacity.json').read_text())
run('Real local placement uses measured adaptive report',[str(ROOT/'bin/fm-placement.sh'),'disposable','--local-dir',str(P)])
(E/'local-product-transcript.md').write_text('\n'.join(log))
print('Stow lifecycle and foreign-host boundaries, adaptive capacity/placement executed successfully.')
