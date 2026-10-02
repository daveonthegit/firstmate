#!/usr/bin/env bash
# fm-vault.sh - export finished work into the captain's Obsidian vault.
#
# Opt-in and home-private: the feature is on only when this home's gitignored
# config/obsidian-vault names an existing vault directory (first non-comment
# line; a leading ~ expands to $HOME; an empty value or "off" means off). With
# the file absent every subcommand except `template` exits 0 and prints nothing,
# so an unconfigured home pays nothing. The file is not inherited by secondmate
# homes; a secondmate home opts in with its own file.
#
# Usage:
#   fm-vault.sh journal <task-id> [--meta <file>|--meta -]
#   fm-vault.sh decision <origin-id> <decision-key> [--decision-file <path>]
#   fm-vault.sh index
#   fm-vault.sh template
#   fm-vault.sh path
#   fm-vault.sh --help
#
# journal writes or updates one note per finished ship or scout task at
#   Journal/Tasks/<YYYY>/<YYYY-MM-DD>-<task-id>.md, keyed by the frontmatter id,
#   from durable records: task metadata (--meta, default state/<id>.meta; "-"
#   reads it from stdin, which teardown uses because it removes the meta file),
#   the backlog item (tasks-axi show), the brief's # Task section, the report
#   path, the last done/failed status line, and the task-authored narrative
#   data/<id>/journal.md when present. A value missing from every source keeps
#   the existing note's value, so a later rerun without metadata never blanks a
#   PR link. Every resolved decision recorded in the metadata's decision_keys
#   gets a decision note too. It then runs `index`.
# decision writes Journal/Decisions/<YYYY-MM-DD>-<origin>-decision-<key>.md, a
#   dated record that links the origin task note, the origin report, and the
#   canonical backlog hold. The captain's decision text comes from
#   --decision-file or from the hold's recorded "Captain decision:" block; an
#   unresolved hold has neither and is skipped with exit 1. It then runs `index`.
# index regenerates, from the notes alone: per-project hubs
#   (Journal/Projects/<project>.md), per-month notes (Journal/Months/<YYYY-MM>.md),
#   per-skill notes (Journal/Skills/<skill>.md), Journal/Investigations.md (scout
#   reports indexed by path, never copied), and Journal/README.md (the Journal
#   area's contract).
# template prints the narrative capture template a worker fills in as
#   data/<id>/journal.md. It is the single owner of that template.
# path prints the resolved vault path when the feature is on; exit 1 when off.
#
# Write safety:
# - Writes go only under <vault>/Journal/. Path components are slug-validated,
#   every existing directory and note on the way is refused if it is a symlink,
#   and each note is written to a temp file in its own directory and renamed.
# - Generated text sits above a `<!-- fm-journal:generated ... -->` marker;
#   everything below it is the captain's and is preserved byte for byte. In
#   project hubs only the text between `<!-- fm-journal:begin generated -->`
#   and `<!-- fm-journal:end generated -->` is replaced. A task note whose
#   frontmatter says `review: captain-reviewed` is never rewritten.
# - An unchanged note is not rewritten, so reruns are idempotent.
# - frontmatter `narrative:` is captured, incomplete (template placeholders
#   remain), or missing.
# - Free text taken from records or narratives passes a redaction filter for
#   email addresses, phone numbers, token and key shapes, PEM blocks, JWTs, and
#   long opaque ids before it reaches the vault. Notes are written `review: draft`.
# - Mutating subcommands serialize on this home's state/.vault.lock.
# - Vault git is never touched unless config/obsidian-vault-git says `commit`
#   (stage and commit only Journal/ paths) or `push` (that commit, then a plain
#   `git push`). It never pulls, rebases, stashes, or forces.
#
# Fail-open contract: a vault problem prints exactly one `fm-vault: ...` line on
# stderr and exits 1. Callers on the task lifecycle path (bin/fm-teardown.sh)
# ignore that status, so a vault error never blocks or alters fleet operations.
# Exit codes: 0 done or feature off, 1 vault error or nothing to record, 2 usage.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE
# select the home; FM_VAULT_TODAY (YYYY-MM-DD) pins today's date for tests;
# FM_VAULT_LOCK_WAIT_SECS bounds the lock wait (default 20);
# FM_VAULT_GIT_TIMEOUT_SECS bounds each opt-in vault git step (default 60).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
VAULT_CONFIG="$CONFIG/obsidian-vault"
VAULT_GIT_CONFIG="$CONFIG/obsidian-vault-git"
TODAY=${FM_VAULT_TODAY:-$(date +%Y-%m-%d)}
LOCK_WAIT=${FM_VAULT_LOCK_WAIT_SECS:-20}
GIT_WAIT=${FM_VAULT_GIT_TIMEOUT_SECS:-60}
case "$GIT_WAIT" in ''|*[!0-9]*|0) GIT_WAIT=60 ;; esac

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

GEN_MARKER='<!-- fm-journal:generated - firstmate rewrites everything above this line on a rerun; the captain writes below it -->'
HUB_BEGIN='<!-- fm-journal:begin generated -->'
HUB_END='<!-- fm-journal:end generated -->'

VAULT=
WORK=
LOCK_DIR=
LOCK_HELD=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  if [ "$LOCK_HELD" = 1 ]; then
    fm_lock_release "$LOCK_DIR"
    LOCK_HELD=0
  fi
  [ -z "$WORK" ] || rm -rf "$WORK"
}
trap cleanup EXIT

# The one-line fail-open report.
fail() {
  printf 'fm-vault: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'fm-vault: usage error: %s (see fm-vault.sh --help)\n' "$*" >&2
  exit 2
}

# ---------------------------------------------------------------- config

