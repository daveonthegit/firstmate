import os,subprocess,pathlib,json,hashlib
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M74NFWCGKM5Y5147R1Y0W99W')
log=open(E/'live-scenarios.log','w',buffering=1)
results=[]
def emit(s): print(s,file=log,flush=True)
def run(args,home='p',extra=None,expected=0):
 env=dict(os.environ)
 for k in list(env):
  if k.startswith('FM_') and (k.endswith('_OVERRIDE') or k in ['FM_GATE_REFUSE_BYPASS','FM_HOME']): env.pop(k,None)
 env.update(FM_HOME=str(R/home),FM_ROOT_OVERRIDE=str(R),FM_SSH_BIN=str(R/'.live/ssh'),FM_PROCEVENT_CLAIM_ROOT=str(R/'.live/claims'),FM_SPAWN_NO_GUARD='1',TASKS_AXI_BACKEND='markdown')
 if extra: env.update(extra)
 emit('$ FM_HOME='+home+' '+' '.join(map(str,args)))
 p=subprocess.run(list(map(str,args)),env=env,cwd=R,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=100)
 emit(p.stdout+'[exit='+str(p.returncode)+']')
 if expected is not None: assert p.returncode==expected,(args,p.returncode,p.stdout)
 return p

def brief(id,scout=False,home='p'):
 args=['bin/fm-brief.sh',id,'sample']+(['--scout'] if scout else ['--mode','local-only','--journal'])
 run(args,home)
 p=R/home/'data'/id/'brief.md'
 p.write_text(p.read_text().replace('{TASK}','Read the disposable sample README and wait for a steer.').replace('{FIRSTMATE_SPEC}','Do not edit files.'))
 run(['tasks-axi','add',id,'Disposable scenario '+id,'--kind','scout' if scout else 'ship','--file',R/home/'data/backlog.md'],home)

def spawn(id,scout=False,home='p',extra=None,expected=0,host='loop'):
 args=['bin/fm-spawn.sh',id,'sample','--host',host]+(['--scout'] if scout else ['--mode','local-only','--yolo','off'])+['--harness','claude']
 return run(args,home,extra,expected)

def meta(id,home='p'):
 text=(R/home/'state'/f'{id}.meta').read_text(); emit('Persisted primary route:\n'+text)
 return dict(x.split('=',1) for x in text.splitlines() if '=' in x)

def state(id,home='p'):
 return run(['tasks-axi','show',id,'--file',R/home/'data/backlog.md'],home).stdout

def windows():
 p=subprocess.run(['tmux','-S',str(R/'l/tmux/tmux-501/fm-lab'),'list-windows','-a','-F','#{window_name}'],text=True,capture_output=True,check=True)
 return p.stdout.splitlines()

def scenario(name,fn):
 emit('\n=== '+name+' ===')
 try: fn(); results.append({'name':name,'result':'pass'})
 except Exception as e: emit('FAIL: '+repr(e)); results.append({'name':name,'result':'fail','error':repr(e)})
 (E/'live-results.json').write_text(json.dumps(results,indent=2))

def placement():
 emit((R/'.live/first-spawn.log').read_text())
 m=meta('t1'); assert m['remote_worker_host']=='loop' and m['remote_backend']=='tmux' and m['remote_target']=='firstmate:fm-t1'
 assert m['remote_home']==str(R/'w') and m['remote_root']==str(R)
 assert not any(k in m for k in ['project','worktree','remote_host'])
 assert 'state: in_flight' in state('t1')
 b=(R/'w/data/t1/brief.md').read_text(); emit('Host-rendered brief:\n'+b)
 assert str(R/'w/state/t1.status') in b and str(R/'w/data/t1/journal.md') in b and 'Verify the disposable sample README.' in b
 assert windows().count('fm-t1')==1
 assert not (R/'p/data/t1/launch-brief.md').exists()
 assert 'remote-worker-loop' in run(['bin/fm-procevent.sh','list']).stdout
 # Synthetic worker progress crosses the real fm-on -> OpenSSH -> controller event source.
 with open(R/'w/state/t1.status','a') as f: f.write('working [at=1794380000]: disposable loopback status proof\n')
 source=run(['bin/fm-procevent-remote-worker.sh','source','loop'])
 capture=E/'live-status-bundle.txt'; capture.write_text(source.stdout)
 run(['bin/fm-procevent-remote-worker.sh','ingest','loop',capture])
 out=(R/'p/state/t1.status').read_text(); emit('Mirrored primary status:\n'+out)
 assert 'disposable loopback status proof' in out

def capacity():
 brief('d1',True)
 p=spawn('d1',True,expected=75)
 assert 'no free place' in p.stdout
 assert 'state: queued' in state('d1')
 assert not (R/'p/state/d1.meta').exists() and not (R/'w/state/d1.remote-worker').exists()
 assert 'fm-d1' not in windows()

def retries():
 (R/'w/config/project-capacity').write_text('sample 3\n')
 brief('r1',True)
 (R/'.live/lose-next-result').touch()
 p=spawn('r1',True,expected=255)
 assert 're-run this same spawn' in p.stdout
 assert not (R/'p/state/r1.meta').exists() and (R/'w/state/r1.meta').exists()
 assert 'state: queued' in state('r1')
 assert windows().count('fm-r1')==1
 p=spawn('r1',True); assert 'already placed' in p.stdout
 m=meta('r1'); assert m['remote_target']=='firstmate:fm-r1' and m['remote_worker_host']=='loop'
 assert windows().count('fm-r1')==1 and 'state: in_flight' in state('r1')

