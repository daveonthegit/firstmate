#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
export FM_HOME="$ROOT/.l" HOME="$ROOT/.l/user" FM_GH_ACCOUNT=none TREEHOUSE_ROOT="$ROOT/.l/pool"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME='Rescue Lab' GIT_AUTHOR_EMAIL='lab@example.invalid' GIT_COMMITTER_NAME='Rescue Lab' GIT_COMMITTER_EMAIL='lab@example.invalid'
export TMUX_TMPDIR="$FM_HOME/t" TMUX="$(TMUX_TMPDIR="$FM_HOME/t" tmux -L fm-lab display-message -p -t primary '#{socket_path}'),0,0"
export GH_CONFIG_DIR="$FM_HOME/gh" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
P=$(< "$FM_HOME/project-path"); H=$(< "$FM_HOME/carried-head"); R="$HOME/fm-rescue/widget.git"
RESCUE="$ROOT/bin/fm-rescue.sh"
. "$ROOT/bin/fm-continuation-lib.sh"
ref_is() { test "$(git -C "$1" rev-parse "$2")" = "$3"; }
absent() { if git -C "$1" show-ref --verify --quiet "$2"; then echo "ERROR unexpected ref $2"; exit 1; fi; }
refused() { if "$@"; then echo 'ERROR unexpectedly allowed'; exit 1; fi; }
record() {
 local id=$1 copy=$2
 mkdir -p "$FM_HOME/data/$id"
 printf 'kind=ship\nproject=%s\nworktree=%s\nbranch=fm/%s\nmode=direct-PR\nbackend=tmux\nwindow=primary:fm-%s\ncontinued_from=%s\n' "$P" "$copy" "$id" "$id" "${id%-c2}" > "$FM_HOME/state/$id.meta"
 tmux -L fm-lab new-window -d -t primary -n "fm-$id" -c "$ROOT" 'sleep 600'
}
echo '=== Ensure refuses conflicting remote and non-bare destination ==='
printf 'project=%s\nworktree=%s\n' "$P" "$P" > "$FM_HOME/state/ensure.meta"
git -C "$P" remote set-url fm-rescue "$FM_HOME/conflict.git"
refused "$RESCUE" ensure ensure
test "$(git -C "$P" remote get-url fm-rescue)" = "$FM_HOME/conflict.git"
git -C "$P" remote remove fm-rescue
mv "$R" "$R.saved"; mkdir -p "$R"; printf keep > "$R/notes"
refused "$RESCUE" ensure ensure
test "$(< "$R/notes")" = keep
rm -rf "$R"; mv "$R.saved" "$R"
"$RESCUE" ensure ensure
git -C "$P" fetch -q fm-rescue
rm "$FM_HOME/state/ensure.meta"

echo '=== Unchanged continuation cleanup retains rescue ==='
fm_continuation_write "$FM_HOME/data" a-c2 a ship fm-rescue fm/a "$H"
C=$(cd "$P" && treehouse get --lease --no-fetch)
git -C "$C" checkout -qb fm/a-c2 "$H"
record a-c2 "$C"
refused "$RESCUE" prune a "$P"
"$ROOT/bin/fm-teardown.sh" a-c2
ref_is "$R" refs/heads/fm/a "$H"
ref_is "$P" refs/remotes/fm-rescue/fm/a "$H"
refused "$RESCUE" prune a "$P"
echo "Unchanged continuation cleaned; rescue $H retained."

echo '=== Feature push, mirrors, and wrong base do not prove landing ==='
mkdir -p "$FM_HOME/data/a"; printf 'base_branch=release/next\n' > "$FM_HOME/data/a/handoff-request"
git -C "$P" push -q origin "$H:refs/heads/feature-only"
git -C "$P" update-ref refs/remotes/no-mistakes/release/next "$H"
git -C "$P" update-ref refs/remotes/fm-rescue/release/next "$H"
refused "$RESCUE" prune a "$P"
ref_is "$R" refs/heads/fm/a "$H"
git -C "$P" push -q origin "$H:refs/heads/release/next"
"$RESCUE" prune a "$P"
absent "$R" refs/heads/fm/a; absent "$P" refs/remotes/fm-rescue/fm/a
"$RESCUE" prune a "$P"
echo 'Recorded remote base landing pruned both refs, idempotently.'

