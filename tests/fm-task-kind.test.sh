#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-kind)
POLICY="$ROOT/bin/fm-task-kind-policy.py"

for kind in missing '' unknown SHIP ship scout secondmate; do
  meta="$TMP_ROOT/task.meta"
  : > "$meta"
  [ "$kind" = missing ] || printf 'kind=%s\n' "$kind" > "$meta"
  case "$kind" in scout|secondmate) expected=$kind ;; *) expected=ship ;; esac
  [ "$(bash "$ROOT/bin/fm-task-kind.sh" "$meta")" = "$expected" ] || fail "executable resolver: $kind"
  [ "$(fm_task_kind "$meta" scout)" = "$expected" ] || fail "resolver accepted a caller hint: $kind"
  [ "$(_fm_status_kind "$TMP_ROOT/task.status" secondmate)" = "$expected" ] || fail "status wrapper overrode record: $kind"
done
printf 'kind=scout\nkind=unknown\n' > "$meta"
[ "$(fm_task_kind "$meta")" = ship ] || fail 'latest field is not authoritative'
printf 'kind=unknown\nkind=secondmate' > "$meta"
[ "$(fm_task_kind "$meta")" = secondmate ] || fail 'unterminated final field was ignored'
[ "$(fm_task_kind "$TMP_ROOT/absent.meta")" = ship ] || fail 'absent record created an exemption'
pass 'all resolver interfaces classify from the actual task record'

policy_fixture() {
  local name=$1 suffix=$2 source=$3 expected=$4 rc=0 dir="$TMP_ROOT/policy"
  mkdir -p "$dir"
  rm -f "$dir"/*
  printf '%s\n' "$source" > "$dir/$name.$suffix"
  python3 "$POLICY" "$dir" > "$TMP_ROOT/policy.out" 2>&1 || rc=$?
  [ "$rc" = "$expected" ] || fail "architecture policy $name returned $rc instead of $expected: $(<"$TMP_ROOT/policy.out")"
}
policy_fixture getter sh 'kind=$(fm_meta_get "$META" kind)' 1
policy_fixture field sh 'role=$(field "$record" "kind")' 1
policy_fixture grep sh 'grep "^kind=" "$meta" | cut -d= -f2-' 1
policy_fixture sed sh 'sed -n "s/^kind=//p" "$record"' 1
policy_fixture awk sh 'awk '\''$1 == "kind" { print $2 }'\'' "$meta"' 1
policy_fixture aliases sh $'key=kind\nreader=fm_meta_get\nrole=$("$reader" "$META" "$key")' 1
policy_fixture wrapper sh $'fetch() { fm_meta_get "$@"; }\nrole=$(fetch "$META" kind)' 1
policy_fixture embedded sh $'python3 - <<PY\nrole = meta.get("kind", "")\nPY' 1
policy_fixture generated sh $'cat > worker.sh <<SH\nrole=$(meta_field "$task" kind)\nSH' 1
policy_fixture dictionary py $'alias = meta\nrole = alias["kind"]' 1
policy_fixture python_key_alias py $'field = "kind"\nrole = meta.get(field)' 1
policy_fixture continued sh $'role=$(fm_meta_get \\\n "$META" kind)' 1
policy_fixture python py 'role = meta.get("kind", "")' 1
policy_fixture javascript mjs 'const role = meta.kind;' 1
policy_fixture consumer sh 'role=$(fm_task_kind "$META")' 0
policy_fixture declaration sh 'local meta kind window' 0
policy_fixture protocol py 'role = event.get("kind", "")' 0
policy_fixture protocol_shell sh 'source_field "$source" kind' 0
policy_fixture transport sh 'grep -v -e "^kind=" "$meta" > "$tmp"' 0
policy_fixture writer sh 'printf "kind=scout\n" >> "$meta"' 0
policy_fixture owner sh 'role=$(grep "^kind=" "$meta")' 1
policy_fixture fm-task-kind sh 'role=$(grep "^kind=" "$meta")' 0
python3 "$POLICY" "$ROOT/bin" || fail 'production task-kind architecture policy failed'
pass 'architecture policy rejects direct and indirect bypasses, not consumers or protocol data'
