"""Drive the actual offline public CLI with synthetic files, not a T3 login.
Oracle: docs/remote-secondmates.md requires this home's regular file and a
loopback origin; linked/foreign/absent credentials must be refused.
"""
import json, os, pathlib, subprocess, tempfile, time
root = pathlib.Path.cwd()
with tempfile.TemporaryDirectory(dir=root / '.test-phase-tmp', prefix='offline-') as temp:
    home = pathlib.Path(temp)
    token = home / 'token'
    linked = home / 'linked'
    base = dict(origin='http://127.0.0.1:9', access_token='synthetic-offline-only-not-a-login', expires_at=int(time.time()*1000)+20*86400000, environment_id='synthetic-offline')
    def save(origin):
        token.write_text(json.dumps(dict(base, origin=origin)))
        token.chmod(0o600)
    def drive(label, path, expected, code=None):
        cmd = ['node', 'bin/fm-t3-mcp.mjs', 'host-credential', '--token-file', str(path)]
        p = subprocess.run(cmd, text=True, capture_output=True)
        print(label, '\n$', ' '.join(cmd), '\nexit=', p.returncode, '\n'+p.stdout+p.stderr, flush=True)
        assert p.returncode == expected, (label, p.returncode)
        if code: assert code in p.stdout+p.stderr, label
        else: assert json.loads(p.stdout)['ok'] is True
    drive('Absent credential refuses with captain sign-in guidance', token, 4, 'no_credential')
    save('http://127.0.0.1:9')
    drive('Regular loopback file passes offline ownership check (NOT server authentication)', token, 0)
    linked.symlink_to(token)
    drive('Link to another file is refused even when target is otherwise valid', linked, 4, 'credential_linked')
    save('http://192.0.2.10:3773')
    drive('Foreign-host origin is refused before network access', token, 4, 'credential_not_local')
    save('http://127.0.0.1:9')
    token.chmod(0o644)
    drive('Over-readable credential is refused', token, 4, 'credential_permissions')
print('Offline public CLI checks completed; no server, login, or production data used.')
