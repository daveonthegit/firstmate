import os, pathlib, subprocess, json, tempfile, shutil, time
root=pathlib.Path.cwd(); work=root/'.live-validation'; work.mkdir(exist_ok=True)
env=os.environ.copy()
for key in list(env):
 if key.startswith(('FM_', 'TASKS_AXI_', 'HERDR_')) or key in ('TMUX','NO_MISTAKES_GATE'): env.pop(key,None)
def cmd(home, script, *args, ok=True):
 e=env|{'FM_HOME':str(home)}
 p=subprocess.run([str(root/'bin'/script),*args],env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
 print('$',script,*args,'[exit',p.returncode,']'); print(p.stdout,end='',flush=True)
 if ok: assert p.returncode==0,p.stdout
 return p
url='https://github.com/example/isolated-validation/pull/8'
def home(name):
 h=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab-'+name+'-',dir=work))
 cmd(h,'fm-lab-home.sh','create',str(h)); (h/'data/backlog.md').write_text('# Backlog\n\n## Queued\n')
 (h/'config/hold-pr-settle').touch(); return h
def hold(h,id):
 cmd(h,'fm-tasks-axi.sh','add',id,'Decide the integration', '--pr',url)
 cmd(h,'fm-captain-hold.sh','hold',id,'--reason','Approve this integration?')
def policy(h,id,event='terminal',action='close'): cmd(h,'fm-captain-hold.sh','pr-policy',id,url,event,action)
def record(h,id,state='merged',error=None):
 d=h/'data'/id; d.mkdir(exist_ok=True)
 row={'url':url,'kind':'pr','checked_at':'2026-09-16T08:00:00Z','error':error,'pending':[],'seen':[],'verdict':None,'observation':{'head':'a'*40,'state':state,'draft':False,'mergeable':'mergeable','review_decision':'APPROVED','can_merge':False,'checks':[],'reviews':[],'events':[]}}
 (d/'contributions.json').write_text(json.dumps({'schema':'fm-contributions.v1','task':id,'records':[row]}))
def isheld(h,id): return cmd(h,'fm-captain-hold.sh','open',id,ok=False).returncode==0
def poll(h): return cmd(h,'fm-contributions.sh','poll')
def show(h,id): return cmd(h,'fm-tasks-axi.sh','show',id,'--full').stdout
try:
 print('SCENARIO: retained synthetic terminal PR evidence settles declared close/release policies, with idempotent replay')
 for state in ('merged','closed'):
  h=home(state)
  for action in ('close','release'):
   hold(h,action); policy(h,action,action=action); record(h,action,state)
  hold(h,'unrelated'); record(h,'unrelated',state)
  poll(h)
  for action in ('close','release'):
   assert not isheld(h,action)
   s=show(h,action); assert ('state: done' in s)==(action=='close'); assert 'Reconciliation evidence:' in s and 'Captain decision:' not in s
  assert isheld(h,'unrelated')
  before=(h/'data/backlog.md').read_bytes(); poll(h); assert before==(h/'data/backlog.md').read_bytes()
 print('RESULT: terminal close/release and replay passed')
 print('SCENARIO: disabled feature, mismatched event, changed question, wrong PR and errored evidence preserve holds')
 for guard in ('disabled','mismatch','changed','wrong-url','error','reheld'):
  h=home(guard); hold(h,'decision'); policy(h,'decision',event='merged'); record(h,'decision','closed' if guard=='mismatch' else 'merged','forge unavailable' if guard=='error' else None)
  if guard=='disabled': (h/'config/hold-pr-settle').unlink()
  if guard=='changed': cmd(h,'fm-tasks-axi.sh','update','decision','--title','A different question')
  if guard=='reheld': cmd(h,'fm-captain-hold.sh','hold','decision','--reason','A different question')
  if guard=='wrong-url': cmd(h,'fm-captain-hold.sh','settle-pr','decision',url+'9')
  elif guard=='error': cmd(h,'fm-captain-hold.sh','settle-pr','decision',url)
  else: poll(h)
  assert isheld(h,'decision')
  if guard=='disabled':
   (h/'config/hold-pr-settle').touch(); poll(h); assert not isheld(h,'decision')
 print('RESULT: policy/evidence guards passed')
 print('SCENARIO: release waits for away posture and task contention, then settles when attended/unlocked')
 h=home('away'); hold(h,'decision'); policy(h,'decision',action='release'); record(h,'decision')
 cmd(h,'fm-afk-contract.sh','enter','--words','watch the fleet'); poll(h); assert isheld(h,'decision')
 cmd(h,'fm-afk-contract.sh','archive'); poll(h); assert not isheld(h,'decision'); assert 'state: done' not in show(h,'decision')
 h=home('busy'); hold(h,'decision'); policy(h,'decision'); record(h,'decision')
 lock=h/'state/.control-decision.lock'; ready=h/'ready'; release=h/'release'
 code='. "$1"; fm_lock_acquire_wait "$2" || exit 10; touch "$3"; while [ ! -f "$4" ]; do sleep 0.05; done; fm_lock_release "$2"'
 child=subprocess.Popen(['bash','-c',code,'_',str(root/'bin/fm-wake-lib.sh'),str(lock),str(ready),str(release)],env=env|{'FM_HOME':str(h),'FM_STATE_OVERRIDE':str(h/'state')})
 try:
  for _ in range(100):
   if ready.exists(): break
   time.sleep(.05)
  assert ready.exists(); t=time.monotonic(); poll(h); assert time.monotonic()-t<20; assert isheld(h,'decision')
 finally:
  release.touch(); assert child.wait(timeout=10)==0
 poll(h); assert not isheld(h,'decision')
 print('RESULT: away and busy deferral passed')
 print('SCENARIO: retained unmerged closures notify only open holds and only once, including late owners')
 h=home('closure'); hold(h,'first'); record(h,'first','closed'); cmd(h,'fm-tasks-axi.sh','add','bystander','Unheld task','--pr',url); record(h,'bystander','closed')
 poll(h)
 pending=json.loads(cmd(h,'fm-contributions.sh','pending').stdout); assert [p['task'] for p in pending if p['type']=='closed']==['first']
 hold(h,'late'); poll(h)
 pending=json.loads(cmd(h,'fm-contributions.sh','pending').stdout); assert sorted(p['task'] for p in pending if p['type']=='closed')==['first','late']
 before=(h/'state/.wake-queue').read_bytes(); poll(h); assert before==(h/'state/.wake-queue').read_bytes()
 print('RESULT: closure scope, late owner and deduplication passed')
finally:
 shutil.rmtree(work)
