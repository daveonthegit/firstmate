#!/run/current-system/sw/bin/python3
# Local SSH transport emulator: decode fm-on's wire argv and execute the REAL
# worker control CLI. This does NOT exercise the production job daemon.
import os,shlex,base64,subprocess,pathlib
root=pathlib.Path(__file__).resolve().parent.parent
args=shlex.split(os.environ['SSH_ORIGINAL_COMMAND'])
assert args[:2]==['fm-remote-entrypoint.sh','1'], args
remote_root,home=[base64.b64decode(x).decode() for x in args[2:4]]
argv=base64.b64decode(args[4]).decode().rstrip('\0').split('\0')
assert remote_root==str(root) and argv[0]=='fm-remote-worker-control.sh'
base=root/'.validation'
env=dict(os.environ)
for k in list(env):
 if k.startswith('FM_') or k in ('GH_HOST','TMUX'): del env[k]
env.update(FM_HOME=home,FM_ROOT_OVERRIDE=str(root),FM_GH_ACCOUNT='none',HOME=str(base/'user-home'),GH_CONFIG_DIR=str(base/'gh-config'),GH_TOKEN='synthetic-token',GH_ENTERPRISE_TOKEN='synthetic-token',HTTPS_PROXY='http://127.0.0.1:22283',SSL_CERT_FILE=str(base/'cert.pem'),PATH=(base/'path').read_text().strip(),GH_PROMPT_DISABLED='1',GH_NO_UPDATE_NOTIFIER='1')
with open(base/'transport.log','a') as f: f.write('real SSH dispatched '+repr(argv)+'\n')
raise SystemExit(subprocess.call([str(root/'bin'/argv[0])]+argv[1:],env=env))
