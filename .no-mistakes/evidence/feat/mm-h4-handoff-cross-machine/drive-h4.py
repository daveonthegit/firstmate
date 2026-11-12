import os, pathlib, subprocess, shlex, time, shutil
ROOT=pathlib.Path.cwd(); W=ROOT/'.test-h4-live'; E=pathlib.Path('~/.no-mistakes/evidence/01M7894WZYM7DCM4Z2A6GQJP5T')
LOG=(E/'live-cli.log').open('w'); base=os.environ.copy()
for k in list(base):
    if k.startswith('FM_') or k in ('TMUX','TASKS_AXI_BACKEND'): base.pop(k)
base['TMPDIR']=str(ROOT/'.test-h4-tmp')
def run(args, expect=0, env=None, data=None):
    merged=base.copy(); merged.update(env or {})
    LOG.write('$ '+shlex.join([str(a) for a in args])+'\n'); LOG.flush()
    r=subprocess.run([str(a) for a in args],env=merged,input=data,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
    LOG.write(r.stdout+f'[exit {r.returncode}]\n'); LOG.flush()
    assert r.returncode==expect, (args,r.returncode,r.stdout)
    return r.stdout
P=W/'primary'; H=W/'worker'
for p in (P,H): run(['bin/fm-lab-home.sh','create',p])
U=W/'user'; U.mkdir(); (H/'.fm-worker-host').touch()
for p in (P,H): (p/'config/backlog-backend').write_text('manual\n')
seed=W/'seed'; run(['git','init','-q','-b','main',seed]); (seed/'base.txt').write_text('base\n')
gitid=['-c','user.name=Disposable H4','-c','user.email=h4@example.invalid']
run(['git','-C',seed,'add','.']); run(['git','-C',seed,*gitid,'commit','-qm','base'])
run(['git','clone','--bare',seed,W/'origin.git'])
for p in (P,H): run(['git','clone',W/'origin.git',p/'projects/sample'])
envP={'FM_HOME':str(P),'HOME':str(U)}; envH={'FM_HOME':str(H),'HOME':str(U)}
run(['bin/fm-brief.sh','move','sample','--mode','direct-PR'],env=envH)
b=H/'data/move/brief.md'; b.write_text(b.read_text().replace('{TASK}','Carry the exact widget change between hosts.').replace('{FIRSTMATE_SPEC}','Keep the scratch file as well as the widget.'))
copy=H/'projects/sample'; run(['git','-C',copy,'checkout','-qb','fm/move'])
(H/'state/move.meta').write_text(f'kind=ship\nworktree={copy}\nproject={copy}\nbranch=fm/move\nbackend=tmux\nharness=claude\nmode=direct-PR\nyolo=off\n')
(H/'state/move.remote-worker').write_text('synthetic placement claim\n')
# The local SSH server uses only disposable keys; no operator SSH configuration.
ssh=['/usr/bin/ssh','-F','/dev/null','-p','22379','-i',str(W/'client_key'),'-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(W/'known_hosts'),'-o','BatchMode=yes','-o','ConnectTimeout=5']
sshdlog=(E/'sshd-live.log').open('w')
s=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f','/dev/null','-h',str(W/'host_key'),'-o','PidFile='+str(W/'sshd.pid'),'-o','Port=22379','-o','ListenAddress=127.0.0.1','-o','UsePAM=no','-o','PasswordAuthentication=no','-o','StrictModes=no','-o','PermitUserRC=no','-o','AuthorizedKeysFile='+str(W/'authorized_keys')],stdout=sshdlog,stderr=sshdlog)
def leg(*args,expect=0,data=None):
    cmd=['env','FM_HOME='+str(H),'HOME='+str(U),'TMPDIR='+str(ROOT/'.test-h4-tmp'),'PATH='+base['PATH'],str(ROOT/'bin/fm-remote-worker-control.sh'),*args]
    return run([*ssh,'127.0.0.1',shlex.join(cmd)],expect=expect,data=data)
try:
    time.sleep(.5)
    run([*ssh,'127.0.0.1','printf real-isolated-ssh-ready'])
    (P/'config/rescue-ssh').write_text('127.0.0.1\n')
    url=run(['bin/fm-rescue.sh','host-url','sample'],env=envP).strip().splitlines()[-1]
    # A standard SSH command override only selects this disposable server/key.
    gitssh=shlex.join(ssh)
    # The remote leg's git ls-remote needs the same explicit connection settings.
    # Add GIT_SSH_COMMAND to the SSH command environment, without replacing git or SSH.
    original_leg=leg
    def leg(*args,expect=0,data=None):
        cmd=['env','FM_HOME='+str(H),'HOME='+str(U),'TMPDIR='+str(ROOT/'.test-h4-tmp'),'PATH='+base['PATH'],'GIT_SSH_COMMAND='+gitssh,str(ROOT/'bin/fm-remote-worker-control.sh'),*args]
        return run([*ssh,'127.0.0.1',shlex.join(cmd)],expect=expect,data=data)
    leg('rescue','move',url)
    (copy/'widget.txt').write_text('first half\n'); (copy/'scratch.txt').write_text('previously untracked\n')
    run(['git','-C',copy,'add','-A']); run(['git','-C',copy,*gitid,'commit','-qm','wip: preserved widget and scratch'])
    sha=run(['git','-C',copy,'rev-parse','HEAD']).strip()
    run(['git','-C',copy,'push','fm-rescue','fm/move'],env={'GIT_SSH_COMMAND':gitssh})
    leg('carried','move','fm-rescue','fm/move',sha)
    run(['bin/fm-rescue.sh','holds','sample','fm/move',sha],env=envP)
    run(['bin/fm-rescue.sh','ensure-project',P/'projects/sample'],env=envP)
    run(['git','-C',P/'projects/sample','fetch','fm-rescue','fm/move'])
    assert run(['git','-C',P/'projects/sample','show',sha+':scratch.txt'])=='previously untracked\n'
    (copy/'dirty.txt').write_text('must refuse\n'); leg('carried','move','fm-rescue','fm/move',sha,expect=1); (copy/'dirty.txt').unlink()
    run(['git','-C',copy,*gitid,'commit','--allow-empty','-qm','moved after ready'])
    leg('carried','move','fm-rescue','fm/move',sha,expect=1)
    # Return only this throwaway synthetic copy to its preserved commit.
    run(['git','-C',copy,'reset','--hard',sha])
    (H/'data/move/handoff-notes.md').write_text('Done: first half. Left: second half. Verify both files.\n')
    (H/'state/move.status').write_text('paused: handoff ready fm/move '+sha+'\n')
    doc=leg('handoff','move','move-c2','local','labmac','--reason','free worker','--carried','fm-rescue','fm/move',sha)
    assert 'Carry the exact widget change between hosts.' in doc and 'Keep the scratch file as well as the widget.' in doc and sha in doc and 'Done: first half.' in doc
    (E/'generated-handoff.md').write_text(doc)
    leg('stage','move-c2','move','handoff',data=doc)
    leg('stage','move-c2','move','handoff',data=doc)
    (H/'state/move-c2.meta').write_text('kind=ship\n')
    (H/'state/move-c2.remote-worker').touch()
    leg('stage','move-c2','move','handoff',data='wrong replacement\n',expect=1)
    assert (H/'data/move-c2/handoff.md').read_text()==doc
    leg('stage','scout-c2','scout','report',data='Interim synthetic scout findings.\n')
    leg('stage','scout-c2','scout','report',data='different findings\n',expect=1)
    leg('admit','fresh','sample')
    (H/'config/lane-capacity').write_text('1\n'); leg('admit','fresh','sample',expect=75); (H/'config/lane-capacity').unlink()
    leg('admit','fresh','absent',expect=1)
    leg('admit','move','sample',expect=1)
    # Supervisor preflight operates on synthetic, non-running task state.
    (P/'data/move').mkdir(); shutil.copyfile(b,P/'data/move/brief.md')
    (P/'state/move.meta').write_text(f'kind=ship\nbranch=fm/move\nworktree={P}/projects/sample\nproject={P}/projects/sample\n')
    args=['bin/fm-handoff.sh','move','--to','unknown','--remote','fm-rescue']
    run(args,env=envP,expect=1)
    (P/'state/move.status').write_text('needs-decision: must answer before moving\n')
    out=run(args,env=envP,expect=1); assert 'open decision' in out
    (P/'state/.supervisor-lease-lost').write_text('other-machine\n')
    out=run(args,env=envP,expect=1); assert 'stood down' in out
    (P/'state/.supervisor-lease-lost').unlink(); (P/'state/move.status').write_text('')
    assert not (P/'data/move/handoff-request').exists()
    # Exercise the real remote entrypoint; nested homes are refused before account state.
    import base64
    enc=lambda x:base64.b64encode(x).decode()
    cmd=[str(ROOT/'bin/fm-remote-entrypoint.sh'),'1',enc(str(ROOT).encode()),enc(str(H).encode()),enc(b'fm-remote-worker-control.sh\0admit\0fresh\0sample\0')]
    out=run([*ssh,'127.0.0.1',shlex.join(['env','PATH='+base['PATH'],*cmd])],expect=64)
    assert 'separate, non-overlapping' in out
    LOG.write('All executed native SSH/Git/CLI checks satisfied their assertions. Full lifecycle remains blocked by the remote bootstrap isolation contract.\n')
finally:
    s.terminate(); s.wait(timeout=10); sshdlog.close(); LOG.close()
