import os,sys,subprocess as s,pathlib as p,time,socket,shutil,json,signal
R=p.Path.cwd(); E=p.Path('~/.no-mistakes/evidence/01M75JFWHGAPG7X7HQN8KMY046'); D=R/'.t'; logs=[]; server=None;thread=None;token=None;threads=[]
D.mkdir(exist_ok=True)
env=os.environ.copy();env.update(T3CODE_HOME=str(D),T3CODE_TELEMETRY_ENABLED='false',TMPDIR=str(R),NODE_COMPILE_CACHE=str(D/'cache'))
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:env.pop(k,None)
def run(args,timeout=60):
 q=s.run(list(map(str,args)),env=env,capture_output=True,text=True,timeout=timeout); logs.append('$ '+' '.join(map(str,args))+'\n'+q.stdout+q.stderr+'\nexit='+str(q.returncode));return q
try:
 with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
 out=open(E/'t3-server.log','w');server=s.Popen(['t3','serve','--base-dir',str(D),'--host','127.0.0.1','--port',str(port),'--no-browser'],env=env,stdout=out,stderr=s.STDOUT,start_new_session=True)
 for i in range(45):
  if (D/'userdata/server-runtime.json').exists():break
  if server.poll()!=None:raise RuntimeError('server exited '+str(server.returncode))
  time.sleep(1)
 rt=json.loads((D/'userdata/server-runtime.json').read_text());logs.append('runtime='+json.dumps(rt))
 # Fresh disposable-server OAuth consent only; never contacts the operator server or edits its credentials.
 token=D/'token.json'
 q=run(['node','bin/fm-t3-mcp.mjs','login','--access','full-access','--url',f'http://127.0.0.1:{port}','--base-dir',D,'--token-file',token]);assert q.returncode==0,q.stdout+q.stderr
 q=run(['node','bin/fm-t3-mcp.mjs','status','--token-file',token]);assert q.returncode==0,q.stdout+q.stderr
 work=D/'work';work.mkdir();run(['git','init',work]);run(['git','-C',work,'-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','commit.gpgsign=false','commit','--allow-empty','-m','Disposable fixture'])
 q=run(['node','bin/fm-t3-mcp.mjs','project-ensure','--root',work,'--title','Disposable W2 validation','--token-file',token]);assert q.returncode==0,q.stdout+q.stderr
 project=json.loads(q.stdout);logs.append('project='+json.dumps(project))
 code="""import {McpSession} from './bin/fm-t3-mcp.mjs';import fs from 'node:fs';let c=JSON.parse(fs.readFileSync(process.argv[1]));let s=new McpSession(c.origin,c.access_token);try{await s.open();console.log(JSON.stringify(await s.call('orchestrator_capabilities',{})));}finally{await s.close()}"""
 q=run(['node','--input-type=module','-e',code,token]);assert q.returncode==0;caps=json.loads(q.stdout);(E/'t3-capabilities.json').write_text(json.dumps(caps,indent=2))
 model=next(x for x in caps['providers'] if x['providerInstanceId']=='claudeAgent')['models'][0]['id']
 def mcp(verb,*args):return run(['node','bin/fm-t3-mcp.mjs',verb,*args,'--token-file',token],90)
 q=mcp('resolve-selection','--harness','claude','--instance','claudeAgent','--model',model,'--effort','low','--project',project['projectId']);assert q.returncode==0,q.stdout
 sel=json.loads(q.stdout)['selection']
 q=mcp('launch','--project',project['projectId'],'--title','W2 question validation','--model-selection',json.dumps(sel));assert q.returncode==0,q.stdout
 thread=json.loads(q.stdout)['threadId'];threads.append(thread)
 parent=D/'parent';host=D/'host'
 for home in [parent,host]:
  assert run(['bin/fm-lab-home.sh','create',home]).returncode==0
  (home/'config/backlog-backend').write_text('manual\n');(home/'state/.lock').write_text(str(os.getpid())+'\n');(home/'state/.last-watcher-beat').touch()
 (host/'.fm-worker-host').touch();shutil.copyfile(token,host/'config/t3code-token');(host/'config/t3code-token').chmod(0o600)
 (host/'state/t2.remote-worker').touch()
 (host/'state/t2.meta').write_text(f'window=t3code:{thread}\nbackend=t3code\nt3_thread_id={thread}\nendpoint_task_id=t2\nharness=claude\nkind=ship\nworktree={work}\nproject={work}\n')
 (parent/'state/t2.meta').write_text(f'window=remote:t2\nharness=claude\nkind=ship\nremote_worker_host=mbp\nremote_root={R}\nremote_home={host}\n')
 (parent/'data/worker-hosts.md').write_text(f'- mbp - local T3 worker (host: lab-local; root: {R}; home: {host}; added 2026-11-10)\n')
 adapter=D/'transport.py';adapter.write_text('''#!/usr/bin/env python3
import os,sys,base64,subprocess
args=sys.argv[1:]
while args and args[0]=='-o':args=args[2:]
if args[0]=='--':args=args[1:]
assert args[:3]==['lab-local','fm-remote-entrypoint.sh','1']
root,home=map(lambda x:base64.b64decode(x).decode(),args[3:5]);argv=base64.b64decode(args[5]).decode().rstrip('\\0').split('\\0');e=os.environ.copy();e['FM_HOME']=home
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']:e.pop(k,None)
sys.exit(subprocess.run([root+'/bin/'+argv[0]]+argv[1:],env=e).returncode)
''');adapter.chmod(0o755)
 env.update(FM_HOME=str(parent),FM_SSH_BIN=str(adapter))
 msg=D/'message';msg.write_text('Validation only. Do not execute commands or modify files. You MUST call the native AskUserQuestion tool now with one question: Which label should be used? Offer Alpha and Beta as the two options. After the user answers, reply exactly LABEL_BETA_CONFIRMED if they selected Beta. Do not answer the question yourself or put it only in prose.')
 q=mcp('send','--thread',thread,'--message-file',msg,'--client-request-id','w2-question-1');assert q.returncode==0,q.stdout
 pending=None
 for i in range(40):
  q=run(['bin/fm-t3-answer.sh','t2'],30)
  if q.returncode==0:
   pending=json.loads(q.stdout)
   if pending.get('questions'):break
  time.sleep(2)
 assert pending and pending.get('questions'),'real provider did not expose a pending question'
 (E/'t3-question-before.json').write_text(json.dumps(pending,indent=2))
 (host/'state/t2.status').write_text('blocked: awaiting the observed label question\n')
 q=run(['bin/fm-crew-state.sh','t2']);assert q.returncode==0 and 'state: blocked' in q.stdout and 'on worker host mbp' in q.stdout,q.stdout+q.stderr
 q=run(['bin/fm-peek.sh','t2','100']);assert q.returncode==0 and 'user_input_request' in q.stdout,q.stdout+q.stderr
 question=pending['questions'][0];request=question['requestId'];items=question['questions'];logs.append('QUESTIONS='+json.dumps(items))
 answers={item['id']:'Beta' for item in items}
 q=run(['bin/fm-t3-answer.sh','t2',request,json.dumps(answers)]);assert q.returncode==0,q.stdout+q.stderr
 q=run(['bin/fm-t3-answer.sh','t2']);assert q.returncode==0;qj=json.loads(q.stdout);assert not qj['questions'];(E/'t3-question-after.json').write_text(json.dumps(qj,indent=2))
 for i in range(20):
  q=mcp('capture','--thread',thread,'--lines','100')
  if '[assistant_message/completed] LABEL_BETA_CONFIRMED' in q.stdout:break
  time.sleep(2)
 (E/'t3-thread-capture.txt').write_text(q.stdout)
 assert '[assistant_message/completed] LABEL_BETA_CONFIRMED' in q.stdout,'answer not consumed by the real provider'
 logs.append('T3_QUESTION_SCENARIO=PASS')
 # Adversarial approval fixture is created by the real server/provider in approval-required mode.
 code="""import {McpSession} from './bin/fm-t3-mcp.mjs';import fs from 'node:fs';let c=JSON.parse(fs.readFileSync(process.argv[1]));let s=new McpSession(c.origin,c.access_token);try{await s.open();console.log(JSON.stringify(await s.call('t3_thread_launch',JSON.parse(process.argv[2]))));}finally{await s.close()}"""
 args={'projectId':project['projectId'],'title':'Approval boundary probe','modelSelection':sel,'runtimeMode':'approval-required','interactionMode':'default','workspaceStrategy':{'type':'root'},'message':'Call Bash to run exactly: printf APPROVAL_BOUNDARY_PROBE > approval-probe.txt . Do not use any other tool to write the file. This is a disposable test directory.'}
 q=run(['node','--input-type=module','-e',code,token,json.dumps(args)]);assert q.returncode==0,q.stdout
 thread=json.loads(q.stdout)['threadId'];threads.append(thread)
 meta=host/'state/t2.meta';meta.write_text(meta.read_text().replace(threads[0],thread))
 for i in range(30):
  q=run(['bin/fm-t3-answer.sh','t2']);assert q.returncode==0,q.stderr
  pending=json.loads(q.stdout)
  if pending.get('approvals',0)>0:break
  time.sleep(2)
 assert pending.get('approvals',0)>0,'real provider did not expose an approval for the boundary probe'
 assert not pending['questions'],'approval incorrectly exposed as an answerable question'
 (E/'t3-approval-before.json').write_text(json.dumps(pending,indent=2))
 approval=pending['signature'].split(';a:',1)[1].split(':',1)[1]
 q=run(['bin/fm-t3-answer.sh','t2',approval,'{}']);assert q.returncode!=0,'approval unexpectedly answerable through fm-t3-answer'
 q=run(['bin/fm-t3-answer.sh','t2']);assert q.returncode==0
 after=json.loads(q.stdout);assert after['approvals']==pending['approvals'] and not (work/'approval-probe.txt').exists()
 (E/'t3-approval-after.json').write_text(json.dumps(after,indent=2));logs.append('T3_APPROVAL_BOUNDARY=PASS')
finally:
 if token:
  for thread in threads:
   run(['node','bin/fm-t3-mcp.mjs','session-stop','--thread',thread,'--client-request-id','w2-cleanup','--token-file',token],45)
   run(['node','bin/fm-t3-mcp.mjs','archive','--thread',thread,'--token-file',token],45)
 if server and server.poll()==None:
  os.killpg(server.pid,signal.SIGTERM)
  try:server.wait(timeout=15)
  except s.TimeoutExpired:os.killpg(server.pid,signal.SIGKILL);server.wait()
 if server:logs.append('server exit='+str(server.returncode))
 (E/'t3-local-transcript.log').write_text('\n\n'.join(logs));shutil.rmtree(D,ignore_errors=True)
