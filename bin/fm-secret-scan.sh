#!/usr/bin/env bash
# fm-secret-scan.sh - flag high-confidence credential shapes in text files
# before they leave this machine. bin/fm-supervisor-lease.sh `sync` runs it over
# exactly the records content it is about to commit and push.
#
# It is a pattern scan with no external dependency beyond grep. It looks only
# for shapes that are very unlikely to be anything but a credential:
#   private-key      a PEM/OpenSSH/PGP private-key block header
#   github-token     ghp_/gho_/ghu_/ghs_/ghr_ tokens and github_pat_ tokens
#   openai-key       sk-<32+ alnum> and sk-proj-/sk-svcacct-/sk-admin-/sk-ant- keys
#   stripe-key       sk_live_/sk_test_/rk_live_/rk_test_ keys
#   webhook-secret   whsec_ signing secrets (Stripe, Svix, Resend)
#   aws-access-key   AKIA/ASIA access key ids
#   slack-token      xoxa-/xoxb-/xoxp-/xoxo-/xoxs-/xoxr- tokens and hooks.slack.com URLs
#   google-key       AIza API keys, GOCSPX- client secrets, ya29. access tokens
#   resend-key       re_<id>_<secret> API keys
#   jwt              eyJ...eyJ...<signature> JSON web tokens
#   vault-token      hvs./hvb./hvr. Vault and OpenBao tokens
#   url-password     scheme://user:password@ URLs with an embedded literal password
#   assignment       a name containing key/secret/token/password/passwd/pwd
#                    (any case) assigned with = : := or => to a literal of 20 or
#                    more [A-Za-z0-9_+/=.-] characters that holds both a letter
#                    and a digit
# Placeholders are not literals: a value containing $, <, {, * or whitespace is
# never flagged by url-password or assignment. An assignment whose value is an
# all-lowercase slash path such as `token=vercel/deploy-hook-2` is a
# secret-store reference, not a secret, and is built-in exempt.
#
# ALLOWLIST. --allowlist <file> (repeatable; a missing file is ignored) names
# known false positives: one extended regular expression per line, blank lines
# and lines starting with # ignored. A finding is dropped when the text it
# matched matches any allowlist expression. The expressions are tested only
# against the matched text, never the whole line, so an allowlisted reference
# cannot hide a real secret elsewhere on the same line.
#
# Usage:
#   fm-secret-scan.sh [--allowlist <file>]... [--] <file>...
#       Scans each regular file. Symbolic links, directories, and missing paths
#       are skipped: the scan never follows a link out of the content it was
#       given.
#
# Output: one line per finding, `secret-scan: <file>:<line>: <rule>`. The
# matched value is never printed, so the report is safe to show and log.
#
# Exit status: 0 nothing found; 1 one or more findings; 2 usage error or an
# unreadable file (treat as "not proven clean").
set -u

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
}

export LC_ALL=C

