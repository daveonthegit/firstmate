import os, subprocess as sp, pathlib as p, json, time, shutil, base64, html
R=p.Path.cwd(); E=p.Path('~/.no-mistakes/evidence/01M75JFWHGAPG7X7HQN8KMY046'); L=R/'.w'; P=R/'.p'; log=[]
def run(argv,env=None,timeout=60):
    q=sp.run([str(x) for x in argv],env=env,capture_output=True,text=True,timeout=timeout)
    log.append('$ '+' '.join(map(str,argv))+'\n'+q.stdout+q.stderr+'\nexit='+str(q.returncode))
    return q
base=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_HOME','FM_BACKEND','HERDR_ENV','HERDR_SESSION','HERDR_SOCKET_PATH','FM_TASK_ID']:base.pop(k,None)
base['TMPDIR']=str(R)
tenv=base|{'TMUX_TMPDIR':str(L/'tmux'),'FM_HOME':str(L)}
tm=['tmux','-L','fm-lab']
try:
    assert run(['bin/fm-lab-home.sh','create',L]).returncode==0
    assert run(['bin/fm-lab-home.sh','create',P]).returncode==0
    (L/'tmux').mkdir(); (L/'.fm-worker-host').touch(); (L/'config/supervision-host').touch()
    for H in [L,P]:
        (H/'config/backlog-backend').write_text('manual\n'); (H/'state/.lock').write_text(str(os.getpid())+'\n'); (H/'state/.last-watcher-beat').touch()
    (L/'state/t1.remote-worker').touch()
    (L/'state/t1.meta').write_text(f'window=primary:fm-t1\nbackend=tmux\nendpoint_task_id=t1\nharness=claude\nkind=ship\nworktree={R}\nproject={R}\nmode=local-only\nyolo=off\nspawn_gen=s1.1.1\n')
    (P/'state/t1.meta').write_text(f'window=remote:t1\nendpoint_task_id=t1\nharness=claude\nkind=ship\nremote_worker_host=mbp\nremote_root={R}\nremote_home={L}\nremote_backend=tmux\nremote_target=primary:fm-t1\nspawn_gen=s1.1.1\n')
    (P/'data/worker-hosts.md').write_text(f'- mbp - local disposable worker (host: lab-local; root: {R}; home: {L}; added 2026-11-10)\n')
    adapter=L/'transport.py'
    adapter.write_text('''#!/usr/bin/env python3
import os,sys,base64,subprocess,pathlib
args=sys.argv[1:]
while args and args[0]=='-o':args=args[2:]
if args and args[0]=='--':args=args[1:]
mode=os.environ.get('W2_FAULT','')
if mode=='down':sys.exit(255)
assert args[:3]==['lab-local','fm-remote-entrypoint.sh','1'],args
root,home=map(lambda s:base64.b64decode(s).decode(),args[3:5])
argv=base64.b64decode(args[5]).decode().rstrip('\\0').split('\\0')
with open(pathlib.Path(home)/'transport.log','a') as f:f.write(repr(argv)+'\\n')
e=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_SEND_PLACED_DELIVERY_ID']:e.pop(k,None)
e['FM_HOME']=home
e['TMUX']=str(pathlib.Path(home)/'tmux'/('tmux-'+str(os.getuid()))/'fm-lab')+',1,0'
r=subprocess.run([root+'/bin/'+argv[0]]+argv[1:],env=e)
if mode=='lose':sys.exit(255)
if mode=='once':
 flag=pathlib.Path(home)/'lost-once'
 if not flag.exists():flag.touch();sys.exit(255)
sys.exit(r.returncode)
''');adapter.chmod(0o755)
    pe=base|{'FM_HOME':str(P),'FM_SSH_BIN':str(adapter),'TMUX_TMPDIR':str(L/'tmux'),'FM_SEND_REMOTE_BUDGET':'20','FM_CONTROL_EXIT_WAIT':'15'}
    def cli(name,*args,fault=''):
        return run(['bin/'+name+'.sh',*args],pe|{'W2_FAULT':fault},100)
    q=run(tm+['new-session','-d','-s','primary','-n','primary','-x','140','-y','42','-c',str(R),'-e','FM_HOME='+str(L),'claude'],tenv)
    assert q.returncode==0,'private tmux launch failed'
    time.sleep(3)
    q=run(tm+['new-window','-t','primary:','-n','fm-t1','-c',str(R),'-e','FM_HOME='+str(L),'-e','FM_TASK_INBOX='+str(L/'state/t1.inbox'),'bash'],tenv)
    assert q.returncode==0
    run(tm+['send-keys','-t','primary:fm-t1','claude','Enter'],tenv)
    time.sleep(8)
    def cap(label):
        q=run(tm+['capture-pane','-p','-t','primary:fm-t1','-S','-120'],tenv)
        (E/(label+'.txt')).write_text(q.stdout)
        (E/(label+'.html')).write_text('<!doctype html><meta charset="utf-8"><title>Disposable Claude worker</title><body style="background:#171717;color:#eee"><pre style="font:14px/1.5 monospace">'+html.escape(q.stdout)+'</pre>')
        return q.stdout
    pane=cap('claude-start')
    if 'trust' in pane.lower():
        run(tm+['send-keys','-t','primary:fm-t1','Down','Enter'],tenv);time.sleep(8);pane=cap('claude-ready')
    assert 'login' not in pane.lower() or 'logged in' in pane.lower(),'CLI login not ready'
    # Read/capture the actual running endpoint before sending any steering.
    q=cli('fm-crew-state','t1');assert q.returncode==0 and 'on worker host mbp' in q.stdout and 'unknown-remote' not in q.stdout,q.stdout
    q=cli('fm-peek','fm-t1','500');assert q.returncode==0 and len(q.stdout.strip())>0,q.stderr
    # Durable real host inbox; fault adapter only manipulates the external transport result.
    msg='Validation only: do not run commands or edit files. Reply LAB_STEER_RECEIVED and wait.'
    q=cli('fm-send','t1',msg,fault='once');assert q.returncode==0,q.stderr
    files=list((L/'state/t1.inbox').rglob('*.msg'));assert len(files)==1,files
    (E/'durable-inbox.txt').write_text(files[0].read_text())
    (P/'state/t1.status').write_text('needs-decision [at=1700000000] [key=k1]: choose layout\n')
    q=cli('fm-send','t1','--resolve-key','k1','Validation: choose layout B; no commands or edits.',fault='lose');assert q.returncode==3,q.stderr
    assert 'resolved' not in (P/'state/t1.status').read_text()
    resend=next(x for x in q.stderr.splitlines() if 'FM_SEND_PLACED_DELIVERY_ID=' in x)
    before=len(list((L/'state/t1.inbox').rglob('*.msg')))
    q=run(['bash','-c',resend],pe,100);assert q.returncode==0,q.stderr
    assert len(list((L/'state/t1.inbox').rglob('*.msg')))==before
    assert 'resolved [key=k1]' in (P/'state/t1.status').read_text()
    (E/'decision-status.txt').write_text((P/'state/t1.status').read_text())
    q=cli('fm-send','t1','--key','Escape');assert q.returncode!=0 and 'fm-control.sh t1 interrupt' in q.stderr
    q=run(['bin/fm-send.sh','t1','bad id'],pe|{'FM_SEND_PLACED_DELIVERY_ID':'invalid'});assert q.returncode!=0 and '16 lowercase hex' in q.stderr
    q=cli('fm-control','t1','relaunch','--note','not supported');assert q.returncode!=0 and 'only interrupt and exit' in q.stderr
    # Active adversarial unreachable-host checks on the real public CLI.
    q=cli('fm-crew-state','t1',fault='down');assert q.returncode==0 and 'unknown-remote' in q.stdout and 'state: unknown' in q.stdout and 'dead' not in q.stdout
    q=cli('fm-peek','t1',fault='down');assert q.returncode!=0 and 'not thereby dead' in q.stderr
    for v in ['interrupt','exit']:
        q=cli('fm-control','t1',v,fault='down');assert q.returncode!=0 and 'is unknown' in q.stderr
    q=cli('fm-t3-answer','t1','req-1','{"q1":"yes"}',fault='down');assert q.returncode==255 and 'is unknown' in q.stderr
    q=cli('fm-t3-answer','t1');assert q.returncode!=0 and 'only T3 Code threads' in q.stderr
    time.sleep(3);cap('claude-before-control')
    q=cli('fm-control','t1','interrupt');log.append('INTERRUPT_RESULT='+str(q.returncode))
    cap('claude-after-interrupt')
    q=cli('fm-control','t1','exit');log.append('EXIT_RESULT='+str(q.returncode))
    cap('claude-after-exit')
    (E/'local-cli-results.json').write_text(json.dumps({'interrupt_exit':q.returncode,'status':'finished'},indent=2))
finally:
    if (L/'tmux').exists():run(tm+['kill-server'],tenv)
    shutil.rmtree(L,ignore_errors=True);shutil.rmtree(P,ignore_errors=True)
    (E/'local-cli-transcript.log').write_text('\n\n'.join(log))
