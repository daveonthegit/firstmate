import os, pathlib, subprocess, json, resource, shutil
root = pathlib.Path.cwd()
base = root / '.test-phase' / 'live'
base.mkdir()
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','HERDR_ENV','HERDR_SESSION','HERDR_PANE_ID'):
        env.pop(key, None)
env['HOME'] = str(root / '.test-phase/home')
env['TMPDIR'] = str(root / '.test-phase/tmp')

def run(args, home, expected=0, lowfd=False):
    e = dict(env, FM_HOME=str(home), TMUX='nonexistent-lab-socket,0,0')
    print('$', ' '.join(map(str,args)), flush=True)
    def limit():
        _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE,(64,hard))
    p = subprocess.run(list(map(str,args)), cwd=home, env=e, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, preexec_fn=limit if lowfd else None)
    print(p.stdout, end='' if p.stdout.endswith('\n') else '\n', flush=True)
    print('exit:',p.returncode,flush=True)
    assert (p.returncode == 0) if expected == 0 else (p.returncode != 0)
    return p.stdout
captain=root/'bin/fm-captain-hold.sh'
for scope in ('repo','user'):
    home=base/scope
    run([root/'bin/fm-lab-home.sh','create',home],base)
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    config='backend = "markdown"\n[markdown]\npath = "data/backlog.md"\ndone_keep = 10\n'
    setting='archive = "data/done # archive.md" # trailing comment\n'
    if scope=='repo': config+=setting
    else:
        config_dir=pathlib.Path(env['HOME'])/'.tasks-axi'
        config_dir.mkdir(exist_ok=True)
        (config_dir/'config.toml').write_text('[markdown]\n'+setting)
    (home/'.tasks.toml').write_text(config)
    run(['tasks-axi','add','lab-scout','Investigate archived answers','--kind','scout','--repo','sample','--start'],home)
    (home/'state/lab-scout.meta').write_text(f'window=lab:fm-lab-scout\nkind=scout\nmode=scout\nharness=codex\nspawn_gen=live-scout\nworktree={home}/projects/missing\nproject={home}/projects/sample\n')
    (home/'state/lab-scout.status').write_text('done: report complete\n')
    (home/'data/lab-scout').mkdir()
    (home/'data/lab-scout/report.md').write_text('# Report\nCaptain chose option A.\n')
    run([captain,'hold','lab-call','--title','Choose an option','--reason','Captain decision needed','--repo','sample','--origin','lab-scout'],home)
    run([captain,'complete','lab-scout','lab-call'],home)
    (home/'decision.txt').write_text('Captain chose option A.\n')
    run([captain,'answer','lab-call','--decision-file',home/'decision.txt'],home)
    (home/'.tasks.toml').write_text(config.replace('done_keep = 10','done_keep = 0'))
    run(['tasks-axi','add','lab-trigger','Trigger Done retention','--kind','ship','--repo','sample'],home)
    run(['tasks-axi','done','lab-trigger'],home)
    run(['tasks-axi','show','lab-call'],home,expected=1)
    archive=home/'data/done # archive.md'
    assert archive.exists()
    print('ARCHIVE persisted contract:\n'+archive.read_text(),flush=True)
    run([captain,'verify','lab-scout'],home)
    run([captain,'complete','lab-scout','lab-call'],home)
    # Recorded endpoint is absent on an explicitly isolated, nonexistent socket.
    run([root/'bin/fm-teardown.sh','lab-scout'],home)
    assert not (home/'state/lab-scout.meta').exists()
    if scope=='repo':
        run(['tasks-axi','add','lab-unanswered','Investigate unanswered close','--kind','scout','--repo','sample','--start'],home)
        (home/'state/lab-unanswered.meta').write_text('window=lab:fm-lab-unanswered\nkind=scout\nmode=scout\nharness=codex\nspawn_gen=live-unanswered\n')
        (home/'state/lab-unanswered.status').write_text('done: report complete\n')
        run([captain,'hold','lab-unanswered-call','--title','Still needs an answer','--reason','No decision recorded','--repo','sample','--origin','lab-unanswered'],home)
        run([captain,'complete','lab-unanswered','lab-unanswered-call'],home)
        run(['tasks-axi','done','lab-unanswered-call'],home)
        run([captain,'verify','lab-unanswered'],home,expected=1)
        run([root/'bin/fm-teardown.sh','lab-unanswered'],home,expected=1)
        assert (home/'state/lab-unanswered.meta').exists()
        with (home/'state/lab-unanswered.meta').open('a') as out:
            out.write('decisions_reviewed=1\ndecision_keys=lab-never-held\n')
        refusal=run([captain,'verify','lab-unanswered'],home,expected=1)
        assert 'lab-never-held' in refusal
    if scope=='user': (config_dir/'config.toml').unlink()

home=base/'export'
run([root/'bin/fm-lab-home.sh','create',home],base)
export=base/'exported-records'
(home/'config/record-export-root').write_text(str(export)+'\n')
for i in range(150):
    task=home/f'data/task-{i:03d}'
    task.mkdir()
    (task/'brief.md').write_text(f'Brief {i}\n')
    (task/'report.md').write_text(f'Report {i}\n')
(home/'data/private.txt').write_text('Not allowlisted\n')
(home/'state/task-000.meta').write_text('spawn_gen=live-generation\nkind=scout\n')
(home/'state/task-000.status').write_text('done: report complete\n')
exporter=root/'bin/fm-record-export.sh'
run([exporter,'sync'],home,lowfd=True)
files=list((export/'live').rglob('*.md'))
assert len(files)==300
assert not (export/'live/data/private.txt').exists()
print('LIVE SNAPSHOT: 150 tasks / 300 byte-checked brief and report files, RLIMIT_NOFILE=64; private.txt excluded',flush=True)
for path in files:
    relative=path.relative_to(export/'live')
    assert path.read_bytes()==(home/relative).read_bytes()
run([exporter,'archive-task','task-000'],home,lowfd=True)
manifest=export/'archive/task-000/live-generation/manifest.v1.json'
print('COMMITTED MANIFEST:\n'+manifest.read_text(),flush=True)
# Adversarial no-follow check must preserve previous published generation.
previous=os.readlink(export/'live')
(home/'data/task-000/brief.md').unlink()
(home/'data/task-000/brief.md').symlink_to(home/'data/private.txt')
run([exporter,'sync'],home,expected=1,lowfd=True)
assert os.readlink(export/'live')==previous
assert (export/'live/data/task-000/brief.md').read_text()=='Brief 0\n'
print('Prior live generation retained after rejected symlink.',flush=True)
shutil.rmtree(base)
print('Disposable live homes removed.',flush=True)
