import os,pathlib,subprocess,socketserver,ssl,threading,json,time,shutil,sys
R=pathlib.Path.cwd(); B=R/'.validation'; E=pathlib.Path('~/.no-mistakes/evidence/01M78SQFEM97ZCTY5Y38YN027V')
log=open(E/'live-cli-transcript.txt','w',buffering=1)
def say(s): print(s,flush=True); log.write(str(s)+'\n')
def cmd(a,env=None,ok=True):
 p=subprocess.run([str(x) for x in a],cwd=R,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=65)
 if ok and p.returncode: raise RuntimeError(str(a)+'\n'+p.stdout)
 return p
forge={'enabled':False,'sha':'','requests':[]}
class Proxy(socketserver.BaseRequestHandler):
 def handle(self):
  try:
   raw=b''
   while b'\r\n\r\n' not in raw: raw+=self.request.recv(8192)
   host=raw.split(b' ')[1].decode(); self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
   ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(B/'cert.pem',B/'cert.key')
   with ctx.wrap_socket(self.request,server_side=True) as s:
    raw=b''
    while b'\r\n\r\n' not in raw: raw+=s.recv(8192)
    headers,body=raw.split(b'\r\n\r\n',1); n=0
    for l in headers.split(b'\r\n'):
     if l.lower().startswith(b'content-length:'): n=int(l.split(b':',1)[1])
    while len(body)<n: body+=s.recv(8192)
    req={'host':host,'request':headers.split(b'\r\n')[0].decode(),'body':body.decode()}
    forge['requests'].append(req)
    if forge['enabled']:
     data={'data':{'repository':{'name':'sample','nameWithOwner':'acme/sample','owner':{'login':'acme'},'pullRequest':{'number':7,'headRefOid':forge['sha'],'isDraft':False,'state':'OPEN','url':'https://'+host.split(':')[0]+'/acme/sample/pull/7'}}}}
     status='200 OK'
    else: data={'message':'synthetic forge unavailable'}; status='503 Service Unavailable'
    out=json.dumps(data).encode(); s.sendall(('HTTP/1.1 '+status+'\r\nContent-Type: application/json\r\nContent-Length: '+str(len(out))+'\r\nConnection: close\r\n\r\n').encode()+out)
  except Exception as ex:
   with open(B/'proxy-errors.log','a') as f: f.write(repr(ex)+'\n')
class Server(socketserver.ThreadingTCPServer): allow_reuse_address=True; daemon_threads=True
server=Server(('127.0.0.1',22283),Proxy); thread=threading.Thread(target=server.serve_forever); thread.start()
sshdlog=open(B/'sshd.log','w'); sshd=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(B/'sshd_config')],stdout=sshdlog,stderr=subprocess.STDOUT)
baseenv=dict(os.environ)
for k in list(baseenv):
 if k.startswith('FM_') or k in ('TMUX','GH_HOST','GITHUB_TOKEN','GITHUB_ENTERPRISE_TOKEN'): del baseenv[k]
