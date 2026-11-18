import os, sys, pathlib, subprocess, json, time, shutil, traceback
root=pathlib.Path.cwd(); lab=root/'.test-board'; home=lab/'home'
evidence=pathlib.Path('~/.no-mistakes/evidence/01M7QTBSQB1ZHTV9SQ3ZTE78CB')
log=(evidence/'live-board-transcript.log').open('w',buffering=1)
def note(s): print(s,flush=True); log.write(s+'\n')
def comment(i,created,body,updated=None):
    return dict(id=i,user={'login':'reagan-bot' if i%2==0 else 'itamarseg'},created_at=created,updated_at=updated or created,body=body,html_url=f'https://github.com/BG-Media-LLC/agent-board/issues/1#issuecomment-{i}')
def state(comments=None,fail=False):
    data=json.loads((lab/'state.json').read_text()) if (lab/'state.json').exists() else {}
    if comments is not None: data['comments']=comments
    data['fail']=fail
    p=lab/'state.new'; p.write_text(json.dumps(data)); p.replace(lab/'state.json')
state([comment(100,'2026-11-01T10:00:00Z','[Front Desk] OLD HISTORY')])
server=subprocess.Popen([sys.executable,str(lab/'emulator.py')],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
runner=None
try:
    for _ in range(100):
        if (lab/'port').exists(): break
        time.sleep(.05)
    port=(lab/'port').read_text()
    env=os.environ.copy()
    for k in list(env):
        if k.startswith('FM_') or k.upper() in ('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN'): env.pop(k,None)
    env.update(FM_HOME=str(home),FM_PROCEVENT_CLAIM_ROOT=str(lab/'claims'),FM_BOARD_TEST_SLEEP='0.2',GH_CONFIG_DIR=str(lab/'gh'),SSL_CERT_FILE=str(lab/'cert.pem'),HTTPS_PROXY='http://127.0.0.1:'+port,HTTP_PROXY='http://127.0.0.1:'+port,NO_PROXY='',TMPDIR=str(lab/'tmp'),GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1')
    def run(script,*args,input=None,ok=True):
        cmd=[str(root/'bin'/script),*args] if script.endswith('.sh') else [script,*args]
        p=subprocess.run(cmd,input=input,text=True,capture_output=True,env=env,timeout=45)
        note('$ '+ ' '.join([script,*args])+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode))
        if ok: assert p.returncode==0
        return p
    def results(): return sorted((home/'state/procevent-inbox').glob('*.result'),key=lambda p:p.stat().st_mtime_ns)
    def cursor():
        p=home/'state/agent-board-watch/cursor'; return p.read_text().strip() if p.exists() else ''
    def waitfor(f,msg,timeout=35):
        stop=time.time()+timeout
        while time.time()<stop:
            if f(): return
            time.sleep(.1)
        raise AssertionError(msg)
    def start():
        global runner
        runner=subprocess.Popen([str(root/'bin/fm-procevent.sh'),'start','agent-board'],env=env,stdout=(lab/'runner.out').open('a'),stderr=subprocess.STDOUT)
    def finish(label):
        global runner
        rc=runner.wait(timeout=40); assert rc==0, (rc,(lab/'runner.out').read_text()); runner=None
        p=results()[-1]; text=p.read_text(); note('RESULT '+label+'\n'+text)
        shutil.copyfile(p,evidence/(label+'.txt'))
        assert p.with_suffix('.handled').exists()
        return text
    # Real GitHub CLI, isolated synthetic account, all network through localhost TLS emulator.
    run('gh','--version'); run('gh','auth','status')
    cfg=home/'config/agent-board'; cfg.unlink()
    assert run('fm-procevent-board.sh','arm',ok=False).returncode!=0
    assert run('fm-board-post.sh','-',input='hello',ok=False).returncode!=0
    assert run('fm-procevent-board.sh','ensure').stdout==''
    assert not (home/'state/procevent/agent-board.source').exists()
    for setting in ['repo=elsewhere/board','issue=2','self_tag=[Impostor]']:
        cfg.write_text(setting+'\n')
        assert run('fm-procevent-board.sh','config',ok=False).returncode!=0
    cfg.write_text('interval=30\naccount=fm-board-lab\n')
    c=run('fm-procevent-board.sh','config').stdout
    assert 'interval=60' in c and "self_tag=[David's Firstmate]" in c and 'repo=BG-Media-LLC/agent-board' in c
    run('fm-procevent-board.sh','ensure')
    source=home/'state/procevent/agent-board.source'; before=source.read_bytes()
    assert run('fm-procevent-board.sh','ensure').stdout=='' and source.read_bytes()==before
    note('SCENARIO 1 PASS: opt-in, fixed destination/tag, floor, idempotent arm')
    start(); waitfor(lambda:cursor()=='2026-11-01T10:00:00Z\t100','baseline')
    time.sleep(1); assert not results()
    state([comment(101,'2026-11-01T10:05:00Z',"[David's Firstmate] own reply")])
    waitfor(lambda:cursor()=='2026-11-01T10:05:00Z\t101','own post skipped')
    assert not results()
    state([comment(102,'2026-11-01T10:09:00Z','[Reagan Pages] Please review https://github.com/BG-Media-LLC/reagan-gold-group-lp/pull/16\nDo not merge without David.')])
    text=finish('review-request')
    assert 'messages=1' in text and 'Please review' in text and 'OLD HISTORY' not in text and 'own reply' not in text
    queue=(home/'state/.wake-queue').read_text(); assert 'procevent:agent-board:' in queue
    note('DURABLE WAKE QUEUE\n'+queue)
    note('SCENARIO 2 PASS: idle listening, baseline and self suppression, review request durably delivered and acknowledged')
    n=len(results()); start(); time.sleep(1); assert len(results())==n and runner.poll() is None
    state([comment(102,'2026-11-01T10:09:00Z','[Reagan Pages] existing'),comment(103,'2026-11-01T10:09:00Z','[Front Desk] newly arriving same second')])
    text=finish('same-second'); assert 'messages=1' in text and 'edited=0' in text and '(edited ' not in text and 'existing' not in text
    start(); state([comment(102,'2026-11-01T10:09:00Z','[Reagan Pages] revised review request','2026-11-01T10:20:00Z')])
    text=finish('edited-comment'); assert 'edited=1' in text and '(edited 2026-11-01T10:20:00Z)' in text
    start(); state([comment(110,'2026-11-01T11:00:00Z','[Front Desk] comment after prior comments deleted')])
    assert 'comment after prior comments deleted' in finish('after-deletion')
    note('SCENARIO 3 PASS: restart dedup, unseen same-second comment not edited, true edit, deletion-safe cursor')
    start(); state(fail=True); text=finish('api-diagnostic'); assert 'diagnostic=not-found' in text
    n=len(results()); start(); time.sleep(3); assert len(results())==n and runner.poll() is None
    state(fail=False); assert 'recovered_from=not-found' in finish('api-recovered')
    assert not (home/'state/agent-board-watch/diagnostic').exists()
    note('SCENARIO 4 PASS: API failure durably diagnosed once, quiet retry and recovery')
    url=run('fm-board-post.sh','-',input='Review complete: request changes.').stdout.strip()
    assert url.endswith('#issuecomment-900')
    run('fm-board-post.sh','-',input="[David's Firstmate] Already tagged café ✓")
    assert run('fm-board-post.sh','-',input='  \n',ok=False).returncode!=0
    posts=json.loads((lab/'state.json').read_text())['posts']
    assert posts==[{'body':"[David's Firstmate] Review complete: request changes."},{'body':"[David's Firstmate] Already tagged café ✓"}]
    note('PERSISTED EMULATED GITHUB COMMENTS\n'+json.dumps(posts,ensure_ascii=False,indent=2))
    requests=[json.loads(l) for l in (lab/'requests.jsonl').read_text().splitlines()]
    writes=[r for r in requests if r['method']!='GET']
    assert len(writes)==2 and all(r['method']=='POST' and r['path']=='/repos/BG-Media-LLC/agent-board/issues/1/comments' and r['synthetic_token'] for r in writes)
    assert all(r['synthetic_token'] for r in requests)
    note('SCENARIO 5 PASS: real gh posts exactly one tagged comment, preserves UTF-8, rejects empty input, no other writes')
    run('fm-procevent-board.sh','retire'); assert not source.exists()
    note('ALL FIVE LOCAL LIVE SCENARIOS PASSED; synthetic localhost GitHub only, not private-board or agent-dispatch validation.')
except Exception:
    note(traceback.format_exc()); raise
finally:
    if runner and runner.poll() is None:
        subprocess.run([str(root/'bin/fm-procevent.sh'),'retire','agent-board'],env=env,capture_output=True,timeout=30)
        try: runner.wait(timeout=15)
        except subprocess.TimeoutExpired: runner.terminate(); runner.wait(timeout=10)
    server.terminate(); server.wait(timeout=10)
    (evidence/'local-github-requests.jsonl').write_text((lab/'requests.jsonl').read_text() if (lab/'requests.jsonl').exists() else '')
    note('CLEANUP: runner and localhost emulator stopped.')
    log.close()
