#!/usr/bin/env bash
set -eu
export FM_HOME="$PWD/.live-handoff/home" TREEHOUSE_ROOT="$PWD/.live-handoff/pool" FM_GH_ACCOUNT=none
(cd "$FM_HOME" && tasks-axi add scout-live 'Inspect both source lines' --kind scout --repo widget --file data/backlog.md)
bin/fm-brief.sh scout-live widget --scout >/dev/null
python3 - "$FM_HOME/data/scout-live/brief.md" <<'PY'
import sys
p=sys.argv[1];s=open(p).read().replace('{TASK}', 'Inspect source.txt in two stages: original scout inspects line one, continuation inspects line two and produces a final report preserving both findings.').replace('{FIRSTMATE_SPEC}', 'Isolated lab. Do not access external network or credentials, or run pipelines/tests. If not a continuation, inspect only line one, write an interim report at your report path and append working status. Then poll your exact steering inbox every 2 seconds in a foreground Bash command, with a 180-second timeout, until a message appears; read it and follow it. Do not finish line two before handoff. A continuation must read handoff.md and the old interim report, inspect line two and finish the final report. There are no human-owned decisions; use the documented completion gate with --none. Use only your task data, status and project paths, not other homes.')
open(p,'w').write(s)
PY
RAW='claude -p --model sonnet --effort low --setting-sources "" --strict-mcp-config --allowedTools Bash,Read,Write,Edit --settings __CLAUDESETTINGS__ "$( __OPINPUT__ encode launch-brief < __BRIEF__ )"'
printf '%s' "$RAW" > .live-handoff/raw-command
bin/fm-spawn.sh scout-live "$FM_HOME/projects/widget" --scout --harness "$RAW"