# rule|grep flags|extended regular expression. The leading (^|[^...]) groups
# anchor a token at a word boundary; the boundary character is stripped from
# the match before the allowlist and value checks.
RULES='private-key||-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----
github-token||(^|[^A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36,}
github-token||(^|[^A-Za-z0-9_])github_pat_[A-Za-z0-9_]{50,}
openai-key||(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9]{32,}
openai-key||(^|[^A-Za-z0-9_-])sk-(proj|svcacct|admin|ant)-[A-Za-z0-9_-]{32,}
stripe-key||(^|[^A-Za-z0-9_])[sr]k_(live|test)_[A-Za-z0-9]{16,}
webhook-secret||(^|[^A-Za-z0-9_])whsec_[A-Za-z0-9+/=]{20,}
aws-access-key||(^|[^A-Za-z0-9])(AKIA|ASIA)[A-Z0-9]{16}([^A-Za-z0-9]|$)
slack-token||(^|[^A-Za-z0-9_-])xox[abposr]-[A-Za-z0-9-]{10,}
slack-token||https://hooks\.slack\.com/(services|workflows|triggers)/[A-Za-z0-9/_-]{20,}
google-key||(^|[^A-Za-z0-9_-])AIza[A-Za-z0-9_-]{35}
google-key||(^|[^A-Za-z0-9_-])GOCSPX-[A-Za-z0-9_-]{20,}
google-key||(^|[^A-Za-z0-9_-])ya29\.[A-Za-z0-9_-]{20,}
resend-key||(^|[^A-Za-z0-9_])re_[A-Za-z0-9]{6,}_[A-Za-z0-9]{16,}
jwt||eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}
vault-token||(^|[^A-Za-z0-9_])hv[sbr]\.[A-Za-z0-9_-]{24,}
url-password||[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@$*<>{}]{3,}@
assignment|-i|(^|[^A-Za-z0-9_])[A-Za-z0-9_.-]*(key|secret|token|passwd|password|pwd)[A-Za-z0-9_-]*["'\'']?[[:space:]]*(:=|=>|=|:)[[:space:]]*["'\'']?[A-Za-z0-9_+/=.-]{20,}'

ALLOW_FILES=()
FILES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allowlist)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ALLOW_FILES+=("$2")
      shift 2
      ;;
    --) shift; FILES+=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done
[ "${#FILES[@]}" -gt 0 ] || { usage >&2; exit 2; }

ALLOW=()
for f in "${ALLOW_FILES[@]+"${ALLOW_FILES[@]}"}"; do
  [ -f "$f" ] || continue
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    ALLOW+=("$line")
  done < "$f"
done

allowed() {  # <matched text>
  local re
  for re in "${ALLOW[@]+"${ALLOW[@]}"}"; do
    printf '%s\n' "$1" | grep -qE -- "$re" 2>/dev/null && return 0
  done
  return 1
}

# A match passes the value checks the rule needs: true means "report it".
credential_shaped() {  # <rule> <matched text>
  local rule=$1 m=$2 v
  case "$rule" in
    assignment)
      # The name holds no : or =, so the first one is the assignment operator.
      local re='^[^:=]*(:=|=>|=|:)[[:space:]]*["'"'"']?([A-Za-z0-9_+/=.-]+)$'
      [[ "$m" =~ $re ]] || return 1
      v=${BASH_REMATCH[2]}
      [[ "$v" =~ [0-9] ]] && [[ "$v" =~ [A-Za-z] ]] || return 1
      # A lowercase slash path names a secret-store entry, not a secret.
      [[ "$v" =~ ^[a-z0-9._-]+(/[a-z0-9._-]+)+$ ]] && return 1
      return 0
      ;;
  esac
  return 0
}

status=0
for file in "${FILES[@]}"; do
  [ ! -L "$file" ] || continue
  [ -e "$file" ] || continue
  [ ! -d "$file" ] || continue
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'secret-scan: %s: unreadable\n' "$file" >&2
    status=2
    continue
  fi
  seen=$'\n'
  while IFS='|' read -r rule flags regex; do
    [ -n "$rule" ] || continue
    # shellcheck disable=SC2086 # flags is empty or one literal option.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      lineno=${hit%%:*}
      m=${hit#*:}
      # Drop a boundary character the leading group consumed.
      [[ "$m" =~ ^[^A-Za-z0-9_-] ]] && m=${m:1}
      [ "$rule" != aws-access-key ] || m=${m%[^A-Za-z0-9]}
      credential_shaped "$rule" "$m" || continue
      allowed "$m" && continue
      case "$seen" in *$'\n'"$lineno:$rule"$'\n'*) continue ;; esac
      seen="$seen$lineno:$rule"$'\n'
      printf 'secret-scan: %s:%s: %s\n' "$file" "$lineno" "$rule"
      [ "$status" -eq 2 ] || status=1
    done < <(grep -anoE $flags -- "$regex" "$file" 2>/dev/null)
  done <<EOF
$RULES
EOF
done
exit "$status"