baseenv.update(FM_ROOT_OVERRIDE=str(R),FM_GH_ACCOUNT='none',HOME=str(B/'user-home'),GH_CONFIG_DIR=str(B/'gh-config'),GH_TOKEN='synthetic-token',GH_ENTERPRISE_TOKEN='synthetic-token',HTTPS_PROXY='http://127.0.0.1:22283',SSL_CERT_FILE=str(B/'cert.pem'),GH_NO_UPDATE_NOTIFIER='1',GH_PROMPT_DISABLED='1')
for d in ('user-home','gh-config'): (B/d).mkdir(exist_ok=True)
(B/'ssh-config').write_text(f'Host remote-lab\n HostName 127.0.0.1\n Port 22282\n User {os.getlogin() if False else cmd(["id","-un"]).stdout.strip()}\n IdentityFile {B}/client_key\n IdentitiesOnly yes\n UserKnownHostsFile {B}/known_hosts\n StrictHostKeyChecking accept-new\n')
(B/'ssh').write_text(f'#!/bin/sh\nexec /usr/bin/ssh -F "{B}/ssh-config" "$@"\n'); (B/'ssh').chmod(0o755)
baseenv['FM_SSH_BIN']=str(B/'ssh')
results=[]
def make(name,mode='no-mistakes',host='github.com'):
 c=B/name
 if c.exists(): shutil.rmtree(c)
 p=c/'parent'; h=c/'worker'; repo=c/'repo'; wt=c/'wt'; origin=c/'origin.git'
 for home in (p,h):
  for d in ('data','state','config'): (home/d).mkdir(parents=True,exist_ok=True)
  (home/'state/.lock').write_text(str(os.getpid())+'\n'); (home/'state/.last-watcher-beat').touch(); (home/'config/backlog-backend').write_text('manual\n')
  (home/'config/github-hosts').write_text(host+'\n')
 (h/'.fm-worker-host').touch()
 cmd(['git','init','--quiet','--bare',origin]); cmd(['git','clone','--quiet',origin,repo])
 cmd(['git','-C',repo,'config','user.name','Lab']); cmd(['git','-C',repo,'config','user.email','lab@example.invalid'])
 (repo/'README').write_text('base\n'); cmd(['git','-C',repo,'add','.']); cmd(['git','-C',repo,'commit','--quiet','-m','base']); cmd(['git','-C',repo,'push','--quiet','origin','HEAD'])
 cmd(['git','-C',repo,'worktree','add','--quiet','-b','fm/t1',wt])
 (wt/'change').write_text('worker change\n'); cmd(['git','-C',wt,'add','.']); cmd(['git','-C',wt,'commit','--quiet','-m','worker change'])
 (h/'state/t1.meta').write_text(f'kind=ship\nmode={mode}\nworktree={wt}\nproject={repo}\nbranch=fm/t1\n')
 (h/'state/t1.remote-worker').write_text('placed_at=1\n')
 (p/'state/t1.meta').write_text(f'kind=ship\nmode={mode}\nwindow=remote:t1\nendpoint_task_id=t1\nbranch=fm/t1\nremote_worker_host=lab\nremote_root={R}\nremote_home={h}\nremote_backend=tmux\nremote_worktree={wt}\nremote_project={repo}\n')
 registry=f'- lab - local SSH worker (host: remote-lab; root: {R}; home: {h}; added 2026-11-10)\n'
 (p/'data/worker-hosts.md').write_text(registry)
 return dict(c=c,p=p,h=h,repo=repo,wt=wt,registry=registry,url=f'https://{host}/acme/sample/pull/7')
def primary(c,args):
 env=dict(baseenv,FM_HOME=str(c['p'])); p=cmd(['bash',R/'bin/fm-pr-check.sh']+args,env,False)
 say('$ bin/fm-pr-check.sh '+' '.join(args)); say(f'exit={p.returncode}\n{p.stdout.rstrip()}')
 return p
def state(c):
 text=(c['p']/'state/t1.meta').read_text(); pr=next((l[3:] for l in text.splitlines() if l.startswith('pr=')),None); poll=(c['p']/'state/t1.check.sh').exists()
 say(f'persisted PR={pr}; merge-monitor script exists={poll}'); return pr,poll
