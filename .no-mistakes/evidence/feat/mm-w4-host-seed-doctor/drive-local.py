import os, pathlib, subprocess, json, base64, shutil, time
R=pathlib.Path.cwd(); E=pathlib.Path(__file__).parent; W=R/'.local-test/live'; W.mkdir(parents=True,exist_ok=True)
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR'): env.pop(k)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(R/'.local-test/tmp'))
H=W/'host'; P=W/'primary'; P.mkdir(); (P/'data').mkdir(); (P/'config').mkdir(); (P/'projects').mkdir()
log=open(E/'live-cli.log','w'); results=[]
def call(argv, home=H, data=None, expected=0):
    e=env.copy(); e['FM_HOME']=str(home)
    p=subprocess.run([str(x) for x in argv],input=data,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=e,timeout=50)
    log.write('$ FM_HOME='+str(home)+' '+' '.join(map(str,argv))+'\n'+p.stdout+'exit='+str(p.returncode)+'\n\n'); log.flush()
    assert p.returncode==expected,(argv,p.returncode,p.stdout)
    return p.stdout
def git(*a): return call(['git',*a])
def b(s): return base64.b64encode(str(s).encode()).decode()
origin=W/'origin.git'; src=W/'src'
git('init','-q','-b','main',src); (src/'README').write_text('Disposable W4 example\n'); git('-C',src,'add','README'); git('-C',src,'-c','user.name=Validation','-c','user.email=test@example.invalid','commit','-qm','seed'); git('clone','--bare','-q',src,origin)
name='alpha service'; line='- alpha service [direct-PR forge=forgejo] - disposable W4 example'
def manifest(origin_url=origin, mode='direct-PR', registry=line, required=0, version=None, lanes=2, cap=1):
    s=f'schema=fm-worker-host-home.v1\nhost_id_b64={b("m1")}\nt3_required={required}\nlanes={lanes}\ncapacity={b(name)}|{cap}\nproject_scope=named\nproject_count=1\nproject={b(name)}|{b(origin_url)}|{b(registry)}|{b(mode)}\n'
    if version is not None: s+=f't3_version_b64={b(version)}\nt3_capabilities=launchEnvironment,sessionStop,keepAlive\n'
    return s
M=manifest(); (E/'synthetic-manifest.txt').write_text(M)
def home(m=M, fix=False, rc=0, h=H): return call([R/'bin/fm-worker-host-home.sh']+(['--fix'] if fix else []),home=h,data=m,expected=rc)
def snapshot(path):
    return {str(p.relative_to(path)):p.read_bytes().hex() for p in path.rglob('*') if p.is_file() and '.git' not in p.parts}
