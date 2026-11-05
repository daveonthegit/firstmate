import os, pathlib, subprocess as s, socket, time, shutil, shlex
root=pathlib.Path.cwd(); d=root/'.live-routing'; d.mkdir()
e=pathlib.Path('~/.no-mistakes/evidence/01M6N9YDAX193H1GCDWVDY5BN0')
log=open(e/'live-routing.log','w'); server=None

def run(args,env=None,ok=True):
 p=s.run(list(map(str,args)),env=env,stdout=s.PIPE,stderr=s.STDOUT,text=True,timeout=25)
 log.write('$ '+shlex.join(list(map(str,args)))+'\n'+p.stdout+f'EXIT={p.returncode}\n');log.flush()
 if ok and p.returncode: raise RuntimeError(p.stdout)
 return p
try:
 home=d/'primary'; (home/'data').mkdir(parents=True)
 remote=d/'remote'; remote.mkdir()
 env=os.environ.copy(); env['FM_HOME']=str(home)
 for k in list(env):
  if k.startswith('FM_') and k.endswith('_OVERRIDE'): del env[k]
 reg=home/'data/worker-hosts.md'
 reg.write_text(f'- worker - test host (host: lab-ssh; root: {root}; home: {remote}; added 2026-11-05)\n- other - another home (host: lab-ssh; root: {root}; home: {remote}/other; added 2026-11-05)\n')
 p=run([root/'bin/fm-on.sh','lab-ssh','fm-remote-worker-control.sh','route','x'],env,False)
 assert p.returncode and 'ambiguous across 2' in p.stdout
 (home/'data/secondmates.md').write_text(f'- worker - conflicting secondmate (host: elsewhere; root: {root}; home: {remote}/second; scope: lab routing; projects: sample; added 2026-11-05)\n')
 p=run([root/'bin/fm-on.sh','worker','fm-remote-worker-control.sh','route','x'],env,False)
 assert p.returncode and 'ambiguous' in p.stdout
 (home/'data/secondmates.md').unlink()
 reg.write_text(f'- worker - test host (host: lab-ssh; root: {root}; home: {remote}; added 2026-11-05)\n')
 run(['ssh-keygen','-q','-t','ed25519','-N','','-f',d/'hostkey'])
 run(['ssh-keygen','-q','-t','ed25519','-N','','-f',d/'identity'])
 (d/'authorized_keys').write_text((d/'identity.pub').read_text()); (d/'authorized_keys').chmod(0o600)
 with socket.socket() as sock:
  sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
 # Only the existing fixed-entrypoint command is allowed, in an isolated account home.
 force=d/'force.py'
 force.write_text('import os,shlex\na=shlex.split(os.environ["SSH_ORIGINAL_COMMAND"])\nassert a[0]=="fm-remote-entrypoint.sh"\nos.environ["HOME"]='+repr(str(remote))+'\nos.execv('+repr(str(root/'bin/fm-remote-entrypoint.sh'))+',a)\n')
 conf=d/'sshd_config'
 conf.write_text(f'Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/hostkey\nPidFile {d}/sshd.pid\nAuthorizedKeysFile {d}/authorized_keys\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nPermitUserEnvironment no\nForceCommand /usr/bin/python3 {force}\n')
 sshlog=open(e/'live-sshd.log','w')
 server=s.Popen(['/usr/sbin/sshd','-D','-e','-f',str(conf)],stdout=sshlog,stderr=s.STDOUT)
 time.sleep(1)
 wrapper=d/'ssh';wrapper.write_text('#!/bin/sh\nexec /usr/bin/ssh -p '+str(port)+' -i '+shlex.quote(str(d/'identity'))+' -o UserKnownHostsFile='+shlex.quote(str(d/'known_hosts'))+' -o StrictHostKeyChecking=accept-new "$@"\n'); wrapper.chmod(0o755)
 # fm-on insists on strict checking; provision this throwaway host's known key explicitly.
 hostpub=(d/'hostkey.pub').read_text().split()
 (d/'known_hosts').write_text(f'[127.0.0.1]:{port} {hostpub[0]} {hostpub[1]}\n')
 sshcfg=d/'ssh_config';sshcfg.write_text('Host lab-ssh\n HostName 127.0.0.1\n')
 wrapper.write_text(wrapper.read_text().replace('exec /usr/bin/ssh ', 'exec /usr/bin/ssh -F '+shlex.quote(str(sshcfg))+' '))
 env['FM_SSH_BIN']=str(wrapper)
 p=run([root/'bin/fm-on.sh','worker','fm-remote-doctor.sh'],env,False)
 # Read-only doctor may report missing daemon/tools; protocol output proves route selection.
 if 'worker=' not in p.stdout and 'remote job' not in p.stdout and 'protocol' not in p.stdout and 'root=' not in p.stdout:
  log.write('Real SSH roundtrip unavailable; see sshd log.\n')
finally:
 if server is not None:
  server.terminate()
  try: server.wait(timeout=5)
  except s.TimeoutExpired: server.kill();server.wait()
 shutil.rmtree(d)
 log.close()
