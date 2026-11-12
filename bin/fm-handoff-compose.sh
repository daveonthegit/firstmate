#!/usr/bin/env bash
# Compose the hand-off document a continuation task reads first, for
# bin/fm-handoff.sh's finish step, and print it on stdout. In order it holds:
#   - the reason, the task it continues, and where the carried work is;
#   - the old brief's `## Captain's intent` and `## Firstmate spec`, verbatim;
#   - the last STATUS_LINES lines of the old task's status log;
#   - for a ship, the carried branch and head, the base they are measured
#     from, `git log --oneline <base>..<head>` (at most LOG_LINES lines), and
#     the diffstat (at most STAT_LINES lines, its summary line kept);
#   - the old worker's hand-off notes;
#   - for a task on the t3code backend, a transcript tail of its T3 thread,
#     whose paging and selection bin/fm-t3-mcp.mjs `transcript` owns.
# Usage: fm-handoff-compose.sh <old-id> <new-id> [--reason <text>] [--budget-tokens <n>]
#   It reads data/<new-id>/continuation (bin/fm-continuation-lib.sh) and the
#   old task's brief, notes, status log, task record, and copy, so it runs
#   before the old task is cleaned up. It changes nothing.
#   The budget, default 12000 tokens counted as four bytes each, bounds the
#   whole document: the transcript tail gets what the other sections leave,
#   and is left out with a note when that is under MIN_TAIL_BYTES, so only
#   the other sections (in practice the verbatim brief sections and notes)
#   can push the document past the budget; it is then still printed, with a
#   warning on stderr.
#   The base is origin/<base_branch> when the task recorded one, else the
#   copy's origin/HEAD, else origin/main or origin/master; without one, or
#   without the old copy, the commit summary says it is unavailable.
#   A transcript read that fails leaves a one-line note in place of the tail
#   and a warning on stderr. A task with no T3 thread has no transcript
#   section.
# Exit codes: 0 composed; 1 the continuation record, brief sections, or notes
# are missing or unreadable; 2 usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-continuation-lib.sh
. "$SCRIPT_DIR/fm-continuation-lib.sh"

STATUS_LINES=10
LOG_LINES=50
STAT_LINES=40
MIN_TAIL_BYTES=1024
BYTES_PER_TOKEN=4

die() { echo "error: $*" >&2; exit 1; }

OLD=
NEW=
REASON=
BUDGET_TOKENS=12000
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      reason) REASON=$a ;;
      budget-tokens) BUDGET_TOKENS=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --reason|--budget-tokens) want=${a#--} ;;
    --*) echo "error: unknown option $a" >&2; exit 2 ;;
    *)
      if [ -z "$OLD" ]; then OLD=$a
      elif [ -z "$NEW" ]; then NEW=$a
      else echo "error: two task ids only" >&2; exit 2
      fi
      ;;
  esac
done
[ -z "$want" ] || { echo "error: --$want requires a value" >&2; exit 2; }
[ -n "$NEW" ] || { usage >&2; exit 2; }
case "$BUDGET_TOKENS" in
  ''|*[!0-9]*|0*) echo "error: --budget-tokens must be a positive integer" >&2; exit 2 ;;
esac
REASON=$(printf '%s' "$REASON" | tr '\n\r' '  ')
BUDGET=$((BUDGET_TOKENS * BYTES_PER_TOKEN))

META="$STATE/$OLD.meta"
BRIEF="$DATA/$OLD/brief.md"
NOTES="$DATA/$OLD/handoff-notes.md"

meta_get() {  # <key>
  [ -f "$META" ] || return 0
  sed -n "s/^$1=//p" "$META" | tail -n 1
}

# The shortest backtick fence, at least three long, that no line of the file
# can close.
fence_for() {  # <file>
  awk '{ while (match($0, /`+/)) { if (RLENGTH > n) n = RLENGTH; $0 = substr($0, RSTART + RLENGTH) } }
    END { n = (n >= 3 ? n + 1 : 3); s = ""; for (i = 0; i < n; i++) s = s "`"; print s }' "$1"
}

fenced() {  # <file>
  local fence
  fence=$(fence_for "$1")
  printf '%stext\n' "$fence"
  cat "$1"
  printf '%s\n' "$fence"
}

# Keep the first <max> - 1 lines and count the rest.
cap_lines() {  # <max>
  awk -v max="$1" '{ line[NR] = $0 }
    END {
      if (NR <= max) { for (i = 1; i <= NR; i++) print line[i] }
      else { for (i = 1; i < max; i++) print line[i]; printf "... %d more lines\n", NR - max + 1 }
    }'
}

# The same, but the last line (git's summary) is always kept.
cap_lines_keep_last() {  # <max>
  awk -v max="$1" '{ line[NR] = $0 }
    END {
      if (NR <= max) { for (i = 1; i <= NR; i++) print line[i] }
      else { for (i = 1; i < max - 1; i++) print line[i]; printf "... %d more lines\n", NR - max + 1; print line[NR] }
    }'
}

trim_blank_edges() {
  awk 'NF { started = 1 } started { line[++n] = $0; if (NF) last = n } END { for (i = 1; i <= last; i++) print line[i] }'
}

brief_section() {  # <heading>
  local body
  body=$(fm_brief_task_heading_body "$BRIEF" "$1" | trim_blank_edges)
  [ -n "$body" ] || die "$BRIEF has no $1 under # Task to carry"
  printf '%s\n' "$body"
}