def mirror_recovery():
 home='p2'; run(['bin/fm-lab-home.sh','create',R/home])
 for item in ['.tasks.toml','data/worker-hosts.md']:
  (R/home/item).write_text((R/'p'/item).read_text())
 (R/home/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
 (R/home/'state/.lock').write_text(str(os.getpid())+'\n')
 (R/home/'state/.last-watcher-beat').touch()
 (R/home/'state/.afk-contract').write_text('''version: 2
entered: 2026-11-10T01:00:00Z
entered_epoch: 1794272400
expected_return: -
reach_channels: none
reach_announced: No phone channel is configured.
spend_max_concurrent_workers: 1
confirmed: 2026-11-10T01:00:00Z
confirmed_epoch: 1794272400
words: |-
  Continue queued work.
''')
 run(['bin/fm-afk-contract.sh','validate'],home)
 brief('a1',False,home)
 (R/home/'state/procevent').touch()
 p=spawn('a1',home=home,extra={'FM_SUPERVISION_ACTOR':'branch'},expected=None)
 assert p.returncode!=0 and 'status mirror could not be armed' in p.stdout
 before=(R/home/'state/a1.meta').read_bytes(); assert meta('a1',home)['remote_target']=='firstmate:fm-a1'
 assert 'state: in_flight' in state('a1',home)
 brief('a2',False,home)
 p=spawn('a2',home=home,extra={'FM_SUPERVISION_ACTOR':'branch'},expected=None)
 assert p.returncode!=0 and 'caps concurrent workers at 1' in p.stdout
 assert not (R/home/'state/a2.meta').exists() and 'state: queued' in state('a2',home)
 (R/home/'state/procevent').unlink()
 p=spawn('a1',home=home,extra={'FM_SUPERVISION_ACTOR':'branch'})
 assert 'already placed' in p.stdout and windows().count('fm-a1')==1
 assert meta('a1',home)['remote_target']=='firstmate:fm-a1'
 assert 'remote-worker-loop' in run(['bin/fm-procevent.sh','list'],home).stdout

def refusals():
 p=spawn('d1',True,host='nonexistent',expected=None)
 assert p.returncode!=0 and "no worker host 'nonexistent'" in p.stdout
 p=run(['bin/fm-spawn.sh','d1','sample','--scout','--host','loop','--account','fixture'],expected=None)
 assert p.returncode!=0 and 'not forwarded' in p.stdout
 assert not (R/'p/state/d1.meta').exists() and 'state: queued' in state('d1')

def route_guards():
 before=(R/'p/state/t1.meta').read_bytes(); wins=windows()
 for id in ['t1','r1']:
  for target in [id,'fm-'+id,'remote:'+id]:
   for args in [['bin/fm-send.sh',target,'hello'],['bin/fm-peek.sh',target]]:
    p=run(args,expected=None); assert p.returncode!=0 and 'worker host loop' in p.stdout and 'not yet supported' in p.stdout
  for verb in ['interrupt','exit','relaunch']:
   p=run(['bin/fm-control.sh',id,verb],expected=None); assert p.returncode!=0 and 'worker host loop' in p.stdout
  for args in [['bin/fm-t3-answer.sh',id],['bin/fm-t3-answer.sh',id,'request','{}'],['bin/fm-teardown.sh',id]]:
   p=run(args,expected=None); assert p.returncode!=0 and 'worker host loop' in p.stdout and 'not yet supported' in p.stdout
  p=run(['bin/fm-crew-state.sh',id]); assert 'state: unknown' in p.stdout and 'placed on worker host loop' in p.stdout and 'worktree gone' not in p.stdout
 for args in [['bin/fm-spawn.sh','t1',str(R/'w/projects/sample'),'--mode','local-only','--yolo','off','--harness','claude'],['bin/fm-spawn.sh','t1','--relaunch','--harness','claude']]:
  p=run(args,expected=None); assert p.returncode!=0 and 'task placed on worker host loop' in p.stdout
 assert (R/'p/state/t1.meta').read_bytes()==before and windows()==wins
 assert 'state: in_flight' in state('t1')
 emit('Primary route bytes and actual tmux windows unchanged after all refused operations.')

scenario('Ship placement publishes remote-only route, host-rendered brief, backlog transition and working status mirror over real loopback SSH',placement)
scenario('Full loopback host defers a new scout with exit 75 and leaves it queued without a route or endpoint',capacity)
scenario('A scout SSH result lost after real launch is retried without a duplicate and the existing route is published',retries)
scenario('Away mirror-arm recovery at spend cap 1 reuses the existing worker while rejecting new work',mirror_recovery)
scenario('Unknown host and unforwardable account pin refuse before placement and preserve queued state',refusals)
scenario('Placed ship and scout refuse unsupported local operations; spawn and relaunch preserve the remote record and actual windows',route_guards)
emit('\nRESULTS\n'+json.dumps(results,indent=2)); log.close()
print(json.dumps(results,indent=2))