try:
    # Check-only must leave a missing home missing; fix builds the actual Git clone.
    out=home(rc=1); assert not H.exists(); assert 'clone:alpha service=fixable' in out
    home(fix=True); assert (H/'.fm-worker-host').read_text().strip()=='m1'; assert (H/'config/backlog-backend').read_text().strip()=='manual'
    assert (H/'data/projects.md').read_text().strip()==line
    assert not (H/'.fm-secondmate-home').exists() and not (H/'config/t3code-token').exists()
    assert (H/'projects'/name/'README').read_bytes()==(src/'README').read_bytes()
    assert (H/'config/project-capacity').read_text().splitlines()[-1]=='alpha service 1'
    before=snapshot(H); out=home(fix=True); assert 'fix ' not in out and before==snapshot(H)
    (H/'data/projects.md').write_text('- alpha service [no-mistakes] - drift\n'); (H/'.fm-worker-host').unlink()
    before=snapshot(H); home(rc=1); assert before==snapshot(H); home(fix=True); assert (H/'data/projects.md').read_text().strip()==line
    results.append('PASS local home convergence: dry-run, real Git clone, spaced name, forge record, capacities, idempotency and drift repair')
    # Refuse incompatible existing declarations.
    before=snapshot(H); out=home(manifest(lanes=3,cap=2),fix=True,rc=1); assert 'lane-capacity=human' in out and 'project-capacity=human' in out; assert before==snapshot(H)
    results.append('PASS capacity conflicts do not overwrite existing declarations')
    # Home ownership guards apply before any home mutation.
    (H/'.fm-worker-host').write_text('other-host\n'); (H/'config/backlog-backend').unlink(); before=snapshot(H)
    out=home(fix=True,rc=1); assert 'marker=human' in out and 'fix ' not in out; assert before==snapshot(H)
    (H/'.fm-worker-host').write_text('m1\n'); (H/'.fm-secondmate-home').touch(); before=snapshot(H)
    out=home(fix=True,rc=1); assert 'secondmate=human' in out and 'fix ' not in out and before==snapshot(H)
    (H/'.fm-secondmate-home').unlink(); home(fix=True)
    results.append('PASS conflicting worker identity and second-mate homes remain untouched')
    # Wrong repository identity must prevent registration and initialization.
    git('-C',H/'projects'/name,'remote','set-url','origin',str(src))
    (H/'data/projects.md').write_text('- alpha service [direct-PR] - preserve me\n'); before=snapshot(H)
    out=home(manifest(mode='no-mistakes',registry='- alpha service [no-mistakes] - requested'),fix=True,rc=1)
    assert 'clone:alpha service=human' in out and 'registry:alpha service=human' in out and 'no-mistakes:alpha service=human' in out
    assert before==snapshot(H); git('-C',H/'projects'/name,'remote','set-url','origin',origin); home(fix=True)
    results.append('PASS wrong-clone identity blocks registry and no-mistakes repairs')
    # Primary validation is driven without opening an account/SSH route.
    (P/'data/worker-hosts.md').write_text(f'- m1 - disposable (host: unreachable.invalid; root: {R}; home: {H}; added 2026-11-10)\n')
    (P/'data/projects.md').write_text(line+'\n- notes [local-only] - local\n')
    for secret in ['https://user:SECRET@forge.example/repo.git','https://SECRET@forge.example/repo.git','ssh://git:SECRET@forge.example/repo.git','https://forge.example/repo.git?token=SECRET']:
        out=call([R/'bin/fm-worker-host-doctor.sh','m1',name+'='+secret],home=P,expected=1); assert 'SECRET' not in out and 'credential-free' in out
        out=home(manifest(origin_url=secret),fix=True,rc=1); assert 'SECRET' not in out and 'credential-free' in out
    out=call([R/'bin/fm-worker-host-seed.sh','m1','--lanes','2','notes'],home=P,expected=1); assert 'local-only' in out
    (P/'data/projects.md').write_text('- alpha service [direct-PR forge=forgjeo] - invalid\n')
    for flag in [[],['--fix']]:
        out=call([R/'bin/fm-worker-host-doctor.sh','m1']+flag,home=P,expected=1); assert 'does not resolve to a delivery posture' in out and 'unknown forge' in out and 'ok: worker host home ready' not in out
    results.append('PASS credential rejection at both manifest boundaries, local-only refusal and unresolved implicit discovery')
    # Real MCP client -> localhost protocol emulator; no actual account or T3 service.
    server=W/'t3'; server.mkdir(); (server/'case').write_text(str(server)); world=server/'world.json'
    world.write_text(json.dumps(dict(serverVersion='0.1.7+fork.1',launchEnvironment=True,sessionStop=True,keepAlive=True,tokens=['disposable-local-token'])))
    serverlog=open(E/'local-t3-server.log','w')
    child=subprocess.Popen(['node',str(R/'tests/t3-fake-server.mjs'),'--case-file',str(server/'case'),'--port-file',str(server/'port'),'--parent-pid',str(os.getpid())],stdout=serverlog,stderr=subprocess.STDOUT,env=env)
    try:
        for _ in range(100):
            if (server/'port').exists(): break
            time.sleep(.05)
        url='http://127.0.0.1:'+(server/'port').read_text().strip()
        token=H/'config/t3code-token'
        def credential(expiry):
            token.write_text(json.dumps(dict(version=1,origin=url,access_token='disposable-local-token',issued_at=0,expires_at=expiry,access='full-access',environment_id='env-fake-1',server_version='0.1.7+fork.1'))); token.chmod(0o600)
        credential(int((time.time()+30*86400)*1000)); T=manifest(required=1,version='0.1.7+fork.1')
        out=home(T); assert 'days left' in out and 't3-version=ok' in out and 't3-capabilities=ok' in out
        d=json.loads(world.read_text()); d.update(serverVersion='0.1.7',sessionStop=False,keepAlive=False); world.write_text(json.dumps(d))
        out=home(T,fix=True,rc=1); assert 't3-version=human' in out and 't3-capabilities=human' in out
        credential(int((time.time()-3600)*1000)); out=home(T,rc=1); assert 'expired' in out
        token.unlink(); out=home(T,fix=True,rc=1); assert 't3-credential=human' in out and not token.exists()
        out=home(manifest(required=1),rc=1); assert 't3-primary=human' in out
        credential(int((time.time()+30*86400)*1000)); out=home(manifest(required=1),rc=1); assert 't3-primary=human' in out
        shutil.copyfile(server/'requests.jsonl',E/'local-t3-requests.jsonl')
        results.append('PASS real Firstmate MCP client against localhost emulator: days left, matching/mismatched versions/capabilities, expiry/missing token, unavailable primary comparison')
    finally:
        child.terminate(); child.wait(timeout=10); serverlog.close(); log.write('Local T3 emulator stopped; exit='+str(child.returncode)+'\n')
    (E/'local-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('\n'.join(results))
finally:
    log.close()
    shutil.rmtree(W)
