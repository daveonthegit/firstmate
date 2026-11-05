#!/usr/bin/env bash
set -eu
D="$PWD/.gate-lab"; E=~/.no-mistakes/evidence/01M6PKMN43MHXMXK8YNN8EX7Y3
export GH_CONFIG_DIR="$D/gh-local-synthetic" SSL_CERT_FILE="$D/cert.pem" HTTPS_PROXY=http://127.0.0.1:19348 HTTP_PROXY=http://127.0.0.1:19348 NO_PROXY='' GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
unset GH_TOKEN GITHUB_TOKEN FM_GH_ACCOUNT
mkdir -p "$GH_CONFIG_DIR"
python3 "$D/github-local.py" "$D/cert.pem" "$D/key.pem" "$E/local-github-requests.jsonl" > "$D/proxy.log" 2>&1 & p=$!
trap 'kill "$p" 2>/dev/null || :; wait "$p" 2>/dev/null || :' EXIT
sleep 1
# Both credentials are synthetic, accepted only by our localhost TLS emulator.
# --insecure-storage confines these test credentials to GH_CONFIG_DIR; no system keychain writes.
printf synthetic-dave | gh auth login --hostname github.com --with-token --insecure-storage
printf synthetic-secco | gh auth login --hostname github.com --with-token --insecure-storage
# Deliberately leave the wrong account globally active inside the disposable config.
gh auth switch --hostname github.com --user fixture-source
export FM_HOME="$D/mate" FM_GH_ACCOUNT_BIN="$PWD/bin/fm-gh-account.sh"
printf "BG-Media-LLC fixture-target\n" > "$D/mate/config/gh-accounts"
gh auth status > "$E/local-gh-accounts.txt" 2>&1
bin/fm-gh-account.sh resolve --repo BG-Media-LLC/validation > "$E/local-account-resolved.txt"
bin/fm-gh-account.sh exec --repo BG-Media-LLC/validation -- gh api repos/BG-Media-LLC/validation > "$E/local-mapped-repo.json"
# An explicit old launch pin must reproduce the captain's 404 against the same local repository.
if FM_GH_ACCOUNT=fixture-source bin/fm-gh-account.sh exec --repo BG-Media-LLC/validation -- gh api repos/BG-Media-LLC/validation > "$E/local-old-pin-response.txt" 2>&1; then echo 'Expected old pin to fail' >&2; exit 1; fi
# Confirm selection is child-local, not an auth-switch side effect.
gh api user > "$E/local-active-account-after.json"
python3 - "$E" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1]);assert (p/'local-account-resolved.txt').read_text().strip()=='fixture-target'
assert json.loads((p/'local-mapped-repo.json').read_text())['full_name']=='BG-Media-LLC/validation'
assert json.loads((p/'local-active-account-after.json').read_text())['login']=='fixture-source'
print('Real gh + local GitHub emulator: mapped repository succeeds as fixture-target; old pin returns 404; active account unchanged.')
PY