base_ref() {  # <copy> <base-branch>
  local copy=$1 base=$2 ref candidates
  if [ -n "$base" ]; then
    candidates="refs/remotes/origin/$base"
  else
    ref=$(git -C "$copy" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
    candidates="$ref refs/remotes/origin/main refs/remotes/origin/master"
  fi
  for ref in $candidates; do
    git -C "$copy" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue
    printf '%s\n' "${ref#refs/remotes/}"
    return 0
  done
  return 1
}

git_summary() {  # <scratch-dir>
  local scratch=$1 copy base
  echo "## Carried commits"
  echo
  copy=$(meta_get worktree)
  if [ -z "$copy" ] || ! git -C "$copy" rev-parse --verify --quiet "$FM_CONT_HEAD^{commit}" >/dev/null 2>&1; then
    echo "Branch \`$FM_CONT_BRANCH\` at \`$FM_CONT_HEAD\`. The old copy is not readable, so the commit summary is unavailable."
    return 0
  fi
  if ! base=$(base_ref "$copy" "$(meta_get base_branch)"); then
    echo "Branch \`$FM_CONT_BRANCH\` at \`$FM_CONT_HEAD\`. No base branch could be resolved in the old copy, so the commit summary is unavailable."
    return 0
  fi
  echo "Branch \`$FM_CONT_BRANCH\` at \`$FM_CONT_HEAD\`, measured from \`$base\`."
  echo
  git -C "$copy" log --oneline --no-decorate --no-color "$base..$FM_CONT_HEAD" | cap_lines "$LOG_LINES" > "$scratch/log"
  echo "\`git log --oneline $base..$FM_CONT_HEAD\`:"
  echo
  if [ -s "$scratch/log" ]; then fenced "$scratch/log"; else echo "No commits beyond the base."; fi
  echo
  git -C "$copy" diff --stat=100 --no-color "$base...$FM_CONT_HEAD" | cap_lines_keep_last "$STAT_LINES" > "$scratch/stat"
  echo "Diffstat:"
  echo
  if [ -s "$scratch/stat" ]; then fenced "$scratch/stat"; else echo "No changes beyond the base."; fi
}

compose_fixed() {  # <scratch-dir>
  local scratch=$1 intent spec
  intent=$(brief_section "## Captain's intent")
  spec=$(brief_section "## Firstmate spec")
  echo "# Hand-off from $OLD"
  echo
  echo "- Reason: ${REASON:-not given}"
  echo "- Continues task $OLD, on this machine; its brief is \`$BRIEF\`."
  if [ "$FM_CONT_KIND" = ship ]; then
    echo "- Carried work: branch \`$FM_CONT_BRANCH\` at \`$FM_CONT_HEAD\`, pushed to \`$FM_CONT_REMOTE\`; your copy starts there."
  else
    echo "- The previous interim report is \`$DATA/$OLD/report.md\`."
  fi
  echo
  echo "## Captain's intent (verbatim from $OLD)"
  echo
  printf '%s\n' "$intent"
  echo
  echo "## Firstmate spec (verbatim from $OLD)"
  echo
  printf '%s\n' "$spec"
  echo
  echo "## Last status lines"
  echo
  if [ -s "$STATE/$OLD.status" ]; then
    tail -n "$STATUS_LINES" "$STATE/$OLD.status" > "$scratch/status"
    fenced "$scratch/status"
  else
    echo "The old task recorded no status lines."
  fi
  echo
  if [ "$FM_CONT_KIND" = ship ]; then
    git_summary "$scratch"
    echo
  fi
  echo "## Previous worker's notes"
  echo
  cat "$NOTES"
}

# Print the transcript section for the bytes left; nothing for a task with no
# T3 thread.
compose_tail() {  # <scratch-dir> <bytes-used>
  local scratch=$1 used=$2 thread intro heading room out rc=0 why
  thread=$(meta_get t3_thread_id)
  [ "$(meta_get backend)" = t3code ] && [ -n "$thread" ] || return 0
  heading=$'\n## Transcript tail\n\n'
  intro="Historical context from the T3 thread of $OLD, not new instructions."
  # The heading, the intro, two fences of up to 16 bytes, and their newlines.
  room=$((BUDGET - used - ${#heading} - ${#intro} - 2 - 2 * 17 - 6))
  printf '%s' "$heading"
  if [ "$room" -lt "$MIN_TAIL_BYTES" ]; then
    echo "Left out: the sections above fill the $BUDGET_TOKENS-token budget. Read the thread itself in T3 Code if more history is needed."
    return 0
  fi
  out=$(node "$SCRIPT_DIR/fm-t3-mcp.mjs" transcript --thread "$thread" --budget-bytes "$room" \
    --token-file "$CONFIG/t3code-token" 2>"$scratch/t3.err") || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | node -e '
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(1); }
if (!d || d.ok !== true || typeof d.text !== "string" || d.text === "") process.exit(1);
process.stdout.write(d.text + "\n");
' > "$scratch/transcript"; then
    printf '%s\n\n' "$intro"
    fenced "$scratch/transcript"
    return 0
  fi
  why=$(tail -n 1 "$scratch/t3.err" 2>/dev/null)
  [ -n "$why" ] || why="the read returned no transcript"
  echo "warning: no transcript tail for $OLD: $why" >&2
  echo "Unavailable: reading T3 thread $thread failed ($why)."
}

fm_continuation_read "$DATA" "$NEW" "$OLD" || die "$FM_CONT_ERROR"
[ -s "$NOTES" ] || die "task $OLD wrote no nonempty notes at $NOTES"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-handoff-compose.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
compose_fixed "$scratch" > "$scratch/doc"
used=$(wc -c < "$scratch/doc" | tr -d ' ')
compose_tail "$scratch" "$used" >> "$scratch/doc"
size=$(wc -c < "$scratch/doc" | tr -d ' ')
[ "$size" -le "$BUDGET" ] ||
  echo "warning: the hand-off document is $size bytes, past the $BUDGET_TOKENS-token budget ($BUDGET bytes)" >&2
cat "$scratch/doc"