# Prints the configured vault path, or nothing when the feature is off.
configured_vault_path() {
  local line
  [ -f "$VAULT_CONFIG" ] || return 0
  line=$(awk '!/^[[:space:]]*(#|$)/ { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$VAULT_CONFIG" 2>/dev/null) || return 0
  case "$line" in
    ''|off) return 0 ;;
    \~) line=$HOME ;;
    \~/*) line="$HOME/${line#\~/}" ;;
  esac
  printf '%s\n' "$line"
}

# Sets VAULT to the resolved vault directory. Returns 1 when the feature is off.
resolve_vault() {
  local configured
  configured=$(configured_vault_path)
  [ -n "$configured" ] || return 1
  case "$configured" in
    /*) ;;
    *) fail "config/obsidian-vault must name an absolute path (got '$configured')" ;;
  esac
  [ -d "$configured" ] || fail "configured vault $configured is not a directory"
  VAULT=$(cd -P "$configured" 2>/dev/null && pwd -P) || fail "cannot resolve vault $configured"
  [ -n "$VAULT" ] && [ "$VAULT" != / ] || fail "refusing vault root /"
  return 0
}

git_mode() {
  local line
  [ -f "$VAULT_GIT_CONFIG" ] || { printf 'off\n'; return 0; }
  line=$(awk '!/^[[:space:]]*(#|$)/ { gsub(/[[:space:]]/, ""); print; exit }' "$VAULT_GIT_CONFIG" 2>/dev/null)
  case "$line" in
    commit|push) printf '%s\n' "$line" ;;
    *) printf 'off\n' ;;
  esac
}

# ---------------------------------------------------------------- locking

acquire_lock() {
  local waited=0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" 2>/dev/null || fail "cannot load the lock helpers"
  LOCK_DIR="$STATE/.vault.lock"
  while ! fm_lock_try_acquire "$LOCK_DIR" 2>/dev/null; do
    [ "$waited" -lt "$((LOCK_WAIT * 10))" ] || fail "another vault export holds $LOCK_DIR; skipped"
    sleep 0.1
    waited=$((waited + 1))
  done
  LOCK_HELD=1
}

# ---------------------------------------------------------------- confinement

valid_slug() {
  case "$1" in
    ''|.*|-*|*..*|*/*) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$'
}

# Lowercase kebab slug for project and skill names; empty when nothing remains.
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9._-]+/-/g; s/^[.-]+//; s/-+$//; s/-+/-/g' | cut -c1-80
}

# Creates <vault>/<rel-dir> component by component, refusing symlinks.
ensure_dir() {
  local rel=$1 cur=$VAULT comp rest
  rest=$rel
  while [ -n "$rest" ]; do
    comp=${rest%%/*}
    if [ "$comp" = "$rest" ]; then rest=; else rest=${rest#*/}; fi
    valid_slug "$comp" || fail "refusing unsafe vault path component '$comp'"
    cur="$cur/$comp"
    [ -L "$cur" ] && fail "refusing symlinked vault directory ${cur#"$VAULT"/}"
    if [ ! -d "$cur" ]; then
      [ -e "$cur" ] && fail "vault path ${cur#"$VAULT"/} exists and is not a directory"
      mkdir "$cur" 2>/dev/null || fail "cannot create vault directory ${cur#"$VAULT"/}"
    fi
  done
}

# vault_write <rel-path> <source-file>: atomic, confined, skip-if-unchanged.
vault_write() {
  local rel=$1 src=$2 dir base target tmp
  case "$rel" in
    Journal/*.md) ;;
    *) fail "refusing a write outside Journal/: $rel" ;;
  esac
  dir=${rel%/*}
  base=${rel##*/}
  valid_slug "$base" || fail "refusing unsafe note name '$base'"
  ensure_dir "$dir"
  target="$VAULT/$rel"
  [ -L "$target" ] && fail "refusing symlinked note $rel"
  if [ -e "$target" ] && [ ! -f "$target" ]; then
    fail "vault path $rel exists and is not a regular file"
  fi
  if [ -f "$target" ] && cmp -s "$src" "$target"; then
    return 0
  fi
  tmp=$(mktemp "$VAULT/$dir/.fm-vault.XXXXXX" 2>/dev/null) || fail "cannot write in vault directory $dir"
  if ! cat "$src" > "$tmp" 2>/dev/null || ! chmod 644 "$tmp" 2>/dev/null \
     || ! mv -f "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp"
    fail "cannot write vault note $rel"
  fi
  WROTE=$((WROTE + 1))
}

# ---------------------------------------------------------------- text helpers

# Redacts sensitive shapes from free text on stdin.
redact() {
  awk '
    inkey { if ($0 ~ /-----END [A-Z ]*PRIVATE KEY-----/) inkey = 0; next }
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/ {
      pre = $0
      sub(/-----BEGIN [A-Z ]*PRIVATE KEY-----.*/, "", pre)
      print pre "[redacted-key]"
      if ($0 !~ /-----BEGIN [A-Z ]*PRIVATE KEY-----.*-----END [A-Z ]*PRIVATE KEY-----/) inkey = 1
      next
    }
    { print }
  ' | sed -E \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[redacted-email]/g' \
    -e 's/(sk-|sk_live_|sk_test_|rk_live_|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xox[abprs]-|AKIA|ASIA)[A-Za-z0-9_-]{8,}/[redacted-secret]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/[redacted-token]/g' \
    -e 's/[A-Fa-f0-9]{24,}/[redacted-id]/g' \
    -e 's/[A-Za-z0-9]{32,}/[redacted-id]/g' \
    -e 's/\+?[0-9]{0,2}[ .-]?\(?[0-9]{3}\)?[ .-]?[0-9]{3}[ .-][0-9]{4}([^0-9]|$)/[redacted-phone]\1/g' \
    -e 's/\+[0-9]{10,15}/[redacted-phone]/g'
}

# YAML double-quoted scalar.
yq() {
  printf '"%s"' "$(printf '%s' "$1" | tr '\n\r\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# Text safe as a wikilink alias.
link_alias() {
  printf '%s' "$1" | tr '\n' ' ' | sed -e 's#|#/#g' -e 's#\[#(#g' -e 's#\]#)#g'
}

# Reads a frontmatter scalar from a note: fm_value <file> <key>.
fm_value() {
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    index($0, key ": ") == 1 {
      v = substr($0, length(key) + 3)
      if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v) }
      print v
      exit
    }
  ' "$1" 2>/dev/null
}

# Normalizes a "[a, b]" or "a, b" list into comma-separated slugs.
normalize_list() {
  local raw=$1 item out='' slug
  raw=${raw#[}
  raw=${raw%]}
  while [ -n "$raw" ]; do
    item=${raw%%,*}
    if [ "$item" = "$raw" ]; then raw=; else raw=${raw#*,}; fi
    item=$(printf '%s' "$item" | sed -E 's/^[[:space:]"'"'"']+//; s/[[:space:]"'"'"']+$//')
    slug=$(slugify "$item")
    [ -n "$slug" ] || continue
    case ",$out," in *",$slug,"*) continue ;; esac
    out="${out}${out:+,}$slug"
  done
  printf '%s' "$out"
}