echo '=== Abandon guards active handoff, live task, and moved rescue tip ==='
C=$(cd "$P" && treehouse get --lease --no-fetch)
git -C "$C" checkout -qb fm/guard main
printf 'guard\n' >> "$C/widget.txt"; git -C "$C" commit -qam guard
G=$(git -C "$C" rev-parse HEAD)
git -C "$C" push -q fm-rescue fm/guard
fm_continuation_write "$FM_HOME/data" guard-c2 guard ship fm-rescue fm/guard "$G"
touch "$FM_HOME/state/guard-c2.meta"
refused "$RESCUE" prune guard "$P" --abandoned
rm "$FM_HOME/state/guard-c2.meta"
touch "$FM_HOME/data/guard-c2/handoff-request"
refused "$RESCUE" prune guard "$P" --abandoned
rm "$FM_HOME/data/guard-c2/handoff-request"
refused "$RESCUE" prune guard "$P"
printf 'moved\n' >> "$C/widget.txt"; git -C "$C" commit -qam moved
M=$(git -C "$C" rev-parse HEAD); git -C "$C" push -q fm-rescue fm/guard
refused "$RESCUE" prune guard "$P" --abandoned
ref_is "$R" refs/heads/fm/guard "$M"
ref_is "$P" refs/remotes/fm-rescue/fm/guard "$M"
git -C "$C" push -q --force fm-rescue "$G:refs/heads/fm/guard"
"$RESCUE" prune guard-c2 "$P" --abandoned
absent "$R" refs/heads/fm/guard; absent "$P" refs/remotes/fm-rescue/fm/guard
(cd "$P" && treehouse return "$C" --force)

echo '=== Other preservation remotes are untouched ==='
fm_continuation_write "$FM_HOME/data" other-c2 other ship origin feature-only "$H"
"$RESCUE" prune other "$P"
ref_is "$FM_HOME/origin.git" refs/heads/feature-only "$H"

echo '=== Actual local squash with real gh against synthetic localhost forge ==='
C=$(cd "$P" && treehouse get --lease --no-fetch)
git -C "$C" checkout -qb fm/s main
printf 'squash carried\n' >> "$C/widget.txt"; git -C "$C" commit -qam 'squash first half'
S=$(git -C "$C" rev-parse HEAD); git -C "$C" push -q fm-rescue fm/s
fm_continuation_write "$FM_HOME/data" s-c2 s ship fm-rescue fm/s "$S"
git -C "$C" checkout -qb fm/s-c2
printf 'squash continued\n' >> "$C/widget.txt"; git -C "$C" commit -qam 'squash second half'
Q=$(git -C "$C" rev-parse HEAD); git -C "$C" push -q origin fm/s-c2
record s-c2 "$C"
printf 'pr=7\n' >> "$FM_HOME/state/s-c2.meta"
git -C "$P" merge --squash fm/s-c2
git -C "$P" commit -qm 'squash merged continuation'
git -C "$P" push -q origin main
git -C "$P" push -q origin --delete fm/s-c2
if git -C "$P" merge-base --is-ancestor "$S" origin/main; then echo 'ERROR fixture retained ancestry'; exit 1; fi
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$FM_HOME/key.pem" -out "$FM_HOME/cert.pem" -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >/dev/null 2>&1
python3 "$FM_HOME/forge.py" "$FM_HOME" & API_PID=$!
trap 'kill "$API_PID" 2>/dev/null || true; wait "$API_PID" 2>/dev/null || true' EXIT
for i in {1..50}; do test ! -f "$FM_HOME/api-port" || break; sleep .1; done
PORT=$(< "$FM_HOME/api-port")
export SSL_CERT_FILE="$FM_HOME/cert.pem" GH_HOST="localhost:$PORT" GH_REPO="localhost:$PORT/example/repo" GH_ENTERPRISE_TOKEN=synthetic-lab-token
write_state() { printf '{"number":7,"state":"%s","headRefOid":"%s","url":"https://localhost/example/repo/pull/7"}\n' "$1" "$2" > "$FM_HOME/api-state.json"; }
write_state MERGED "$Q"
gh pr view 7 --json state,headRefOid,url
# Check fail-closed forge proofs after a synthetic completed-task state.
mv "$FM_HOME/state/s-c2.meta" "$FM_HOME/s-c2.saved"
printf 'pr=7\n' > "$FM_HOME/data/s-c2/rescue-pr"
write_state OPEN "$Q"
refused "$RESCUE" prune s "$P"
ref_is "$R" refs/heads/fm/s "$S"
write_state MERGED "$(git -C "$P" rev-parse main~1)"
refused "$RESCUE" prune s "$P"
ref_is "$R" refs/heads/fm/s "$S"
printf '{"unavailable":true}\n' > "$FM_HOME/api-state.json"
refused "$RESCUE" prune s "$P"
ref_is "$R" refs/heads/fm/s "$S"
mv "$FM_HOME/s-c2.saved" "$FM_HOME/state/s-c2.meta"
rm "$FM_HOME/data/s-c2/rescue-pr"
write_state MERGED "$Q"
"$ROOT/bin/fm-teardown.sh" s-c2
test "$(< "$FM_HOME/data/s-c2/rescue-pr")" = pr=7
test ! -e "$FM_HOME/state/s-c2.meta"
absent "$R" refs/heads/fm/s; absent "$P" refs/remotes/fm-rescue/fm/s
printf 'Squash commit %s excludes carried ancestry %s; merged PR head %s allowed cleanup and pruned rescue.\n' "$(git -C "$P" rev-parse main)" "$S" "$Q"
"$RESCUE" prune s "$P"
echo 'PRUNE-LIVE-PASS'
