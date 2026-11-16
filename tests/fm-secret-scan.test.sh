#!/usr/bin/env bash
# tests/fm-secret-scan.test.sh - behavior tests for bin/fm-secret-scan.sh, the
# credential-shape scan that gates every records sync:
#   - each credential shape is reported by file, line, and rule
#   - the matched value never appears in the output
#   - placeholders, secret-store references, and ordinary prose are not flagged
#   - an allowlist drops only findings whose matched text it matches
#   - symbolic links are not followed, and usage errors exit 2
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-secret-scan.sh"
TMP_ROOT=$(fm_test_tmproot fm-secret-scan-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

scan() {  # <dir> <args...>: runs the scan from <dir> so reported names are relative
  local dir=$1
  shift
  (cd "$dir" && bash "$SCAN" "$@" 2>&1)
}

# Assembled at run time so this file never holds a contiguous credential shape.
long=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij0123456789

test_hits_name_file_line_and_rule() {
  local d="$TMP_ROOT/hits" out status rule line=0 expected=''
  mkdir -p "$d"
  : > "$d/hits.md"
  while IFS='|' read -r rule text; do
    line=$((line + 1))
    printf '%s\n' "$text" >> "$d/hits.md"
    expected="${expected}secret-scan: hits.md:$line: $rule"$'\n'
  done <<EOF
private-key|-----BEGIN RSA PRIVATE ""KEY-----
private-key|-----BEGIN OPENSSH PRIVATE ""KEY-----
github-token|token ghp_${long:0:36}
github-token|github_pat_${long}${long:0:10}
openai-key|key sk-${long:0:40}
openai-key|sk-proj-${long:0:40}
stripe-key|sk_live_${long:10:20}
stripe-key|rk_test_${long:5:20}
webhook-secret|whsec_${long:0:30}
aws-access-key|id AKIA${long:0:16} here
slack-token|xoxb-1234567890-${long:0:12}
slack-token|https://hooks.slack.com/services/T0000/B0000/${long:0:24}
google-key|AIza${long:0:35}
google-key|GOCSPX-${long:0:28}
google-key|ya29.${long:0:30}
resend-key|re_${long:30:8}_${long:0:24}
jwt|eyJ${long:0:12}.eyJ${long:12:12}.${long:0:20}
vault-token|hvs.${long:0:30}
vault-token|hvb.${long:0:30}
url-password|postgres://admin:s3cret""pass@db.example.invalid/app
assignment|API_TOKEN="${long:20:24}"
assignment|"client_secret": "${long:20:24}"
assignment|db_password := ${long:15:22}
EOF
  sed -i.bak 's/""//' "$d/hits.md" && rm -f "$d/hits.md.bak"
  status=0
  out=$(scan "$d" hits.md) || status=$?
  expect_code 1 "$status" "scan of credential-shaped lines"
  assert_equals "${expected%$'\n'}" "$out" "the scan did not report exactly one finding per credential line"
  assert_not_contains "$out" "${long:0:12}" "the scan printed a matched value"
  pass "each credential shape is reported by file, line, and rule without its value"
}

test_misses() {
  local d="$TMP_ROOT/misses" out status
  mkdir -p "$d"
  cat > "$d/misses.md" <<'EOF'
# Notes
token=vercel/deploy-hook-2
api_key: openbao/kv/prod/stripe-api-key-2026
password: <your-password>
password = correcthorsebatterystaple
secret: ${SECRET_VALUE_FROM_ENVIRONMENT_1}
url https://user:${PASS}@example.invalid
url https://user:***@example.invalid
see http://localhost:3000/foo@bar and git@github.com:owner/repo.git
the sk-learn library and task-keys-handling-notes
commit 7281840c feat: integrate upstream supervision (#37)
-----BEGIN PUBLIC KEY-----
pk_live_publishable_keys_are_public_1234
EOF
  status=0
  out=$(scan "$d" misses.md) || status=$?
  expect_code 0 "$status" "scan of placeholders, references, and prose"
  assert_equals "" "$out" "the scan flagged a non-credential"
  pass "placeholders, secret-store references, and ordinary prose are not flagged"
}

test_allowlist() {
  local d="$TMP_ROOT/allow" out status
  mkdir -p "$d"
  printf 'deploy_token=Vercel/Project%s\nGH ghp_%s\n' "${long:0:12}" "${long:0:36}" > "$d/notes.md"
  cat > "$d/allow" <<'EOF'
# secret-store references in this home use a capitalized prefix
^deploy_token=Vercel/

EOF
  status=0
  out=$(scan "$d" --allowlist "$d/allow" --allowlist "$d/missing" notes.md) || status=$?
  expect_code 1 "$status" "scan with an allowlist entry and a real token"
  assert_equals "secret-scan: notes.md:2: github-token" "$out" "the allowlist did not drop exactly its own finding"
  # An allowlist entry is tested against the matched text only, so a line-wide
  # pattern cannot hide a credential that shares the line with an exempt word.
  printf 'harmless ghp_%s\n' "${long:0:36}" > "$d/same-line.md"
  printf '^harmless\n' > "$d/allow-line"
  status=0
  out=$(scan "$d" --allowlist "$d/allow-line" same-line.md) || status=$?
  expect_code 1 "$status" "scan where the allowlist matches only the line"
  assert_contains "$out" "same-line.md:1: github-token" "a line-wide allowlist pattern hid a token"
  pass "an allowlist drops only findings whose matched text it matches"
}

test_links_and_usage() {
  local d="$TMP_ROOT/links" out status
  mkdir -p "$d/outside" "$d/in"
  printf 'ghp_%s\n' "${long:0:36}" > "$d/outside/secret.md"
  ln -s ../outside/secret.md "$d/in/link.md"
  mkdir -p "$d/in/dir.md"
  status=0
  out=$(scan "$d/in" link.md dir.md absent.md) || status=$?
  expect_code 0 "$status" "scan of a link, a directory, and a missing path"
  assert_equals "" "$out" "the scan followed a link or reported a non-file"
  status=0
  scan "$d/in" >/dev/null || status=$?
  expect_code 2 "$status" "scan with no files"
  status=0
  scan "$d/in" --bogus x >/dev/null || status=$?
  expect_code 2 "$status" "scan with an unknown option"
  pass "symbolic links are not followed, and usage errors exit 2"
}

fm_test_run \
  test_hits_name_file_line_and_rule \
  test_misses \
  test_allowlist \
  test_links_and_usage