# Prints a file's body after an optional leading frontmatter block, with HTML
# comments and a leading H1 removed and outer blank lines trimmed.
narrative_body() {
  awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm { if ($0 == "---") infm = 0; next }
    { print }
  ' "$1" | awk '
    {
      line = $0
      out = ""
      while (length(line) > 0) {
        if (incomment) {
          p = index(line, "-->")
          if (p == 0) { line = ""; break }
          line = substr(line, p + 3); incomment = 0
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, p - 1); line = substr(line, p + 4); incomment = 1
        }
      }
      if (incomment && out == "") next
      print out
    }
  ' | awk '
    !seen && /^[[:space:]]*$/ { next }
    !seen && /^# / { seen = 1; next }
    { seen = 1; print }
  ' | trim_blank
}

trim_blank() {
  awk '
    { lines[NR] = $0 }
    END {
      s = 1; e = NR
      while (s <= e && lines[s] ~ /^[[:space:]]*$/) s++
      while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print lines[i]
    }
  '
}

# Prefixes every line of stdin for an Obsidian callout body.
callout_lines() {
  sed -e 's/^/> /' -e 's/^> $/>/'
}

# ---------------------------------------------------------------- records

meta_value() {
  [ -n "${META_FILE:-}" ] && [ -f "$META_FILE" ] || return 0
  sed -n "s/^$1=//p" "$META_FILE" | tail -1
}

SHOW=
load_show() {
  SHOW=
  command -v tasks-axi >/dev/null 2>&1 || return 0
  SHOW=$(cd "$FM_HOME" 2>/dev/null && tasks-axi show "$1" --full 2>/dev/null) || SHOW=
}

# show_field <field>: decoded value from the last tasks-axi show, "-" as empty.
show_field() {
  local v
  v=$(printf '%s\n' "$SHOW" | sed -n "s/^  $1: //p" | head -1)
  case "$v" in
    '"-"'|-) return 0 ;;
  esac
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
    *) printf '%s\n' "$v"; return 0 ;;
  esac
  printf '%s' "$v" | awk '
    {
      s = $0; out = ""; i = 1; n = length(s)
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) {
          d = substr(s, i + 1, 1)
          if (d == "n") out = out "\n"
          else if (d == "t") out = out "\t"
          else out = out d
          i += 2
          continue
        }
        out = out c
        i++
      }
      print out
    }
  '
}

# Finds an existing note by frontmatter id under a Journal subtree.
find_note() {
  local subdir=$1 id=$2 f
  [ -d "$VAULT/Journal/$subdir" ] || return 0
  while IFS= read -r f; do
    if [ "$(fm_value "$f" id)" = "$id" ]; then
      printf '%s\n' "${f#"$VAULT"/}"
      return 0
    fi
  done < <(find "$VAULT/Journal/$subdir" -type f -name "*-$id.md" 2>/dev/null | sort)
}

# Prints the captain-owned tail of an existing generated note (marker onward).
preserved_tail() {
  local file=$1
  if [ -f "$file" ] && grep -q '^<!-- fm-journal:generated' "$file"; then
    awk 'found { print; next } index($0, "<!-- fm-journal:generated") == 1 { found = 1; print }' "$file" \
      | awk -v marker="$GEN_MARKER" 'NR == 1 { print marker; next } { print }'
  else
    printf '%s\n## Captain notes\n' "$GEN_MARKER"
  fi
}

