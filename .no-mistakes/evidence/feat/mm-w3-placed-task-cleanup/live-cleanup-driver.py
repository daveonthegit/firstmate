import os, pathlib, subprocess, sys, time, base64, json, shutil
R=pathlib.Path.cwd(); D=R/'.test-tmp/live'; D.mkdir(); E=pathlib.Path('~/.no-mistakes/evidence/01M75SDGMKFHHMGR1K4ST1VQD3'); log=open(E/'live-cleanup.log','w',buffering=1)
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or k in ('TMUX','NO_MISTAKES_GATE'): env.pop(k,None)
env['PATH']=os.environ['PATH']; env['TMPDIR']=str(R/'.test-tmp'); env.update(HOME=str(D/'user'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',TREEHOUSE_ROOT=str(D/'pool'))
children=[]; sock=str(R/'.t')
def run(args, extra=None, check=True):
 p=subprocess.run([str(a) for a in args],env={**env,**(extra or {})},stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'\nexit={p.returncode}\n')
 if check and p.returncode: raise RuntimeError(p.stdout)
 return p
try:
 for h in ('primary','host'):
  run([R/'bin/fm-lab-home.sh','create',D/h]); (D/h/'config/backend').write_text('tmux\n')
 (D/'host/.fm-worker-host').touch(); (D/'host/config/backlog-backend').write_text('manual\n')
 for h in ('primary','host'):
  (D/h/'state/.last-watcher-beat').touch(); (D/h/'state/.lock').write_text(str(os.getpid())+'\n')
 (D/'primary/.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
 (D/'primary/data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
 (D/'primary/data/worker-hosts.md').write_text(f'# Worker hosts\n\n- local - disposable localhost (host: fm-local; root: {R}; home: {D}/host; added 2026-11-10)\n')
 # This SSH forced-command launcher replaces only the remote installation/login shell;
 # it executes the real worker-control public command, not a fake cleanup implementation.
 launcher=D/'ssh-launch.py'
 launcher.write_text('''#!/usr/bin/python3
import os,base64,shlex,sys
r='''+repr(str(R))+'''
d='''+repr(str(D))+'''
a=shlex.split(os.environ['SSH_ORIGINAL_COMMAND'])
assert a[:2]==['fm-remote-entrypoint.sh','1']
root=base64.b64decode(a[2]).decode(); home=base64.b64decode(a[3]).decode()
assert root==r and home==d+'/host'
argv=[x.decode() for x in base64.b64decode(a[4]).split(b'\\0') if x]
assert argv[0]=='fm-remote-worker-control.sh'
e=os.environ.copy()
for k in list(e):
 if k.startswith(('FM_','HERDR_','TASKS_AXI_')) or k in ('TMUX','NO_MISTAKES_GATE'): e.pop(k,None)
e.update(FM_HOME=home,FM_ROOT_OVERRIDE=r,HOME=d+'/user',PATH='''+repr(env['PATH'])+''',TMPDIR=r+'/.test-tmp',TREEHOUSE_ROOT=d+'/pool',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',TMUX='''+repr(sock+',0,0')+''')
import subprocess,time,pathlib
p=subprocess.run([root+'/bin/'+argv[0]]+argv[1:],env=e)
if argv[1]=='teardown' and pathlib.Path(d+'/lose-answer').exists(): sys.exit(255)
if argv[1]=='teardown' and pathlib.Path(d+'/pause').exists():
 pathlib.Path(d+'/host-finished').touch()
 while not pathlib.Path(d+'/release-host').exists(): time.sleep(.05)
sys.exit(p.returncode)
'''); launcher.chmod(0o755); (D/'user').mkdir()
 run(['git','init','-q','-b','main',D/'project']); (D/'project/README.md').write_text('Disposable local project\n'); run(['git','-C',D/'project','add','README.md']); run(['git','-C',D/'project','commit','-qm','initial'])
 cfg=R/'.test-tmp/sshd/config'; old=cfg.read_text(); cfg.write_text(old+f'ForceCommand {launcher}\n')
 server=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(cfg)],stdout=log,stderr=log); children.append(server); time.sleep(.5)
 adapter=D/'ssh'; adapter.write_text('#!/bin/sh\nexec /usr/bin/ssh -F '+str(D/'ssh-config')+' "$@"\n'); adapter.chmod(0o755)
 (D/'ssh-config').write_text(f'Host fm-local\n HostName 127.0.0.1\n Port 22487\n IdentityFile {R}/.test-tmp/sshd/client\n UserKnownHostsFile {R}/.test-tmp/sshd/known_hosts\n StrictHostKeyChecking yes\n BatchMode yes\n')
 run(['tmux','-S',sock,'new-session','-d','-s','fm-lab-cleanup','sleep 900'])
 pe={'FM_HOME':str(D/'primary'),'FM_ROOT_OVERRIDE':str(R),'FM_SSH_BIN':str(adapter),'TASKS_AXI_BACKEND':'markdown','TMUX':sock+',0,0','FM_PROCEVENT_CLAIM_ROOT':str(D/'claims')}
 def seed(id,kind='ship'):
  run(['tasks-axi','add',id,'Disposable '+id,'--kind',kind,'--file',D/'primary/data/backlog.md'])
  run(['tasks-axi','start',id,'--file',D/'primary/data/backlog.md'])
  (D/f'primary/state/{id}.meta').write_text(f'kind={kind}\nmode=local-only\nspawn_gen=live-{id}\nremote_worker_host=local\nremote_root={R}\nremote_home={D}/host\nremote_target=fm-lab-cleanup:fm-{id}\n')
  (D/f'primary/state/{id}.status').write_text('working: synthetic local task\n')
  wt=run(['bash','-c','cd "$1" && treehouse get --lease --no-fetch -b "$2"','lab',D/'project','fm-'+id]).stdout.strip().splitlines()[-1]
  run(['tmux','-S',sock,'new-window','-d','-t','fm-lab-cleanup','-n','fm-'+id,'sleep 900'])
  (D/f'host/state/{id}.meta').write_text(f'kind={kind}\nmode=local-only\nbackend=tmux\nwindow=fm-lab-cleanup:fm-{id}\nendpoint_task_id={id}\nworktree={wt}\nproject={D}/project\nspawn_gen=live-{id}\n')
  (D/f'host/state/{id}.remote-worker').write_text('placed_at=123\n')
  (D/f'host/data/{id}').mkdir(); (D/f'host/data/{id}/journal.md').write_text(f'Final journal for {id}\n')
  run([R/'bin/fm-procevent-remote-worker.sh','arm','local'],pe)
  cr=D/'primary/state/remote-workers/local'; cr.mkdir(exist_ok=True); (cr/(id+'.cursor')).write_text('schema=fm-remote-worker-cursor.v1\noffset=0\nprefix_sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n')
 def td(id,*args): return run([R/'bin/fm-teardown.sh',id,*args],pe,False)
 def sources(): return run([R/'bin/fm-procevent.sh','list'],pe).stdout
 def state(id): return run(['tasks-axi','show',id,'--file',D/'primary/data/backlog.md']).stdout
 seed('live-ship'); p=td('live-ship'); assert p.returncode==0,p.stdout
 assert not (D/'host/state/live-ship.meta').exists(); assert not (D/'primary/state/live-ship.meta').exists(); assert 'state: done' in state('live-ship'); assert (D/'primary/data/live-ship/journal.md').read_text()=='Final journal for live-ship\n'
 log.write('LIVE ship: host and primary records retired; final journal fetched; backlog done\n')
 seed('live-down'); server.terminate(); server.wait(); p=td('live-down'); assert p.returncode==255; assert (D/'primary/state/live-down.meta').exists(); assert (D/'host/state/live-down.meta').exists(); assert 'state: in_flight' in state('live-down'); log.write('LIVE unavailable SSH: exit 255; both homes preserved; backlog in_flight\n')
 server=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(cfg)],stdout=log,stderr=log); children.append(server); time.sleep(.5)
 p=td('live-down'); assert p.returncode==0; assert 'state: done' in state('live-down'); log.write('LIVE SSH recovery: retry converged to done\n')
 seed('live-scout','scout'); p=td('live-scout'); assert p.returncode!=0 and 'has no report' in p.stdout
 (D/'host/data/live-scout/report.md').write_text('Initial findings\n'); p=td('live-scout'); assert p.returncode!=0 and 'captain-call completion gate' in p.stdout
 (D/'host/data/live-scout/report.md').write_text('Final findings\n'); run([R/'bin/fm-captain-hold.sh','complete','live-scout','--none'],pe)
 p=td('live-scout'); assert p.returncode==0,p.stdout; assert (D/'primary/data/live-scout/report.md').read_text()=='Final findings\n'; assert 'state: done' in state('live-scout'); log.write('LIVE scout: missing report and inventory refused; retry fetched refreshed report, then closed both legs\n')
 seed('live-lost'); (D/'lose-answer').touch(); p=td('live-lost'); assert p.returncode==255 and 'unknown' in p.stdout; assert (D/'primary/state/live-lost.meta').exists(); assert not (D/'host/state/live-lost.meta').exists(); assert 'state: in_flight' in state('live-lost'); assert 'remote-worker-local' in sources(); (D/'lose-answer').unlink(); p=td('live-lost'); assert p.returncode==0 and 'no task record remains' in p.stdout; assert 'state: done' in state('live-lost'); log.write('LIVE lost answer: injected SSH-channel exit 255 after real host cleanup preserved primary; retry completed without host records\n')
 seed('live-dirty'); hm=(D/'host/state/live-dirty.meta').read_text(); wt=pathlib.Path(next(x.split('=',1)[1] for x in hm.splitlines() if x.startswith('worktree='))); (wt/'scratch').write_text('unlanded synthetic work\n'); p=td('live-dirty'); assert p.returncode!=0 and 'REFUSED' in p.stdout; assert (wt/'scratch').exists(); assert (D/'primary/state/live-dirty.meta').exists(); assert (D/'host/state/live-dirty.meta').exists(); assert 'state: in_flight' in state('live-dirty'); (D/'host/data/live-dirty/journal.md').write_text('Refreshed final journal\n'); (wt/'scratch').unlink(); p=td('live-dirty'); assert p.returncode==0; assert (D/'primary/data/live-dirty/journal.md').read_text()=='Refreshed final journal\n'; log.write('LIVE dirty guard: preserved scratch and both records; clean retry fetched final journal and returned actual Treehouse slot\n')
 seed('live-drift'); reg=D/'primary/data/worker-hosts.md'; original=reg.read_text(); reg.write_text(original.replace(str(D/'host'),str(D/'elsewhere'))); p=td('live-drift'); assert p.returncode!=0 and 'no longer matches' in p.stdout; assert (D/'host/state/live-drift.meta').exists(); assert 'state: in_flight' in state('live-drift'); reg.write_text(original); assert td('live-drift').returncode==0; log.write('LIVE route guard: registry drift refused; original route restored and cleaned up\n')
 seed('live-sibling-a'); seed('live-sibling-b'); assert td('live-sibling-a').returncode==0; assert 'remote-worker-local' in sources(); assert (D/'primary/state/live-sibling-b.meta').exists(); assert td('live-sibling-b').returncode==0; assert 'remote-worker-local' not in sources(); log.write('LIVE siblings: first cleanup kept shared mirror, last cleanup retired mirror\n')
 seed('live-lock'); (D/'pause').touch(); cf=open(D/'lock-cleanup.out','w'); cp=subprocess.Popen([str(R/'bin/fm-teardown.sh'),'live-lock'],env={**env,**pe},stdout=cf,stderr=subprocess.STDOUT); children.append(cp)
 deadline=time.time()+30
 while not (D/'host-finished').exists():
  assert time.time()<deadline,'host cleanup timeout'; time.sleep(.05)
 lockscript='source "$1/bin/fm-wake-lib.sh"; source "$1/bin/fm-procevent-remote-worker.sh"; hold() { touch "$3/lock-held"; while [ ! -f "$3/unlock" ]; do sleep .05; done; }; fm_remote_worker_with_lifecycle_lock "$2" local hold "$1" "$2" "$3"'
 lp=subprocess.Popen(['bash','-c',lockscript,'lab',str(R),str(D/'primary/state'),str(D)],env={**env,**pe},stdout=log,stderr=log); children.append(lp)
 while not (D/'lock-held').exists():
  assert time.time()<deadline,'lock timeout'; time.sleep(.05)
 (D/'release-host').touch(); time.sleep(1); assert cp.poll() is None; assert (D/'primary/state/live-lock.meta').exists(); assert (D/'primary/state/live-lock.status').exists(); (D/'unlock').touch(); assert lp.wait(timeout=20)==0; assert cp.wait(timeout=30)==0; cf.close(); log.write((D/'lock-cleanup.out').read_text()); assert not (D/'primary/state/live-lock.status').exists(); assert 'remote-worker-local' not in sources(); (D/'pause').unlink(); log.write('LIVE lifecycle serialization: retirement waited for held mirror lock; status and cursor retired after release\n')
 real_tasks=shutil.which('tasks-axi',path=env['PATH']); failtools=D/'failtools'; failtools.mkdir()
 for trans,verb in [('close','done'),('retain','reopen')]:
  id='live-fail-'+trans; seed(id)
  if trans=='retain': run([R/'bin/fm-captain-hold.sh','hold',id,'--reason','Synthetic approval needed'],pe)
  tool=failtools/'tasks-axi'; tool.write_text('#!/bin/sh\nif [ "$1" = '+verb+' ] && [ "$2" = '+id+' ]; then echo injected-backlog-failure >&2; exit 1; fi\nexec '+real_tasks+' "$@"\n'); tool.chmod(0o755)
  p=run([R/'bin/fm-teardown.sh',id],{**pe,'PATH':str(failtools)+':'+env['PATH']},False); assert p.returncode!=0 and 'injected-backlog-failure' in p.stdout
  assert not (D/f'host/state/{id}.meta').exists(); assert not (D/f'primary/state/{id}.meta').exists(); assert (D/f'primary/state/{id}.backlog-close').exists(); assert not (D/f'primary/state/remote-workers/local/{id}.cursor').exists(); assert 'remote-worker-local' not in sources()
 log.write('LIVE backlog failure injection: both close and retain failures left replay markers but no stale task cursor or mirror registration\n')
 log.write('LIVE_DRIVER_COMPLETE\n')
finally:
 subprocess.run(['tmux','-S',sock,'kill-server'],stdout=log,stderr=log)
 for c in children:
  if c.poll() is None: c.terminate()
  c.wait()
 log.close()
