"""Exercise the real inventory CLI only; never start ShellCheck/actionlint.
Oracles: canonical public inventory (direct *.sh files), set partition laws,
byte-balancing bound, legacy N=2 support, and supported totals {2,4}.
"""
import collections
import json
import os
from pathlib import Path
import subprocess

out = Path(__file__).parent
transcript = []
env = dict(os.environ, CI='false', GITHUB_ACTIONS='false')

def invoke(args, expected=0):
    cmd = ['bin/fm-lint.sh', *args]
    p = subprocess.run(cmd, env=env, text=True, capture_output=True, timeout=45)
    transcript.append({'command': cmd, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    assert p.returncode == expected, (cmd, p.returncode, p.stderr)
    return p.stdout.splitlines()

try:
    canonical = sorted(str(p) for d in ['bin', 'bin/backends', 'tests']
                       for p in Path(d).glob('*.sh') if p.is_file() and not p.name.startswith('.'))
    summary = {}
    for total in [4, 2]:
        groups = []
        loads = []
        for i in range(1, total + 1):
            name = f'{i}of{total}'
            roots = invoke(['--partition', name, '--list-files'])
            assert roots, name
            assert roots == invoke([f'--partition={name}', '--list-files']), name
            assert roots == invoke(['--partition', name, '--list-files']), name
            groups.extend(roots)
            load = sum(Path(r).stat().st_size for r in roots)
            loads.append(load)
            summary[name] = {'roots': len(roots), 'bytes': load}
        assert collections.Counter(groups) == collections.Counter(canonical), 'lost or duplicated roots'
        assert max(loads) - min(loads) <= max(Path(r).stat().st_size for r in canonical), 'not byte balanced'
    invalid = ['', '0of2', '0of4', '3of2', '5of4', '1of1', '1of3', '1of5', '1of6', '1of7', '1of8', '1of9', '1of10', 'Kof4', '01of4', '1of04', '-1of4', '1of4of4']
    for value in invalid:
        for args in [['--partition', value], [f'--partition={value}']]:
            assert not invoke([*args, '--list-files'], 2)
    invoke(['--partition'], 2)
    for total in [2, 4]:
        for i in range(1, total+1):
            for forbidden in [['--fast'], ['bin/fm-lint.sh']]:
                assert not invoke(['--partition', f'{i}of{total}', *forbidden, '--list-files'], 2)
    summary['oracle_inventory_roots'] = len(canonical)
    summary['result'] = 'all inventory and refusal assertions passed; no analysis tools executed'
    (out / 'partition-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
finally:
    (out / 'partition-cli-transcript.json').write_text(json.dumps(transcript, indent=2) + '\n')