project_name() {  # <backlog repo> <meta project path> <fallback>
  local p
  p=${1##*/}
  [ -n "$p" ] || p=${2##*/}
  p=$(slugify "$p")
  [ -n "$p" ] || p=$3
  [ -n "$p" ] || p=unknown
  printf '%s\n' "$p"
}

# ---------------------------------------------------------------- decision

# write_decision <origin> <key> [decision-file]. Returns 1 (silently) when no
# captain decision is recorded yet; DECISION_SKIP_REASON says why.
DECISION_SKIP_REASON=
# shellcheck disable=SC2016 # Backticks are literal Markdown code spans.
write_decision() {
  local origin=$1 key=$2 dfile=${3:-} id text title decided project repo reason routed mode
  local existing rel origin_note origin_title report canonical status superseded out
  id="$origin-decision-$key"
  DECISION_SKIP_REASON=
  load_show "$id"
  text=
  if [ -n "$dfile" ]; then
    [ -f "$dfile" ] || fail "decision file $dfile does not exist"
    text=$(head -c 65536 "$dfile")
  elif [ -n "$SHOW" ]; then
    text=$(show_field body | awk '
      /^Captain decision:[[:space:]]*$/ { on = 1; next }
      on && /^Routed work:/ { exit }
      on { print }
    ' | sed -e 's/^  //' | trim_blank)
  fi
  if [ -z "$text" ]; then
    DECISION_SKIP_REASON="no recorded captain decision for $id yet"
    return 1
  fi
  title=$(show_field title)
  [ -n "$title" ] || title="Decision $key for $origin"
  title=$(printf '%s' "$title" | redact)
  existing=$(find_note Decisions "$id")
  decided=$(printf '%s\n' "$text" | sed -n -E 's/^[[:space:]]*Date:[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p' | head -1)
  [ -n "$decided" ] || decided=$(show_field closed)
  if [ -z "$decided" ] && [ -n "$existing" ]; then decided=$(fm_value "$VAULT/$existing" decided); fi
  [ -n "$decided" ] || decided=$TODAY
  printf '%s' "$decided" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || decided=$TODAY
  origin_note=$(find_note Tasks "$origin")
  repo=$(show_field repo)
  project=
  [ -z "$existing" ] || project=$(fm_value "$VAULT/$existing" project)
  [ -n "$project" ] || [ -z "$origin_note" ] || project=$(fm_value "$VAULT/$origin_note" project)
  project=$(project_name "$repo" "" "$project")
  reason=$(show_field hold_reason | redact)
  routed=$(show_field body | sed -n 's/^Routed identities: //p' | head -1)
  mode=$(show_field body | sed -n 's/^Resolution mode: //p' | head -1)
  report=none
  [ -f "$DATA/$origin/report.md" ] && report="$DATA/$origin/report.md"
  if [ -n "$SHOW" ]; then
    canonical="firstmate backlog hold $id"
  else
    canonical="decision file $dfile"
  fi
  status=active
  superseded=
  if [ -n "$existing" ]; then
    status=$(fm_value "$VAULT/$existing" status)
    [ -n "$status" ] || status=active
    superseded=$(fm_value "$VAULT/$existing" superseded_by)
  fi
  if [ -n "$existing" ]; then
    rel=$existing
  else
    rel="Journal/Decisions/$decided-$id.md"
  fi
  out="$WORK/decision.md"
  {
    printf -- '---\n'
    printf 'type: decision\n'
    printf 'id: %s\n' "$id"
    printf 'title: %s\n' "$(yq "$title")"
    printf 'origin: %s\n' "$origin"
    printf 'key: %s\n' "$key"
    printf 'project: %s\n' "$project"
    printf 'hub: %s\n' "$(yq "[[Journal/Projects/$project]]")"
    printf 'decided: %s\n' "$decided"
    printf 'decided_by: captain\n'
    printf 'status: %s\n' "$(slugify "$status")"
    [ -z "$superseded" ] || printf 'superseded_by: %s\n' "$(yq "$superseded")"
    printf 'canonical: %s\n' "$(yq "$canonical")"
    printf 'report: %s\n' "$(yq "$report")"
    printf 'tags: [decision, project/%s]\n' "$project"
    printf 'review: draft\n'
    printf -- '---\n\n'
    printf '# %s\n\n' "$title"
    printf -- '- **Decided:** %s by the captain.\n' "$decided"
    if [ -n "$origin_note" ]; then
      origin_title=$(fm_value "$VAULT/$origin_note" title)
      printf -- '- **Origin task:** [[%s|%s]]\n' "${origin_note%.md}" "$(link_alias "${origin_title:-$origin}")"
    else
      printf -- '- **Origin task:** `%s`\n' "$origin"
    fi
    [ "$report" = none ] || printf -- '- **Origin report:** `%s` (owned by firstmate, indexed not copied)\n' "$report"
    [ -z "$reason" ] || printf -- '- **Recommendation at the time:** %s\n' "$reason"
    [ -z "$routed" ] || printf -- '- **Routed to:** %s\n' "$routed"
    [ -z "$mode" ] || printf -- '- **Resolution path:** %s\n' "$mode"
    printf -- '- **Project:** [[Journal/Projects/%s|%s]]\n' "$project" "$project"
    printf -- '- **Canonical source:** %s. The rule and its consequences live there or in the repo that embodies it; this note is the dated record.\n\n' "$canonical"
    printf '> [!quote]- Captain decision as recorded\n'
    printf '%s\n' "$text" | redact | callout_lines
    printf '\n'
    preserved_tail "$VAULT/$rel"
  } > "$out"
  vault_write "$rel" "$out"
  NOTE_REL=$rel
}

# ---------------------------------------------------------------- journal

EXISTING_NOTE=
NOTE_REL=

# The existing task note's frontmatter value, for fields no live source has.
old_value() {
  [ -n "$EXISTING_NOTE" ] || return 0
  fm_value "$VAULT/$EXISTING_NOTE" "$1"
}

# A generated section of the existing task note, for sections no live source
# has: old_section status prints the Final status text; old_section <callout
# heading> prints that callout's quoted lines.
old_section() {
  [ -n "$EXISTING_NOTE" ] || return 0
  awk -v want="$1" '
    index($0, "<!-- fm-journal:generated") == 1 { exit }
    $0 == "## Records" { rec = 1; got = 0; on = 0; out = ""; next }
    !rec || got { next }
    on { if ($0 ~ /^>/) { out = out $0 "\n"; next } on = 0; got = 1; next }
    want == "status" && index($0, "- **Final status:** ") == 1 { out = substr($0, 21) "\n"; got = 1; next }
    want != "status" && $0 == want { on = 1 }
    END { printf "%s", out }
  ' "$VAULT/$EXISTING_NOTE" 2>/dev/null
}

# A frontmatter value from the narrative file, empty while it is a placeholder.
narrative_value() {
  local v
  v=$(fm_value "$1" "$2")
  case "$v" in '<'*|'[<'*) v= ;; esac
  printf '%s' "$v"
}

# shellcheck disable=SC2016 # Backticks are literal Markdown code spans.
write_journal() {
  local id=$1 existing rel title kind mode closed started project repo_path pr pr_head report
  local repo body ask outcome narrative jfile employer client skills metrics worker harness model
  local month tags s keys key dnote decisions year narrative_state old_ask old_body
  load_show "$id"
  existing=$(find_note Tasks "$id")
  EXISTING_NOTE=$existing
  if [ -n "$existing" ] && [ "$(fm_value "$VAULT/$existing" review)" = captain-reviewed ]; then
    NOTE_REL=$existing
    return 0
  fi

  jfile="$DATA/$id/journal.md"
  title=
  [ -f "$jfile" ] && title=$(narrative_value "$jfile" title)
  [ -n "$title" ] || title=$(show_field title | sed -E 's#https?://[^[:space:]]+##g; s/[[:space:]]+$//')
  [ -n "$title" ] || title=$(old_value title)
  [ -n "$title" ] || title=$id
  title=$(printf '%s' "$title" | redact)

  kind=$(meta_value kind); [ -n "$kind" ] || kind=$(show_field kind); [ -n "$kind" ] || kind=$(old_value kind); [ -n "$kind" ] || kind=ship
  kind=$(slugify "$kind")
  mode=$(meta_value mode); [ -n "$mode" ] || mode=$(old_value mode)
  closed=$(show_field closed); [ -n "$closed" ] || closed=$(old_value closed); [ -n "$closed" ] || closed=$TODAY
  printf '%s' "$closed" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || closed=$TODAY
  started=$(show_field created); [ -n "$started" ] || started=$(old_value started)
  repo=$(show_field repo)
  repo_path=$(meta_value project); [ -n "$repo_path" ] || repo_path=$(old_value repo_path)
  project=$(project_name "$repo" "$repo_path" "$(old_value project)")
  pr=$(meta_value pr)
  [ -n "$pr" ] || pr=$(show_field links | awk -F '[ ,]+' '{ for (i = 1; i <= NF; i++) if (sub(/^pr:/, "", $i)) { print $i; exit } }')
  [ -n "$pr" ] || pr=$(old_value pr); [ -n "$pr" ] || pr=none
  pr_head=$(meta_value pr_head); [ -n "$pr_head" ] || pr_head=$(old_value pr_head)
  report=none
  [ -f "$DATA/$id/report.md" ] && report="$DATA/$id/report.md"
  [ "$report" != none ] || report=$(old_value report)
  [ -n "$report" ] || report=none
  harness=$(meta_value harness); model=$(meta_value model)
  worker=$(printf '%s %s' "$harness" "$model" | sed -E 's/^ +//; s/ +$//')
  [ -n "$worker" ] || worker=$(old_value worker)

  employer=; client=; skills=; metrics=
  if [ -f "$jfile" ]; then
    employer=$(slugify "$(narrative_value "$jfile" employer)")
    client=$(narrative_value "$jfile" client | redact)
    skills=$(normalize_list "$(narrative_value "$jfile" skills)")
    metrics=$(slugify "$(narrative_value "$jfile" metrics)")
  fi
  [ -n "$employer" ] || employer=$(old_value employer)
  case "$client" in none|None|'') client=$(old_value client) ;; esac
  [ -n "$skills" ] || skills=$(normalize_list "$(old_value skills)")
  case "$metrics" in evidenced|none-recorded) ;; *) metrics=$(old_value metrics) ;; esac
  [ -n "$metrics" ] || metrics=none-recorded
  year=${closed%%-*}
  month=${closed%-*}
  body=$(show_field body)

  # Decisions this task produced, written first so the task note can link them.
  decisions=
  keys=$(meta_value decision_keys | tr ',' ' ')
  for key in $keys; do
    valid_slug "$key" || continue
    write_decision "$id" "$key" || true
  done
  if [ -d "$VAULT/Journal/Decisions" ]; then
    while IFS= read -r dnote; do
      [ "$(fm_value "$dnote" origin)" = "$id" ] || continue
      s=${dnote#"$VAULT"/}
      decisions="${decisions}- [[${s%.md}|$(link_alias "$(fm_value "$dnote" title)")]]
"
    done < <(find "$VAULT/Journal/Decisions" -type f -name '*.md' 2>/dev/null | sort)
  fi

  if [ -n "$existing" ]; then rel=$existing; else rel="Journal/Tasks/$year/$closed-$id.md"; fi

  ask=
  if [ -f "$DATA/$id/brief.md" ]; then
    ask=$(awk '/^# Task[[:space:]]*$/ { on = 1; next } on && /^# / { exit } on { print }' "$DATA/$id/brief.md" | trim_blank)
    [ "$ask" != '{TASK}' ] || ask=
  fi
  outcome=
  if [ -f "$STATE/$id.status" ]; then
    outcome=$(grep -E '^(done|failed)( \[key=[^]]*\])?:' "$STATE/$id.status" 2>/dev/null | tail -1)
  fi
  [ -n "$outcome" ] || outcome=$(old_section status)
  old_ask=; old_body=
  [ -n "$ask" ] || old_ask=$(old_section '> [!quote]- The ask, as briefed')
  [ -n "$body" ] || old_body=$(old_section '> [!info]- Backlog note')
  narrative=
  narrative_state=missing
  if [ -f "$jfile" ]; then
    narrative=$(narrative_body "$jfile")
    if [ -n "$narrative" ]; then
      narrative_state=captured
      # Template placeholders still present mean the worker left gaps.
      print_template | grep -o '<[^>]*>' | sort -u > "$WORK/placeholders"
      if printf '%s\n' "$narrative" | grep -Fqf "$WORK/placeholders"; then
        narrative_state=incomplete
      fi
    fi
  fi

  tags="task, project/$project"
  [ -z "$employer" ] || tags="$tags, employer/$employer"
  for s in $(printf '%s' "$skills" | tr ',' ' '); do tags="$tags, skill/$s"; done

  {
    printf -- '---\n'
    printf 'type: task\n'
    printf 'id: %s\n' "$id"
    printf 'title: %s\n' "$(yq "$title")"
    printf 'project: %s\n' "$project"
    printf 'hub: %s\n' "$(yq "[[Journal/Projects/$project]]")"
    printf 'kind: %s\n' "$kind"
    [ -z "$mode" ] || printf 'mode: %s\n' "$(slugify "$mode")"
    [ -z "$started" ] || printf 'started: %s\n' "$started"
    printf 'closed: %s\n' "$closed"
    printf 'month: %s\n' "$(yq "[[Journal/Months/$month]]")"
    printf 'pr: %s\n' "$(yq "$pr")"
    [ -z "$pr_head" ] || printf 'pr_head: %s\n' "$(yq "$pr_head")"
    printf 'report: %s\n' "$(yq "$report")"
    [ -z "$repo_path" ] || printf 'repo_path: %s\n' "$(yq "$repo_path")"
    [ -z "$employer" ] || printf 'employer: %s\n' "$employer"
    [ -z "$client" ] || printf 'client: %s\n' "$(yq "$client")"
    printf 'skills: [%s]\n' "$(printf '%s' "$skills" | sed 's/,/, /g')"
    printf 'tags: [%s]\n' "$tags"
    [ -z "$worker" ] || printf 'worker: %s\n' "$(yq "$worker")"
    printf 'attribution: captain-directed, ai-implemented\n'
    printf 'metrics: %s\n' "$metrics"
    printf 'narrative: %s\n' "$narrative_state"
    printf 'review: draft\n'
    printf -- '---\n\n'
    printf '# %s\n\n' "$title"
    if [ -n "$narrative" ]; then
      printf '%s\n' "$narrative" | redact
    else
      printf '> [!note] No task narrative was captured.\n'
      printf '> The worker did not leave `data/%s/journal.md`; the records below are all firstmate holds. Fill the STAR sections from `fm-vault.sh template` when this work matters for a resume.\n' "$id"
    fi
    printf '\n## Records\n'
    printf -- '- **Project:** [[Journal/Projects/%s|%s]]\n' "$project" "$project"
    printf -- '- **Kind:** %s' "$kind"
    [ -z "$mode" ] || printf ' (%s)' "$mode"
    printf '\n'
    printf -- '- **Closed:** %s' "$closed"
    [ -z "$started" ] || printf ' (started %s)' "$started"
    printf '\n'
    [ "$pr" = none ] || printf -- '- **PR:** %s\n' "$pr"
    [ "$report" = none ] || printf -- '- **Report:** `%s` (owned by firstmate, indexed not copied)\n' "$report"
    [ -z "$outcome" ] || printf -- '- **Final status:** %s\n' "$(printf '%s' "$outcome" | redact)"
    [ -z "$worker" ] || printf -- '- **AI worker:** %s, briefed and supervised by firstmate\n' "$worker"
    if [ -n "$decisions" ]; then
      printf -- '- **Decisions:**\n'
      printf '%s' "$decisions" | sed 's/^/  /'
    fi
    if [ -n "$ask" ]; then
      printf '\n> [!quote]- The ask, as briefed\n'
      printf '%s\n' "$ask" | redact | callout_lines
    elif [ -n "$old_ask" ]; then
      printf '\n> [!quote]- The ask, as briefed\n%s\n' "$old_ask"
    fi
    if [ -n "$body" ]; then
      printf '\n> [!info]- Backlog note\n'
      printf '%s\n' "$body" | redact | callout_lines
    elif [ -n "$old_body" ]; then
      printf '\n> [!info]- Backlog note\n%s\n' "$old_body"
    fi
    printf '\n'
    preserved_tail "$VAULT/$rel"
  } > "$WORK/task.md"
  vault_write "$rel" "$WORK/task.md"
  # A decision written before its origin note existed links the note now.
  for key in $keys; do
    valid_slug "$key" || continue
    write_decision "$id" "$key" || true
  done
  NOTE_REL=$rel
}

