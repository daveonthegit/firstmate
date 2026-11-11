#!/usr/bin/env python3
"""Disposable SSH gateway. Decode fm-on protocol; execute the REAL host command.
Only the fixed entrypoint/job-queue bootstrap is replaced, not placement or runtime.
"""
import os,sys,shlex,base64,subprocess
root=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
a=shlex.split(os.environ['SSH_ORIGINAL_COMMAND'])
assert len(a)==5 and a[:2]==['fm-remote-entrypoint.sh','1'],a
assert base64.b64decode(a[2]).decode()==root
home=base64.b64decode(a[3]).decode()
assert home==root+'/w'
argv=[x.decode() for x in base64.b64decode(a[4]).split(b'\0') if x]
assert argv[0] in ['fm-remote-worker-control.sh','fm-remote-worker-events.sh']
env=dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k in ['NO_MISTAKES_GATE','CLAUDECODE','CLAUDE_CODE_ENTRYPOINT']:
        env.pop(k,None)
env.update(FM_HOME=home, FM_ROOT_OVERRIDE=root, TREEHOUSE_ROOT=root+'/.live/pool',
           PATH=os.environ.get('PATH','')+':/opt/homebrew/bin:~/.local/bin:~/.nvm/versions/node/v24.16.0/bin',
           TMUX=open(root+'/.live/tmux-address').read().strip(), FM_SPAWN_NO_GUARD='1',
           FM_GH_ACCOUNT='none', FM_REMOTE_WORKER_WAIT_SECONDS='1')
p=subprocess.run([root+'/bin/'+argv[0]]+argv[1:],env=env)
# Disconnect after the real host operation has completed, once, for retry proof.
marker=root+'/.live/lose-next-result'
if os.path.exists(marker) and argv[0]=='fm-remote-worker-control.sh' and argv[1]=='spawn':
    os.unlink(marker)
    sys.exit(255)
sys.exit(p.returncode)
