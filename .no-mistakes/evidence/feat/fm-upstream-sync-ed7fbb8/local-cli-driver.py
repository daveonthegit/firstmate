import os,json,subprocess,pathlib,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M7B0601XBFMBS0XPWMER9J4Q'); L=R/'.test-phase/live'; L.mkdir()
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','GROK_AGENT','GROK_HOOK_EVENT','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_ENV','HERDR_SESSION','HERDR_PANE_ID','HERDR_SOCKET_PATH','FM_BACKEND']:env.pop(k,None)
log=[]
def run(args,extra={},payload=None):
 p=subprocess.run(args,env=env|extra,input=payload,text=True,capture_output=True,timeout=45)
 log.append('$ '+ ' '.join(map(str,args))+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 return p
try:
 # Public Stop-hook protocol, using a disposable plain checkout and synthetic transcript.
 P=L/'primary'; run(['git','clone','--quiet','--no-hardlinks',str(R),str(P)])
 (P/'state').mkdir(); (P/'config').mkdir(); T=P/'transcript.jsonl'
 base={'FM_HOME':str(P),'FM_ROOT_OVERRIDE':str(P)}
 def hook(tokens):
  T.write_text(json.dumps({'message':{'usage':{'input_tokens':tokens,'cache_read_input_tokens':0,'cache_creation_input_tokens':0}}})+'\n')
  return run([str(R/'bin/fm-stow-guard.sh')],base,json.dumps({'session_id':'live-validation','transcript_path':str(T)}))
 assert hook(1200).stdout==''
 (P/'config/stow-guard').write_text('tokens=1000\n')
 assert json.loads(hook(1200).stdout)['decision']=='block'
 assert hook(1200).stdout==''
 assert hook(100).stdout==''
 assert json.loads(hook(1200).stdout)['decision']=='block'
 log.append('OBSERVED: opt-out is silent; crossing blocks; repeated stop is silent; low usage rearms next crossing.\n')
 # Real host probes, synthetic local/worker-host task records.
 H=L/'home';run([str(R/'bin/fm-lab-home.sh'),'create',str(H)])
 (H/'config/lane-capacity').write_text('auto\nmax-lanes 2\n')
 for i in (1,2): (H/f'state/remote{i}.meta').write_text(f'project=demo\nkind=ship\nremote_worker_host=lab-worker\nremote_task_id=remote{i}\n')
 p=run([str(R/'bin/fm-capacity.sh'),'--json'],{'FM_HOME':str(H)})
 data=json.loads(p.stdout);assert data['lanes']['count']==0 and data['lanes']['placed']==2,data
 assert data['cap']['status']=='ok' and isinstance(data['cap']['target'],int),data
 (E/'capacity-remote-records.json').write_text(p.stdout)
 (H/'state/local.meta').write_text('project=demo\nkind=ship\n')
 p=run([str(R/'bin/fm-capacity.sh'),'--json'],{'FM_HOME':str(H)}); data=json.loads(p.stdout)
 assert data['lanes']['count']==1 and data['lanes']['placed']==2,data
 # Malformed adaptive config is rejected, not treated as spare capacity.
 (H/'config/lane-capacity').write_text('auto\nmax-lanes nonsense\nadmit-spawns\n')
 p=run([str(R/'bin/fm-capacity.sh'),'--spawn-gate'],{'FM_HOME':str(H)});assert p.returncode!=0
 # Remote dispatch conflict must fail before any host exists/contact occurs.
 (H/'config/crew-dispatch.json').write_text('{}\n')
 (H/'data/d1').mkdir();(H/'data/d1/brief.md').write_text('# Task\n\n## Captain\'s intent\n\nExercise dispatch refusal.\n\n## Firstmate spec\n\nNo launch is authorized.\n\nDelivery contract: mode=local-only\n')
 (H/'data/d1/dispatch-resolution.json').write_text(json.dumps({'task':'d1','status':'clear','profile':{'harness':'codex'}}))
 p=run([str(R/'bin/fm-spawn.sh'),'d1','demo','--host','not-configured','--harness','claude','--mode','local-only','--yolo','off'],{'FM_HOME':str(H)})
 assert p.returncode!=0 and 'launch flags do not match the clear dispatch selection' in p.stdout+p.stderr
 assert not (H/'state/d1.meta').exists()
 log.append('OBSERVED: real capacity excludes placed workers, counts local workers, publishes a measured target, rejects malformed config; conflicting remote dispatch is refused before routing.\n')
finally:
 (E/'local-cli-transcript.log').write_text('\n'.join(log));shutil.rmtree(L)