# ---------------------------------------------------------------- index

# One TSV row per note: date kind id project title rel skills report status origin
collect_rows() {
  local f
  : > "$WORK/rows.tsv"
  while IFS= read -r f; do
    [ -L "$f" ] && continue
    awk -v rel="${f#"$VAULT"/}" '
      function unq(v) {
        if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v) }
        gsub(/\t/, " ", v)
        return v
      }
      NR == 1 { if ($0 != "---") exit; next }
      $0 == "---" { done = 1; exit }
      {
        p = index($0, ": ")
        if (p == 0) next
        k = substr($0, 1, p - 1); v = unq(substr($0, p + 2))
        f[k] = v
      }
      END {
        if (!done || f["id"] == "") exit
        if (f["type"] == "decision") { date = f["decided"]; kind = "decision" }
        else { date = f["closed"]; kind = f["kind"] }
        sk = f["skills"]; gsub(/\[/, "", sk); gsub(/\]/, "", sk); gsub(/ /, "", sk)
        t = f["title"]; gsub(/\|/, "/", t); gsub(/\[/, "(", t); gsub(/\]/, ")", t)
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", date, kind, f["id"], f["project"], t, rel, sk, f["report"], f["status"], f["origin"], f["repo_path"]
      }
    ' "$f" >> "$WORK/rows.tsv"
  done < <(find "$VAULT/Journal/Tasks" "$VAULT/Journal/Decisions" -type f -name '*.md' 2>/dev/null | sort)
  sort -r "$WORK/rows.tsv" -o "$WORK/rows.tsv"
}

