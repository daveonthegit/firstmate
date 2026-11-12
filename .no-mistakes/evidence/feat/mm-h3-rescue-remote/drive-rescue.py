import os, pathlib, subprocess, tempfile, shutil, json, ssl, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M77ZFXMRV4JZ9DK5S0JZQPSD')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.rescue-live-',dir=ROOT)); log=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ['GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN','GH_HOST','TMUX']: env.pop(k,None)
env.update(HOME=str(lab/'user'), FM_HOME=str(lab/'home'), FM_GH_ACCOUNT='none', GH_CONFIG_DIR=str(lab/'gh'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GH_NO_UPDATE_NOTIFIER='1', GH_PROMPT_DISABLED='1')
(lab/'user').mkdir(); (lab/'gh').mkdir()
def run(*args, expected=0, cwd=None):
    p=subprocess.run([str(x) for x in args],cwd=cwd or ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    log.append('$ '+' '.join(str(x).replace(str(lab),'$LAB') for x in args)+'\n'+p.stdout.replace(str(lab),'$LAB')+f'[exit {p.returncode}]\n')
    if expected is not None and p.returncode!=expected: raise RuntimeError(log[-1])
    return p.stdout.strip(),p.returncode
def git(where,*args,**kw): return run('git','-C',where,*args,**kw)[0]
def rescue(*args,**kw): return run(ROOT/'bin/fm-rescue.sh',*args,**kw)
def record(head):
    run('bash','-c','. "$1/bin/fm-continuation-lib.sh"; fm_continuation_write "$2" carry-c2 carry ship fm-rescue fm/carry "$3"','_',ROOT,lab/'home/data',head)
server=None
try:
    run(ROOT/'bin/fm-lab-home.sh','create',lab/'home')
    project=lab/'project'; wt=lab/'copy'; repo=lab/'user/fm-rescue/project.git'; origin=lab/'origin.git'
    run('git','init','-q','-b','main',project)
    git(project,'config','user.name','Live Test');git(project,'config','user.email','live@example.invalid')
    (project/'base.txt').write_text('base\n'); git(project,'add','.');git(project,'commit','-qm','base');base=git(project,'rev-parse','HEAD')
    run('git','init','--bare','-q',origin);git(project,'remote','add','origin',origin);git(project,'push','-q','-u','origin','main')
    git(project,'worktree','add','-q','-b','fm/carry',wt)
    (lab/'home/state/carry.meta').write_text(f'project={project}\nworktree={wt}\n')
    rescue('ensure','carry');rescue('ensure','carry')
    assert git(repo,'rev-parse','--is-bare-repository')=='true'
    assert (repo.parent.stat().st_mode & 0o777)==0o700
    git(project,'remote','set-url','fm-rescue',lab/'conflict.git');rescue('ensure','carry',expected=1)
    assert git(project,'remote','get-url','fm-rescue')==str(lab/'conflict.git')
    git(project,'remote','set-url','fm-rescue',repo)
    (wt/'widget.txt').write_text('carried feature\n');git(wt,'add','.');git(wt,'commit','-qm','carried feature');head=git(wt,'rev-parse','HEAD');git(wt,'push','-q','fm-rescue','fm/carry')
    assert git(origin,'for-each-ref','--format=%(refname)','refs/heads')=='refs/heads/main'
    record(head);(lab/'home/state/carry.meta').unlink()
    (lab/'home/state/carry-c2.meta').write_text('kind=ship\n')
    rescue('prune','carry',project,expected=1)
    (lab/'home/state/carry-c2.meta').unlink();rescue('prune','carry',project,expected=1)
    assert git(repo,'rev-parse','refs/heads/fm/carry')==head
    git(wt,'push','-q','origin','HEAD:refs/heads/main');rescue('prune','carry',project)
    assert not git(repo,'for-each-ref','--format=%(refname)','refs/heads/fm/carry')
    rescue('prune','carry',project)
    # Reset only the disposable origin base for adversarial abandonment and PR cases.
    git(wt,'push','-q','--force','origin',base+':refs/heads/main');git(wt,'push','-q','fm-rescue','fm/carry')
    (wt/'widget.txt').write_text('carried feature\nmore work\n');git(wt,'commit','-qam','more work');moved=git(wt,'rev-parse','HEAD');git(wt,'push','-q','fm-rescue','fm/carry')
    rescue('prune','carry',project,'--abandoned',expected=1);assert git(repo,'rev-parse','refs/heads/fm/carry')==moved
    git(wt,'push','-q','--force','fm-rescue',head+':refs/heads/fm/carry');rescue('prune','carry',project,'--abandoned')
    # Rebase the continuation, then squash its actual feature into main.
    git(wt,'reset','--hard',head)
    (project/'advanced.txt').write_text('main advanced\n');git(project,'add','.');git(project,'commit','-qm','advance main');git(project,'push','-q','origin','main')
    git(wt,'rebase','origin/main');rewritten=git(wt,'rev-parse','HEAD');assert rewritten!=head
    git(project,'merge','--squash','fm/carry');git(project,'commit','-qm','squash carried feature');git(project,'push','-q','origin','main')
    assert (project/'widget.txt').read_text()=='carried feature\n'
    _,ancestry=run('git','-C',project,'merge-base','--is-ancestor',head,'origin/main',expected=1)
    # A real gh CLI talks TLS GraphQL to a local synthetic forge boundary.
    run('openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',lab/'key.pem','-out',lab/'cert.pem','-days','1','-subj','/CN=rescue.example.test','-addext','subjectAltName=DNS:rescue.example.test')
    response={'state':'OPEN','headRefOid':rewritten}
    class Handler(BaseHTTPRequestHandler):
        def do_CONNECT(self):
            self.send_response(200);self.end_headers()
            connection=ctx.wrap_socket(self.connection,server_side=True)
            Handler(connection,self.client_address,self.server)
        def do_POST(self):
            body=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode();log.append('LOCAL GRAPHQL '+body+'\n')
            if response['state']=='unavailable':
                self.send_response(503);self.end_headers();return
            pr={'state':response['state'],'headRefOid':response['headRefOid'],'url':'https://rescue.example.test/owner/repo/pull/7'}
            data=json.dumps({'data':{'repository':{'pullRequest':pr}}}).encode()
            self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(data)
        def log_message(self,*args): pass
    server=HTTPServer(('127.0.0.1',0),Handler);ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(lab/'cert.pem',lab/'key.pem')
    thread=threading.Thread(target=server.serve_forever);thread.start()
    env.update(GH_HOST='rescue.example.test',GH_ENTERPRISE_TOKEN='synthetic-local-only',SSL_CERT_FILE=str(lab/'cert.pem'),HTTPS_PROXY=f'http://127.0.0.1:{server.server_port}',https_proxy=f'http://127.0.0.1:{server.server_port}',NO_PROXY='',no_proxy='')
    url='https://rescue.example.test/owner/repo/pull/7'
    (lab/'home/data/carry-c2/rescue-pr').write_text(f'pr={url}\n')
    git(wt,'push','-q','fm-rescue',head+':refs/heads/fm/carry')
    run('gh','pr','view',url,'--json','state,headRefOid,url')
    # Open and unavailable PRs must retain the original ref despite matching content.
    rescue('prune','carry',project,expected=1)
    assert git(repo,'rev-parse','refs/heads/fm/carry')==head
    response['state']='unavailable';rescue('prune','carry',project,expected=1)
    assert git(repo,'rev-parse','refs/heads/fm/carry')==head
    response['state']='MERGED';rescue('prune','carry',project)
    assert not git(repo,'for-each-ref','--format=%(refname)','refs/heads/fm/carry')
    log.append('PASS: rebased then squash-landed carried feature pruned only after the synthetic forge reported MERGED.\n')
    git(project,'push','-q','--force','origin',base+':refs/heads/main')
    git(wt,'reset','--hard',base)
    (wt/'unrelated.txt').write_text('different feature, carried work dropped\n');git(wt,'add','.');git(wt,'commit','-qm','different feature');unrelated=git(wt,'rev-parse','HEAD')
    assert not (wt/'widget.txt').exists()
    git(wt,'push','-q','origin','HEAD:refs/heads/main')
    git(wt,'push','-q','fm-rescue',head+':refs/heads/fm/carry')
    response['headRefOid']=unrelated
    out,rc=rescue('prune','carry',project,expected=None)
    exists=bool(git(repo,'for-each-ref','--format=%(refname)','refs/heads/fm/carry'))
    log.append(f'ADVERSARIAL ORACLE: continuation discarded widget.txt and landed different feature at {unrelated}; synthetic merged PR reports that real Git head. It contains no carried feature. Expected retention; actual prune exit={rc}, rescue_ref_exists={exists}.\n')
    tracking=git(project,'for-each-ref','--format=%(refname)','refs/remotes/fm-rescue/fm/carry')
    if rc==0 and not exists:
        log.append(f'FAIL: merged PR unrelated to carried work deleted rescue ref; tracking_ref={tracking or "absent"}.\n')
        raise AssertionError('Unsafe prune: merged PR discarded carried feature, but rescue preservation refs were deleted')
finally:
    if server: server.shutdown();thread.join();server.server_close()
    shutil.rmtree(lab)
    (E/'live-rescue.log').write_text('\n'.join(log))
print('\n'.join(log[-8:]))
