import os,pathlib,tempfile,subprocess,shutil
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M77ZFXMRV4JZ9DK5S0JZQPSD'); L=pathlib.Path(tempfile.mkdtemp(prefix='.rescue-cleanup-',dir=R));logs=[]
e=os.environ.copy()
for k in list(e):
 if k.startswith('FM_') or k in ['TMUX','GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN']:e.pop(k,None)
e.update(FM_HOME=str(L/'home'),HOME=str(L/'user'),FM_GH_ACCOUNT='none',GH_CONFIG_DIR=str(L/'gh'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',TREEHOUSE_ROOT=str(L/'pool'),TMUX=f'{L}/absent-socket,1,0')
(L/'user').mkdir();(L/'gh').mkdir()
S=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab-tmux-'));e['TMUX_TMPDIR']=str(S);e.pop('TMUX',None)
def run(*a,cwd=None,expected=0):
 p=subprocess.run([str(x) for x in a],cwd=cwd or R,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=100)
 logs.append('$ '+' '.join(str(x).replace(str(L),'$LAB') for x in a)+'\n'+p.stdout.replace(str(L),'$LAB')+f'[exit {p.returncode}]\n')
 if expected is not None and p.returncode!=expected:raise RuntimeError(logs[-1])
 return p.stdout.strip(),p.returncode
def g(d,*a):return run('git','-C',d,*a)[0]
try:
 run('tmux','-L','fm-lab','new-session','-d','-s','fm-lab-rescue','-n','idle','-x','100','-y','30','bash')
 e['TMUX']=str(S/f'tmux-{os.getuid()}'/'fm-lab')+',1,0'
 run(R/'bin/fm-lab-home.sh','create',L/'home');(L/'home/config/supervision-host').touch();(L/'home/config/backlog-backend').write_text('manual\n')
 P=L/'project';O=L/'origin.git';run('git','init','-q','-b','main',P);g(P,'config','user.name','Live');g(P,'config','user.email','live@example.invalid');(P/'base').write_text('base\n');g(P,'add','.');g(P,'commit','-qm','base');run('git','init','--bare','-q',O);g(P,'remote','add','origin',O);g(P,'push','-qu','origin','main')
 out,_=run('treehouse','get','--lease','--no-fetch','-b','fm/cleanup',cwd=P);W=pathlib.Path(out.splitlines()[-1]);(W/'feature').write_text('unlanded feature\n');g(W,'add','.');g(W,'commit','-qm','feature');head=g(W,'rev-parse','HEAD')
 meta=L/'home/state/cleanup.meta';meta.write_text(f'window=fm-lab-rescue:fm-cleanup\nendpoint_task_id=cleanup\nworktree={W}\nproject={P}\nkind=ship\nmode=direct-PR\nbranch=fm/cleanup\nspawn_gen=live-cleanup\n')
 out,rc=run(R/'bin/fm-teardown.sh','cleanup',expected=None)
 assert rc!=0 and meta.exists(), 'unpreserved work must refuse'
 assert 'not on any remote' in out, 'must reach actual preservation guard'
 run(R/'bin/fm-rescue.sh','ensure','cleanup');g(W,'push','-q','fm-rescue','fm/cleanup')
 out,rc=run(R/'bin/fm-teardown.sh','cleanup',expected=None)
 assert rc==0 and not meta.exists(),'preserved work should clean without force'
 assert g(L/'user/fm-rescue/project.git','rev-parse','refs/heads/fm/cleanup')==head
 assert g(O,'for-each-ref','--format=%(refname)','refs/heads')=='refs/heads/main'
 logs.append('PASS: actual fm-teardown refused unpushed work, accepted rescue-only work without --force, retained durable rescue head, and left origin with main only.\n')
finally:
 run('tmux','-L','fm-lab','kill-server',expected=None)
 shutil.rmtree(S);shutil.rmtree(L);(E/'live-cleanup.log').write_text('\n'.join(logs))
print('\n'.join(logs[-5:]))