# write_generated <rel> <body-file>: body above the marker, captain tail kept.
write_generated() {
  local rel=$1 body=$2
  { cat "$body"; printf '\n'; preserved_tail "$VAULT/$rel"; } > "$WORK/gen.md"
  vault_write "$rel" "$WORK/gen.md"
}

write_hub() {  # <project>
  local project=$1 rel target repo_path adr f t
  rel="Journal/Projects/$project.md"
  target="$VAULT/$rel"
  repo_path=$(awk -F '\t' -v p="$project" '$4 == p && $11 != "" { print $11; exit }' "$WORK/rows.tsv")
  {
    printf '%s\n' "$HUB_BEGIN"
    printf '## Repo knowledge (canonical in the repo, linked here)\n'
    if [ -n "$repo_path" ] && [ -d "$repo_path" ]; then
      [ -f "$repo_path/AGENTS.md" ] && printf -- '- [AGENTS.md](<file://%s/AGENTS.md>)\n' "$repo_path"
      [ -d "$repo_path/docs" ] && printf -- '- [docs/](<file://%s/docs>)\n' "$repo_path"
      for adr in "$repo_path/docs/adr" "$repo_path/docs/decisions"; do
        [ -d "$adr" ] || continue
        while IFS= read -r f; do
          t=$(awk '/^# / { sub(/^# /, ""); print; exit }' "$f")
          printf -- '- [%s](<file://%s>)\n' "$(link_alias "${t:-${f##*/}}")" "$f"
        done < <(find "$adr" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
      done
    else
      printf -- '- No local clone recorded yet.\n'
    fi
    printf '\n## Decisions (newest first)\n'
    awk -F '\t' -v p="$project" '$4 == p && $2 == "decision" { printf "- %s [[%s|%s]] (%s)\n", $1, substr($6, 1, length($6) - 3), $5, ($9 == "" ? "active" : $9) }' "$WORK/rows.tsv"
    printf '\n## Work log (newest first)\n'
    awk -F '\t' -v p="$project" '$4 == p && $2 != "decision" { s = ($7 == "" ? "" : " - skills: " $7); gsub(/,/, ", ", s); printf "- %s [[%s|%s]] - %s%s\n", $1, substr($6, 1, length($6) - 3), $5, $2, s }' "$WORK/rows.tsv"
    printf '%s\n' "$HUB_END"
  } > "$WORK/block.md"
  if [ -f "$target" ] && grep -Fxq "$HUB_BEGIN" "$target" && grep -Fxq "$HUB_END" "$target"; then
    awk -v b="$HUB_BEGIN" -v e="$HUB_END" -v blk="$WORK/block.md" '
      $0 == b { while ((getline l < blk) > 0) print l; skip = 1; next }
      $0 == e && skip { skip = 0; next }
      !skip { print }
    ' "$target" > "$WORK/hub.md"
  elif [ -f "$target" ]; then
    { cat "$target"; printf '\n'; cat "$WORK/block.md"; } > "$WORK/hub.md"
  else
    {
      printf -- '---\ntype: project\nproject: %s\ntags: [project, project/%s]\n---\n\n# %s\n\n' "$project" "$project" "$project"
      printf 'Captain-written description goes here; firstmate only replaces the generated block below.\n\n'
      cat "$WORK/block.md"
    } > "$WORK/hub.md"
  fi
  vault_write "$rel" "$WORK/hub.md"
}

write_month() {  # <YYYY-MM>
  local m=$1
  {
    printf -- '---\ntype: month\nmonth: %s\ntags: [month]\n---\n\n# %s\n' "$m" "$m"
    printf '\n## Shipped\n'
    awk -F '\t' -v m="$m" 'substr($1, 1, 7) == m && $2 != "decision" && $2 != "scout" { printf "- %s [[%s|%s]] - %s\n", $1, substr($6, 1, length($6) - 3), $5, $4 }' "$WORK/rows.tsv"
    printf '\n## Investigations\n'
    awk -F '\t' -v m="$m" 'substr($1, 1, 7) == m && $2 == "scout" { printf "- %s [[%s|%s]] - %s\n", $1, substr($6, 1, length($6) - 3), $5, $4 }' "$WORK/rows.tsv"
    printf '\n## Decisions\n'
    awk -F '\t' -v m="$m" 'substr($1, 1, 7) == m && $2 == "decision" { printf "- %s [[%s|%s]] - %s\n", $1, substr($6, 1, length($6) - 3), $5, $4 }' "$WORK/rows.tsv"
  } > "$WORK/month.md"
  write_generated "Journal/Months/$m.md" "$WORK/month.md"
}

# shellcheck disable=SC2016 # Backticks are literal Markdown code spans.
write_skill() {  # <skill>
  local skill=$1
  {
    printf -- '---\ntype: skill\nskill: %s\ntags: [skill, skill/%s]\n---\n\n# %s\n\n' "$skill" "$skill" "$skill"
    printf 'Every journaled task that used this skill, newest first. Only `review: captain-reviewed` notes feed a resume.\n\n'
    awk -F '\t' -v s="$skill" '$2 != "decision" && index("," $7 ",", "," s ",") { printf "- %s [[%s|%s]] - %s\n", $1, substr($6, 1, length($6) - 3), $5, $4 }' "$WORK/rows.tsv"
  } > "$WORK/skill.md"
  write_generated "Journal/Skills/$skill.md" "$WORK/skill.md"
}

# shellcheck disable=SC2016 # Backticks are literal Markdown code spans.
write_investigations() {
  {
    printf -- '---\ntype: index\ntags: [index]\n---\n\n# Investigations\n\n'
    printf 'Scout reports stay in firstmate under `data/<task>/report.md`; this index points at them and never copies them.\n\n'
    awk -F '\t' 'END { if (!n) print "- None yet." } $2 == "scout" { n++; r = ($8 == "" || $8 == "none") ? "no report recorded" : "`" $8 "`"; printf "- %s [[%s|%s]] - %s - %s\n", $1, substr($6, 1, length($6) - 3), $5, $4, r }' "$WORK/rows.tsv"
  } > "$WORK/inv.md"
  write_generated "Journal/Investigations.md" "$WORK/inv.md"
}

# shellcheck disable=SC2016 # Backticks are literal Markdown code spans.
write_readme() {
  {
    printf -- '---\ntype: index\ntags: [index]\n---\n\n# Journal\n\n'
    printf 'Firstmate writes this folder and nothing else in the vault.\n'
    printf 'It is the long-term work journal, career evidence, and dated decision record; firstmate memory stays in its own `data/`.\n\n'
    printf -- '- `Tasks/<year>/` - one note per finished ship or scout task, with a STAR-ready narrative when the worker captured one.\n'
    printf -- '- `Decisions/` - dated captain decisions linking their origin task, report, and canonical source; the canonical source wins on any disagreement.\n'
    printf -- '- `Projects/` - one hub per project linking its repo knowledge, decisions, and work log.\n'
    printf -- '- `Months/`, `Skills/`, `Investigations.md` - generated indexes.\n\n'
    printf 'Generated text sits above the `fm-journal:generated` marker (or between the begin and end markers in hubs); write below it and firstmate keeps it.\n'
    printf 'Notes start as `review: draft`; set `review: captain-reviewed` after reading one, and firstmate stops rewriting it.\n'
    printf 'Only captain-reviewed notes, and only metrics from `metrics: evidenced` notes, should feed a resume.\n'
  } > "$WORK/readme.md"
  write_generated "Journal/README.md" "$WORK/readme.md"
}

run_index() {
  local p m s
  collect_rows
  cut -f4 "$WORK/rows.tsv" | sort -u > "$WORK/projects"
  while IFS= read -r p; do
    valid_slug "$p" || continue
    write_hub "$p"
  done < "$WORK/projects"
  cut -f1 "$WORK/rows.tsv" | cut -c1-7 | sort -u > "$WORK/months"
  while IFS= read -r m; do
    printf '%s' "$m" | grep -Eq '^[0-9]{4}-[0-9]{2}$' || continue
    write_month "$m"
  done < "$WORK/months"
  awk -F '\t' '$2 != "decision" { print $7 }' "$WORK/rows.tsv" | tr ',' '\n' | sort -u > "$WORK/skills"
  while IFS= read -r s; do
    valid_slug "$s" || continue
    write_skill "$s"
  done < "$WORK/skills"
  write_investigations
  write_readme
}

# ---------------------------------------------------------------- git opt-in

# Vault git never prompts, never signs, reads no stdin, and is time-bounded,
# so missing credentials or a pinentry cannot hang teardown under the lock.
vault_git() {
  local ssh_cmd=${GIT_SSH_COMMAND:-}
  [ -n "$ssh_cmd" ] || ssh_cmd=$(git -C "$VAULT" config --get core.sshCommand </dev/null 2>/dev/null)
  [ -n "$ssh_cmd" ] || ssh_cmd=ssh
  fm_run_timed "$GIT_WAIT" env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true SSH_ASKPASS=true \
    GIT_SSH_COMMAND="$ssh_cmd -o BatchMode=yes" \
    git -c commit.gpgsign=false -c core.askPass=true -C "$VAULT" "$@" </dev/null
}

git_sync() {  # <message>
  local mode
  mode=$(git_mode)
  [ "$mode" != off ] || return 0
  vault_git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "config/obsidian-vault-git is set but $VAULT is not a git repository; notes written, not committed"
  vault_git add -A -- Journal >/dev/null 2>&1 || fail "notes written; git add of Journal/ failed"
  if ! vault_git diff --cached --quiet -- Journal >/dev/null 2>&1; then
    vault_git commit -q -m "$1" --only -- Journal >/dev/null 2>&1 \
      || fail "notes written; vault commit failed or timed out (a hook or git identity may have refused it)"
  fi
  if [ "$mode" = push ]; then
    vault_git push -q >/dev/null 2>&1 \
      || fail "notes committed locally; vault push failed or timed out and will be retried by the next export"
  fi
}

# ---------------------------------------------------------------- template

print_template() {
  cat <<'EOF'
---
title: <plain-language title of what changed>
employer: <employer tag: personal, or the employer's slug>
client: <generalised client, e.g. "a home-improvement brand", or none>
skills: [<resume keywords as lowercase-kebab, e.g. typescript, postgres, row-level-security>]
metrics: none-recorded
---
<!--
Work-journal capture for the captain's long-term archive. Firstmate copies this
file into the captain's vault after cleanup; a resume or interview answer may be
built from it, so it must be true and safe to keep.

Rules:
- Plain language a hiring manager understands; name technologies in context.
- Real metrics only. Every number must appear in the PR, the report, or a
  measurement you ran. Otherwise write "unknown" or "none recorded". Never
  estimate. Set metrics: evidenced only when every number here is backed.
- Honest attribution: the captain set the goal, made the decisions, reviewed,
  and merged; AI workers (you) implemented, tested, and validated. Say which.
- Confidentiality: no secrets, tokens, keys, credentials, or env values; no
  email addresses, phone numbers, or personal data; nothing derived from
  private mail; no revenue, payouts, margins, partner terms, or account ids.
  Generalise client and partner names by industry.
- Delete these comments and any section that truly does not apply.
-->

## STAR summary
- **Situation:** <one sentence: the business situation, in plain language>
- **Task:** <one sentence: what had to be true afterwards>
- **Action:** <one or two sentences: what was decided and built, naming the technology in use>
- **Result:** <one sentence: the outcome; a number only if it is evidenced>

## Problem and why it mattered
<What was broken or missing, and why the business or the captain cared.>

## Constraints
- <deadline, compliance rule, compatibility requirement, data limits>

## Approach and alternatives considered
- **Chosen:** <approach> because <reason>
- **Considered:** <alternative>, rejected because <reason>

## Technologies in context
- <technology> - <how it was used here and why>

## Hard parts: what went wrong and how it was diagnosed
- <symptom> -> <how it was diagnosed> -> <fix>

## Outcome
- <shipped behaviour, PR, or report conclusion>
- Metrics: <evidenced numbers with their source, or "none recorded">

## Lessons
- <one or two reusable lessons>

## Role: captain vs AI workers
- **Captain:** <set the requirement, chose between options, reviewed, merged>
- **AI workers:** <what the AI worker implemented, tested, and validated>
EOF
}

# ---------------------------------------------------------------- main

[ "$#" -gt 0 ] || { usage; exit 2; }
cmd=$1
shift
case "$cmd" in
  -h|--help|help) usage; exit 0 ;;
  template) print_template; exit 0 ;;
  path)
    resolve_vault || exit 1
    printf '%s\n' "$VAULT"
    exit 0
    ;;
  journal|decision|index) ;;
  *) usage_error "unknown subcommand '$cmd'" ;;