def record(name): results.append(name); say('SCENARIO PASS: '+name+'\n')
try:
 time.sleep(.5)
 # Real Git durability, real SSH, real worker CLI; the transport adapter is not the production remote-job daemon.
 say('LOCAL SURFACE: real supervisor CLI -> real fm-on -> OpenSSH localhost -> transport adapter -> real worker named-head CLI; real Git repos. Forge requests use real gh against a synthetic HTTPS API via a private proxy. No production login or remote-job daemon tested.\n')
 c=make('pushed'); cmd(['git','-C',c['wt'],'push','--quiet','origin','fm/t1'])
 p=primary(c,['t1',c['url']]); assert p.returncode==0,p.stdout; assert state(c)==(c['url'],True)
 record('Published worker head registers from supervisor without a local worktree and arms monitoring')
 c=make('copy-only'); p=primary(c,['t1',c['url']]); assert p.returncode==1 and 'unreachable outside the worker copy' in p.stdout; assert state(c)==(None,False)
 # Missing claim is an independent adversarial host identity guard.
 (c['h']/'state/t1.remote-worker').unlink(); p=primary(c,['t1',c['url']]); assert p.returncode==1 and 'not placed on this worker host' in p.stdout; assert state(c)==(None,False)
 record('Unpublished worker head and unclaimed task refuse registration and monitoring')
 c=make('retry'); cmd(['git','-C',c['wt'],'push','--quiet','origin','fm/t1'])
 sshd.terminate(); sshd.wait(timeout=5)
 p=primary(c,['t1',c['url']]); assert p.returncode==75,p.stdout; assert state(c)==(None,False)
 (c['p']/'state/t1.status').write_text('done: PR '+c['url']+' checks green\n')
 p=primary(c,['scan']); assert p.returncode==0 and p.stdout=='',p.stdout; assert not (c['p']/'state/t1.pr-register-refused').exists()
 sshd=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(B/'sshd_config')],stdout=sshdlog,stderr=subprocess.STDOUT); time.sleep(.5)
 p=primary(c,['scan']); assert p.returncode==0,p.stdout; assert state(c)==(c['url'],True)
 record('Offline SSH returns retryable 75; scan stays silent then registers when transport recovers')
 for axis in ('root','home'):
  c=make('drift-'+axis); old=str(R) if axis=='root' else str(c['h']); (c['p']/'data/worker-hosts.md').write_text(c['registry'].replace(f'{axis}: {old};',f'{axis}: {c["c"]}/other;'))
  before=(B/'transport.log').read_text(); p=primary(c,['t1',c['url']]); assert p.returncode==1 and 'route drift' in p.stdout; assert state(c)==(None,False); assert (B/'transport.log').read_text()==before
 record('Registry root/home drift refuses before dispatching to another worker identity')
 forge['enabled']=True
 for host in ('github.com','github.acme.test'):
  for mode in ('no-mistakes','','direct-PR','local-only'):
   c=make('rewrite-'+host+'-'+(mode or 'default'),mode,host)
   old=cmd(['git','-C',c['wt'],'rev-parse','HEAD']).stdout.strip()
   cmd(['git','-C',c['wt'],'checkout','--quiet','--detach']); cmd(['git','-C',c['wt'],'update-ref','-d','refs/heads/fm/t1'])
   # Create a different, genuinely published pipeline commit independently of the stale worker HEAD.
   (c['repo']/'pipeline').write_text('published pipeline rewrite\n'); cmd(['git','-C',c['repo'],'add','.']); cmd(['git','-C',c['repo'],'commit','--quiet','-m','pipeline rewrite']); cmd(['git','-C',c['repo'],'push','--quiet','origin','HEAD'])
   forge['sha']=cmd(['git','-C',c['repo'],'rev-parse','HEAD']).stdout.strip(); assert forge['sha']!=old
   refs=cmd(['git','-C',c['wt'],'for-each-ref','--contains',old,'refs/remotes/']).stdout; assert refs=='',refs
   start=len(forge['requests']); p=primary(c,['t1',c['url']])
   expected=0 if mode in ('','no-mistakes') else 1
   assert p.returncode==expected,(host,mode,p.stdout); assert state(c)==((c['url'],True) if expected==0 else (None,False))
   reqs=forge['requests'][start:]; assert reqs,(host,mode,'real gh did not reach local API')
   if expected==0: assert any('headRefOid' in q['body'] for q in reqs),reqs
   say(f'forge host={host}; mode={mode or "default"}; worker HEAD={old}; published forge HEAD={forge["sha"]}; worker HEAD absent from remote refs; real gh requests={len(reqs)}')
 record('Published rewritten GitHub and Enterprise forge heads register only in no-mistakes/default mode; direct-PR/local-only still refuse stale copy-only HEAD')
 (E/'live-results.json').write_text(json.dumps({'passed':results,'scope':'Local SSH transport adapter and synthetic HTTPS forge; real product CLIs, Git, OpenSSH, and gh. Not production remote job daemon or tenant validation.'},indent=2))
 say('ALL LOCAL SCENARIOS PASSED')
finally:
 if sshd.poll() is None: sshd.terminate()
 sshd.wait(timeout=10); say('Disposable sshd stopped, exit='+str(sshd.returncode)); sshdlog.close()
 server.shutdown(); server.server_close(); thread.join(timeout=10)
 (E/'forge-requests.json').write_text(json.dumps(forge['requests'],indent=2))
 if (B/'transport.log').exists(): shutil.copyfile(B/'transport.log',E/'ssh-dispatch.txt')
 shutil.copyfile(B/'sshd.log',E/'sshd.log'); log.close()
