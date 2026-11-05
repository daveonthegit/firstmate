import os, pathlib, subprocess, time
r=pathlib.Path.cwd(); d=r/'.worker-validation'; e=pathlib.Path('~/.no-mistakes/evidence/01M6N9YDAX193H1GCDWVDY5BN0')
env=dict(os.environ)
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE']:
    env.pop(k,None)
env.update(FM_HOME=str(d/'primary'), FM_SSH_BIN=str(d/'ssh/client'), TMPDIR=str(d/'tmp'))
def call(label,*args,expected=0):
    print('=== '+label+' ===',flush=True)
    p=subprocess.run([str(r/'bin/fm-on.sh'),*args],env=env,text=True,capture_output=True,timeout=70)
    print(p.stdout,end=''); print(p.stderr,end=''); print('exit='+str(p.returncode),flush=True)
    assert (p.returncode==expected if expected>=0 else p.returncode!=0),label
    return p.stdout+p.stderr
server=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(d/'ssh/sshd_config')],stdout=open(e/'local-sshd.log','w'),stderr=subprocess.STDOUT)
try:
    time.sleep(1)
    if server.poll() is not None:
        raise RuntimeError('local sshd exited '+str(server.returncode))
    out=call('Worker registry selects its home through real localhost SSH and remote job worker','lab-worker','fm-remote-worker-control.sh','route','transport-proof')
    assert 'task=transport-proof' in out and 'kind=scout' in out
    out=call('Unique worker SSH alias also routes','worker-local','fm-remote-worker-control.sh','route','transport-proof')
    assert 'task=transport-proof' in out
    reg=d/'primary/data/secondmates.md'
    reg.write_text('- mate - separate remote mate (host: worker-local; root: '+str(d/'code')+'; home: '+str(r/'.l')+'; scope: example; projects: sample; added 2026-11-05)\n')
    out=call('Shared alias across worker and secondmate is refused before transport','worker-local','fm-remote-worker-control.sh','route','transport-proof',expected=-1)
    assert 'ambiguous' in out
    call('Distinct worker ID remains routable beside secondmate','lab-worker','fm-remote-worker-control.sh','route','transport-proof')
    call('Distinct secondmate ID remains routable beside worker','mate','fm-remote-worker-control.sh','route','transport-proof')
    with (d/'primary/data/worker-hosts.md').open('a') as f:
        f.write('- mate - duplicate id (host: another-local; root: '+str(d/'code')+'; home: '+str(r/'.l')+'; added 2026-11-05)\n')
    out=call('Cross-registry ID collision is refused','mate','fm-remote-worker-control.sh','route','transport-proof',expected=-1)
    assert 'ambiguous' in out
    print('ALL LOCALHOST TRANSPORT SCENARIOS COMPLETED',flush=True)
finally:
    server.terminate()
    try: server.wait(timeout=10)
    except subprocess.TimeoutExpired: server.kill(); server.wait()
    state=d/'remote-jobs'
    pidfile=state/'worker.pid'
    if pidfile.exists():
        cmd='. "$1/bin/fm-remote-job-lib.sh"; FM_REMOTE_JOB_STATE="$2"; fm_remote_job_stop_worker_tree "$(cat "$2/worker.pid")"'
        p=subprocess.run(['bash','-c',cmd,'bash',str(d/'code'),str(state)],capture_output=True,text=True,timeout=40)
        print('worker cleanup exit='+str(p.returncode),p.stdout,p.stderr,flush=True)
        assert p.returncode==0
    print('local sshd stopped exit='+str(server.returncode),flush=True)