esac

META_FILE=
META_ARG=
DECISION_FILE=
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --meta) [ "$#" -ge 2 ] || usage_error "--meta needs a value"; META_ARG=$2; shift 2 ;;
    --decision-file) [ "$#" -ge 2 ] || usage_error "--decision-file needs a value"; DECISION_FILE=$2; shift 2 ;;
    --*) usage_error "unknown option $1" ;;
    *) POS+=("$1"); shift ;;
  esac
done

case "$cmd" in
  journal) [ "${#POS[@]}" -eq 1 ] || usage_error "journal takes one task id"
    valid_slug "${POS[0]}" || usage_error "invalid task id '${POS[0]}'" ;;
  decision) [ "${#POS[@]}" -eq 2 ] || usage_error "decision takes an origin id and a decision key"
    valid_slug "${POS[0]}" || usage_error "invalid origin id '${POS[0]}'"
    valid_slug "${POS[1]}" || usage_error "invalid decision key '${POS[1]}'" ;;
  index) [ "${#POS[@]}" -eq 0 ] || usage_error "index takes no arguments" ;;
esac

# Feature off: silent no-op. Stdin is left unread on purpose.
resolve_vault || exit 0

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-vault.XXXXXX") || fail "cannot create a temp directory"
WROTE=0

if [ "$cmd" = journal ]; then
  if [ "$META_ARG" = - ]; then
    META_FILE="$WORK/meta"
    cat > "$META_FILE"
  elif [ -n "$META_ARG" ]; then
    [ -f "$META_ARG" ] || fail "metadata file $META_ARG does not exist"
    META_FILE=$META_ARG
  elif [ -f "$STATE/${POS[0]}.meta" ]; then
    META_FILE="$STATE/${POS[0]}.meta"
  fi
fi

[ -d "$STATE" ] || mkdir -p "$STATE" 2>/dev/null || fail "cannot create $STATE for the vault lock"
acquire_lock
ensure_dir Journal

case "$cmd" in
  journal)
    write_journal "${POS[0]}"
    run_index
    git_sync "journal: ${POS[0]}"
    printf 'vault: journaled %s -> %s\n' "${POS[0]}" "$NOTE_REL"
    ;;
  decision)
    write_decision "${POS[0]}" "${POS[1]}" "$DECISION_FILE" || fail "$DECISION_SKIP_REASON"
    run_index
    git_sync "decision: ${POS[0]}-decision-${POS[1]}"
    printf 'vault: recorded decision -> %s\n' "$NOTE_REL"
    ;;
  index)
    run_index
    git_sync "journal: reindex"
    printf 'vault: index regenerated\n'
    ;;
esac
exit 0
