import os,pathlib,subprocess,time,html,json,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M7CF729TEKTFDZA3QD5ECVS9'); L=E/'l'
subprocess.run([str(R/'bin/fm-lab-home.sh'),'create',str(L)],check=True)
(L/'tmux').mkdir(); (L/'config/supervision-host').touch()
(L/'state/.lock').write_text('9999999\n')
for name in ['.lock.acquire','.lock.acquire.steal']:
    d=L/'state'/name; d.mkdir(); (d/'pid').write_text('9999999\n'); os.utime(d,(1,1))
env=dict(os.environ,TMUX_TMPDIR=str(L/'tmux'))
cmd=['tmux','-L','fm-lab']; history=[]
def tm(*args,check=True):return subprocess.run(cmd+list(args),env=env,capture_output=True,text=True,timeout=20,check=check)
def cap(label):
    s=tm('capture-pane','-p','-S','-300','-t','primary').stdout
    history.append('## '+label+'\n'+s)
    (E/'primary-transcript.md').write_text('\n'.join(history))
    (E/'primary-screen.html').write_text('<!doctype html><meta charset="utf-8"><title>Disposable Claude primary</title><style>body{background:#171717;color:#eee;padding:24px;font:14px monospace;white-space:pre-wrap}</style>'+html.escape(s))
    return s
try:
    start=['env']
    for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:start+=['-u',k]
    start += ['TMUX_TMPDIR='+str(L/'tmux')]+cmd+['new-session','-d','-s','primary','-x','140','-y','45','-c',str(R),'-e','FM_HOME='+str(L),'claude']
    x=subprocess.run(start,capture_output=True,text=True,timeout=20); history.append('launch exit='+str(x.returncode)+'\n'+x.stdout+x.stderr); x.check_returncode()
    time.sleep(8); s=cap('Initial interactive CLI')
    # Only acknowledge workspace trust for this disposable gate worktree.
    if 'trust this folder' in s.lower() or 'trust this project' in s.lower() or 'is this a project you created' in s.lower():
        tm('send-keys','-t','primary','Down','Enter'); time.sleep(6); s=cap('After workspace trust acknowledgement')
    prompt='This is an isolated validation home, not the fleet. Do not spawn workers or contact any forge. Run exactly `bin/fm-lock.sh; bin/fm-lock.sh status` in Bash, then reply LAB_LOCK_DONE. Do not do other work.'
    tm('send-keys','-t','primary','-l',prompt); tm('send-keys','-t','primary','Enter')
    for i in range(36):
        time.sleep(5); s=cap('Lock acquisition poll '+str(i+1))
        if 'Do you want to proceed' in s or 'Allow this' in s:
            tm('send-keys','-t','primary','Enter')
        if 'LAB_LOCK_DONE' in s and ('lock acquired:' in s or 'lock: held by live harness' in s):break
        if 'Not logged in' in s or 'Please run /login' in s or 'Invalid API key' in s:break
    state={'lock':(L/'state/.lock').read_text() if (L/'state/.lock').exists() else None,'claim_directory_remains':(L/'state/.lock.acquire').is_dir(),'steal_directory_remains':(L/'state/.lock.acquire.steal').is_dir()}
    (E/'primary-lock-state.json').write_text(json.dumps(state,indent=2))
    print(json.dumps(state)); print(s)
finally:
    # Stop only the lab socket, never a default tmux server.
    tm('kill-server',check=False)
    time.sleep(1)
    for n in ['.supervision-host','.watch.lock/pid']:
        p=L/'state'/n
        if p.exists():print('Cleanup inspection:',n,p.read_text()[:300])
    shutil.rmtree(L)
