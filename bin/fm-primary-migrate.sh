#!/usr/bin/env bash
# fm-primary-migrate.sh - guarded primary Firstmate home migration between
# machines (preflight, export, and import).
#
# Usage:
#   fm-primary-migrate.sh preflight
#   fm-primary-migrate.sh export <bundle-dir>
#   fm-primary-migrate.sh import <bundle-dir> [--clone-projects]
#
# Moves a primary Firstmate home (private data/, portable config/, local-only
# project clones, and remote secondmate / worker-host registries) from one
# machine to another without losing unlanded work, and refuses rather than
# guessing.
#
# Subcommands:
#   preflight   Read-only safety check on the source primary. Refuses (exit 1)
#               when any blocker holds:
#                 - a live session holds state/.lock;
#                 - an away/quiet record (state/.afk-contract or state/.afk) is
#                   active;
#                 - any local ship, local scout, worker-host-placed task, or
#                   local secondmate still has a record in state/*.meta (remote
#                   secondmates stay running on their own host and are allowed);
#                 - any pending state/*.backlog-close, data/handoff/*.outbox.md,
#                   or unresolved state/pending-replies/ record remains;
#                 - any private rescue repo under state/rescue/ still holds refs;
#                 - any clone under projects/ is non-git, dirty, has extra
#                   worktrees attached, or (for remote-backed projects) has local
#                   commits not pushed to origin;
#                 - a records git repo under data/ has uncommitted edits,
#                   unpushed commits, or (for export) still holds the supervisor
#                   lease on this host.
#   export      Runs the full preflight gate plus the supervisor-lease release
#               check, then writes a self-contained bundle to a NEW directory
#               <bundle-dir>:
#                 - manifest.json (schema fm-primary-migrate.v1)
#                 - data/ (private durable records)
#                 - config/ (portable config only; excludes machine-bound files
#                   and credentials such as t3code-token, machine-id, rescue-ssh,
#                   cmux-socket-password, and .env)
#                 - local-projects/<name>.bundle (git bundle --all for every
#                   local-only or origin-less project so zero commits are lost)
#                 - remote-projects.tsv (credential-free origins for remote
#                   projects to re-clone on the new host)
#               Never copies state/.lock, state/.lock-session, local PIDs,
#               local backend targets, or .env secrets.
#   import      Validates <bundle-dir>/manifest.json and checksums, refuses if
#               the destination FM_HOME is already populated, locked, marked as
#               a worker-host or secondmate home, or shares the source's
#               machine-id, then restores data/, portable config/, and bundled
#               local-only projects. With --clone-projects, also clones remote
#               projects from their validated credential-free origins and runs
#               `no-mistakes init` on no-mistakes projects. Prints the exact
#               remaining human/operator checklist (secure .env transfer,
#               machine-local config, sign-ins, verifying remote secondmates
#               and worker hosts, and starting bin/fm-session-start.sh).
#
# Exit status: 0 on pass/success, 1 on refusal or blocker, 2 on usage.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
SCHEMA=fm-primary-migrate.v1

# shellcheck source=bin/fm-task-route-lib.sh
. "$SCRIPT_DIR/fm-task-route-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-worker-host-lib.sh
. "$SCRIPT_DIR/fm-worker-host-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,/^set -eu$/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }

command -v jq >/dev/null 2>&1 || die "fm-primary-migrate.sh requires jq"

# Config entries bound to a specific machine or holding host-bound credentials;
# never copied automatically across machines.
is_machine_bound_config() { # <basename>
  case "$1" in
    t3code-token|machine-id|rescue-ssh|cmux-socket-password|lane-capacity|project-capacity|obsidian-vault|record-export-root|claude-account|pi-account|claude-accounts)
      return 0 ;;
    *) return 1 ;;
  esac
}

current_machine_id() {
  local id=
  if [ -f "$CONFIG/machine-id" ]; then
    id=$(head -n 1 "$CONFIG/machine-id" 2>/dev/null | tr -d '[:space:]')
  fi
  if [ -z "$id" ] && command -v scutil >/dev/null 2>&1; then
    id=$(scutil --get LocalHostName 2>/dev/null || true)
  fi
  [ -n "$id" ] || id=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
  printf '%s\n' "$id"
}

sha256_of() { # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

BLOCKERS=()
WARNINGS=()
REMOTE_SECONDMATES=()
LOCAL_BUNDLE_PROJECTS=()
REMOTE_CLONE_PROJECTS=()
REMOTE_CLONE_ORIGINS=()
REMOTE_CLONE_MODES=()
PORTABLE_CONFIGS=()
SKIPPED_CONFIGS=()
LEASE_MODE=off
LEASE_HOLDER=
RECORDS_REMOTE_URL=
RECORDS_HEAD=

add_blocker() { BLOCKERS+=("$1"); }
add_warning() { WARNINGS+=("$1"); }

run_preflight() { # <mode: preflight|export>
  local check_mode=$1 lock_out meta id kind proj name dir mode_line pmode origin wt_count unpushed
  local lease_out data_dirty ahead f base rref_count

  BLOCKERS=()
  WARNINGS=()
  REMOTE_SECONDMATES=()
  LOCAL_BUNDLE_PROJECTS=()
  REMOTE_CLONE_PROJECTS=()
  REMOTE_CLONE_ORIGINS=()
  REMOTE_CLONE_MODES=()
  PORTABLE_CONFIGS=()
  SKIPPED_CONFIGS=()
  LEASE_MODE=off
  LEASE_HOLDER=
  RECORDS_REMOTE_URL=
  RECORDS_HEAD=

  # 0. Must be a primary home, not a worker host or secondmate home.
  [ ! -e "$FM_HOME/.fm-worker-host" ] || add_blocker "this home carries .fm-worker-host; only a primary home can be migrated"
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || add_blocker "this home carries .fm-secondmate-home; only a primary home can be migrated"

  # 1. Session lock must be free.
  if [ -d "$STATE" ]; then
    lock_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lock.sh" status 2>/dev/null || true)
    case "$lock_out" in
      *'lock: held by live harness'*)
        add_blocker "a live primary session holds state/.lock ($lock_out); stop it before migrating"
        ;;
      *'lock: unreadable'*)
        add_blocker "state/.lock is unreadable; resolve it before migrating"
        ;;
    esac
  fi

  # 2. Away/quiet posture must be off.
  if [ -e "$STATE/.afk-contract" ] || [ -e "$STATE/.afk" ]; then
    add_blocker "away or quiet supervision posture is active (state/.afk-contract or state/.afk); exit it before migrating"
  fi

  # 3. Task records in state/*.meta.
  if [ -d "$STATE" ]; then
    for meta in "$STATE"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      id=$(basename "$meta" .meta)
      if [ -L "$meta" ] || [ ! -f "$meta" ]; then
        add_blocker "unsafe task metadata record: $meta"
        continue
      fi
      kind=$(sed -n 's/^kind=//p' "$meta" | head -n 1)
      if ! fm_task_route "$meta"; then
        add_blocker "unreadable task route in $meta"
        continue
      fi
      if [ "$kind" = secondmate ] && [ "$FM_TASK_ROUTE" = remote-secondmate ]; then
        REMOTE_SECONDMATES+=("$id")
      elif [ "$kind" = secondmate ]; then
        add_blocker "local secondmate '$id' is recorded in state/; retire or drain it before moving the primary"
      elif [ "$FM_TASK_ROUTE" = worker-host ]; then
        add_blocker "task '$id' is placed on worker host '$FM_TASK_ROUTE_HOST'; finish and tear it down before moving the primary"
      else
        add_blocker "local ${kind:-ship} task '$id' is still in flight; land and tear it down (or hand it off) before migrating"
      fi
    done

    # 4. Pending backlog closes, pending replies, and rescue repositories.
    for f in "$STATE"/*.backlog-close; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      add_blocker "pending backlog close record remains: $(basename "$f"); run bootstrap reconciliation first"
    done
    if [ -d "$STATE/pending-replies" ]; then
      for f in "$STATE/pending-replies"/*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        add_blocker "unresolved secondmate pending reply remains: $(basename "$f")"
      done
    fi
    if [ -d "$STATE/rescue" ]; then
      for dir in "$STATE/rescue"/*.git; do
        [ -d "$dir" ] || continue
        rref_count=$(git --git-dir="$dir" for-each-ref --format='%(refname)' 2>/dev/null | wc -l | tr -d ' ')
        if [ "${rref_count:-0}" -gt 0 ]; then
          add_blocker "private rescue repository $(basename "$dir") still holds $rref_count ref(s); land or prune via bin/fm-rescue.sh first"
        fi
      done
    fi
  fi

  # 5. Pending secondmate backlog handoff outboxes.
  if [ -d "$DATA/handoff" ]; then
    for f in "$DATA/handoff"/*.outbox.md; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      add_blocker "pending backlog handoff outbox remains: data/handoff/$(basename "$f")"
    done
  fi

  # 6. Project clones under projects/.
  if [ -d "$PROJECTS" ]; then
    for proj in "$PROJECTS"/*; do
      [ -e "$proj" ] || [ -L "$proj" ] || continue
      name=$(basename "$proj")
      if [ -L "$proj" ] || [ ! -d "$proj" ] || ! git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
        add_blocker "projects/$name is not a plain git clone; inspect or move it aside before migrating"
        continue
      fi
      if [ -n "$(git -C "$proj" status --porcelain 2>/dev/null)" ]; then
        add_blocker "projects/$name has uncommitted or untracked changes; commit, push, or clean them before migrating"
        continue
      fi
      wt_count=$(git -C "$proj" worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)
      if [ "${wt_count:-0}" -gt 1 ]; then
        add_blocker "projects/$name still has $((wt_count - 1)) attached worktree(s); return or clean them before migrating"
        continue
      fi
      pmode=unknown
      if mode_line=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$name" 2>/dev/null); then
        pmode=${mode_line%% *}
      fi
      origin=$(git -C "$proj" remote get-url origin 2>/dev/null || true)
      if [ "$pmode" = local-only ] || [ -z "$origin" ]; then
        LOCAL_BUNDLE_PROJECTS+=("$name")
      else
        if ! fm_project_origin_credential_free "$origin"; then
          add_blocker "projects/$name has a credential-bearing origin URL; replace it with a credential-free URL"
          continue
        fi
        unpushed=$(git -C "$proj" log --branches --not --remotes --oneline 2>/dev/null | head -n 5 || true)
        if [ -n "$unpushed" ]; then
          add_blocker "projects/$name ($pmode) has unpushed local commits; push them or land them before migrating"
          continue
        fi
        REMOTE_CLONE_PROJECTS+=("$name")
        REMOTE_CLONE_ORIGINS+=("$origin")
        REMOTE_CLONE_MODES+=("$pmode")
      fi
    done
  fi

  # 7. Records repository & supervisor lease (data/).
  if [ -d "$DATA" ]; then
    lease_out=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-supervisor-lease.sh" status 2>/dev/null || true)
    if printf '%s\n' "$lease_out" | grep -q 'mode: misconfigured'; then
      add_blocker "records repository data/ is misconfigured; resolve 'bin/fm-supervisor-lease.sh status' before migrating"
    elif printf '%s\n' "$lease_out" | grep -q 'mode: active'; then
      LEASE_MODE=active
      LEASE_HOLDER=$(printf '%s\n' "$lease_out" | sed -n 's/.*local: host=\([^ ]*\).*/\1/p' | head -n 1)
      RECORDS_HEAD=$(git -C "$DATA" rev-parse HEAD 2>/dev/null || true)
      local remote_name
      remote_name=$(git -C "$DATA" remote 2>/dev/null | head -n 1 || true)
      [ -z "$remote_name" ] || RECORDS_REMOTE_URL=$(git -C "$DATA" remote get-url "$remote_name" 2>/dev/null || true)
      data_dirty=$(git -C "$DATA" status --porcelain 2>/dev/null || true)
      if [ -n "$data_dirty" ]; then
        add_blocker "records repository data/ has uncommitted changes; run 'bin/fm-supervisor-lease.sh sync' first"
      fi
      ahead=$(git -C "$DATA" log --branches --not --remotes --oneline 2>/dev/null | head -n 1 || true)
      if [ -n "$ahead" ]; then
        add_blocker "records repository data/ has unpushed commits; run 'bin/fm-supervisor-lease.sh sync' first"
      fi
      if [ -n "$LEASE_HOLDER" ] && [ "$LEASE_HOLDER" != none ]; then
        if [ "$check_mode" = export ]; then
          add_blocker "supervisor lease is still held by '$LEASE_HOLDER'; run 'bin/fm-supervisor-lease.sh release' before exporting"
        else
          add_warning "supervisor lease is currently held by '$LEASE_HOLDER'; run 'bin/fm-supervisor-lease.sh release' right before export"
        fi
      fi
    fi
  fi

  # 8. Classify config/ files (portable vs machine-bound).
  if [ -d "$CONFIG" ]; then
    for f in "$CONFIG"/*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      base=$(basename "$f")
      if [ -L "$f" ]; then
        add_warning "skipping symlinked config/$base (recreate manually if needed)"
        SKIPPED_CONFIGS+=("$base")
      elif is_machine_bound_config "$base"; then
        SKIPPED_CONFIGS+=("$base")
      elif [ -f "$f" ] || [ -d "$f" ]; then
        PORTABLE_CONFIGS+=("$base")
      fi
    done
  fi
  if [ -f "$FM_HOME/.env" ]; then
    add_warning ".env exists and is never copied into the migration bundle; transfer it securely by hand"
  fi
}

print_preflight_report() {
  local item
  printf 'migrate: machine=%s\n' "$(current_machine_id)"
  printf 'migrate: supervisor_lease_mode=%s%s\n' "$LEASE_MODE" "${LEASE_HOLDER:+ holder=$LEASE_HOLDER}"
  printf 'migrate: remote_secondmates=%s\n' "${REMOTE_SECONDMATES[*]:-none}"
  printf 'migrate: local_bundle_projects=%s\n' "${LOCAL_BUNDLE_PROJECTS[*]:-none}"
  printf 'migrate: remote_clone_projects=%s\n' "${REMOTE_CLONE_PROJECTS[*]:-none}"
  printf 'migrate: portable_configs=%s\n' "${PORTABLE_CONFIGS[*]:-none}"
  printf 'migrate: skipped_machine_configs=%s\n' "${SKIPPED_CONFIGS[*]:-none}"
  for item in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
    printf 'warning: %s\n' "$item"
  done
  for item in ${BLOCKERS[@]+"${BLOCKERS[@]}"}; do
    printf 'blocker: %s\n' "$item"
  done
}

cmd_preflight() {
  run_preflight preflight
  print_preflight_report
  if [ "${#BLOCKERS[@]}" -gt 0 ]; then
    printf 'error: preflight failed with %s blocker(s); resolve them before exporting\n' "${#BLOCKERS[@]}" >&2
    exit 1
  fi
  printf 'ok: preflight passed; safe to release lease (if active) and export\n'
  exit 0
}

cmd_export() {
  local dest=$1 stage i name origin pmode bpath bsha f json_local='[]' json_remote='[]' json_sm='[]' json_cfg='[]' json_skip='[]'
  local has_env=false code_head
  [ -n "$dest" ] || usage
  [ ! -e "$dest" ] && [ ! -L "$dest" ] || die "export destination already exists: $dest"
  run_preflight export
  print_preflight_report
  if [ "${#BLOCKERS[@]}" -gt 0 ]; then
    printf 'error: refusing export with %s blocker(s)\n' "${#BLOCKERS[@]}" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$dest")" || die "cannot create parent directory for $dest"
  stage=$(mktemp -d "$(dirname "$dest")/.fm-migrate-export.XXXXXX") || die "cannot stage export bundle"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$stage'" EXIT
  mkdir -p "$stage/data" "$stage/config" "$stage/local-projects"

  # Copy private data/ (excluding any data/handoff or nested git lock files).
  if [ -d "$DATA" ]; then
    (cd "$DATA" && tar -cf - --exclude='.git' .) | (cd "$stage/data" && tar -xf -)
  fi

  # Copy portable config/ items only.
  for f in ${PORTABLE_CONFIGS[@]+"${PORTABLE_CONFIGS[@]}"}; do
    cp -R "$CONFIG/$f" "$stage/config/$f"
    json_cfg=$(printf '%s' "$json_cfg" | jq -c --arg v "$f" '. + [$v]')
  done
  for f in ${SKIPPED_CONFIGS[@]+"${SKIPPED_CONFIGS[@]}"}; do
    json_skip=$(printf '%s' "$json_skip" | jq -c --arg v "$f" '. + [$v]')
  done

  # Bundle local-only / origin-less projects with all refs so zero commits are lost.
  for name in ${LOCAL_BUNDLE_PROJECTS[@]+"${LOCAL_BUNDLE_PROJECTS[@]}"}; do
    bpath="$stage/local-projects/$name.bundle"
    git -C "$PROJECTS/$name" bundle create "$bpath" --all >/dev/null 2>&1 \
      || die "failed to create git bundle for local project $name"
    bsha=$(sha256_of "$bpath")
    json_local=$(printf '%s' "$json_local" | jq -c --arg n "$name" --arg s "$bsha" '. + [{name: $n, sha256: $s}]')
  done

  # Record remote-backed projects (origins validated credential-free in preflight).
  : > "$stage/remote-projects.tsv"
  i=0
  while [ "$i" -lt "${#REMOTE_CLONE_PROJECTS[@]}" ]; do
    name=${REMOTE_CLONE_PROJECTS[$i]}
    origin=${REMOTE_CLONE_ORIGINS[$i]}
    pmode=${REMOTE_CLONE_MODES[$i]}
    i=$((i + 1))
    printf '%s\t%s\t%s\n' "$name" "$origin" "$pmode" >> "$stage/remote-projects.tsv"
    json_remote=$(printf '%s' "$json_remote" | jq -c --arg n "$name" --arg o "$origin" --arg m "$pmode" \
      '. + [{name: $n, origin: $o, mode: $m}]')
  done

  for name in ${REMOTE_SECONDMATES[@]+"${REMOTE_SECONDMATES[@]}"}; do
    json_sm=$(printf '%s' "$json_sm" | jq -c --arg n "$name" '. + [$n]')
  done
  [ ! -f "$FM_HOME/.env" ] || has_env=true
  code_head=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')

  jq -n \
    --arg schema "$SCHEMA" \
    --arg source_machine "$(current_machine_id)" \
    --arg exported_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg code_head "$code_head" \
    --arg lease_mode "$LEASE_MODE" \
    --arg records_remote "$RECORDS_REMOTE_URL" \
    --arg records_head "$RECORDS_HEAD" \
    --argjson has_env "$has_env" \
    --argjson portable_configs "$json_cfg" \
    --argjson skipped_configs "$json_skip" \
    --argjson local_projects "$json_local" \
    --argjson remote_projects "$json_remote" \
    --argjson remote_secondmates "$json_sm" \
    '{
      schema: $schema,
      source_machine: $source_machine,
      exported_at: $exported_at,
      code_head: $code_head,
      has_env: $has_env,
      records_repo: {
        mode: $lease_mode,
        remote_url: (if $records_remote == "" then null else $records_remote end),
        head: (if $records_head == "" then null else $records_head end)
      },
      portable_configs: $portable_configs,
      skipped_configs: $skipped_configs,
      local_projects: $local_projects,
      remote_projects: $remote_projects,
      remote_secondmates: $remote_secondmates
    }' > "$stage/manifest.json"

  chmod 0700 "$stage" 2>/dev/null || true
  mv -- "$stage" "$dest" || die "cannot publish export bundle at $dest"
  trap - EXIT
  printf 'ok: exported primary migration bundle to %s\n' "$dest"
  exit 0
}

cmd_import() {
  local src=$1 clone_projects=$2 manifest src_machine dst_machine f meta
  local n_local i name expected_sha actual_sha bpath origin pmode dest_proj has_env lease_mode records_remote
  [ -d "$src" ] && [ ! -L "$src" ] || die "migration bundle directory not found: $src"
  manifest="$src/manifest.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || die "migration bundle has no manifest.json: $src"
  [ "$(jq -r '.schema // empty' "$manifest" 2>/dev/null)" = "$SCHEMA" ] \
    || die "incompatible migration bundle schema in $manifest"

  # Destination safety checks: refuse rather than overwrite or collide.
  [ ! -e "$FM_HOME/.fm-worker-host" ] || die "destination $FM_HOME carries .fm-worker-host; import only into a primary home"
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || die "destination $FM_HOME carries .fm-secondmate-home; import only into a primary home"
  if [ -d "$STATE" ]; then
    case "$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lock.sh" status 2>/dev/null || true)" in
      *'lock: held by live harness'*) die "destination $FM_HOME has a live session holding state/.lock" ;;
    esac
    for meta in "$STATE"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      die "destination $FM_HOME already has task records under state/; refusing to overwrite an active home"
    done
  fi
  if [ -s "$DATA/backlog.md" ]; then
    die "destination $DATA/backlog.md already exists and is non-empty; refusing to overwrite an existing home"
  fi
  src_machine=$(jq -r '.source_machine // empty' "$manifest")
  dst_machine=$(current_machine_id)
  if [ -n "$src_machine" ] && [ "$src_machine" = "$dst_machine" ]; then
    die "destination machine id '$dst_machine' matches source machine '$src_machine'; write a distinct config/machine-id first"
  fi

  # Verify all local project bundles before mutating destination.
  n_local=$(jq -r '.local_projects | length' "$manifest")
  i=0
  while [ "$i" -lt "$n_local" ]; do
    name=$(jq -r ".local_projects[$i].name" "$manifest")
    expected_sha=$(jq -r ".local_projects[$i].sha256" "$manifest")
    i=$((i + 1))
    case "$name" in ''|.|..|*/*|*[[:cntrl:]]*) die "unsafe project name in manifest: $name" ;; esac
    bpath="$src/local-projects/$name.bundle"
    [ -f "$bpath" ] && [ ! -L "$bpath" ] || die "missing local project bundle: $bpath"
    actual_sha=$(sha256_of "$bpath")
    [ "$actual_sha" = "$expected_sha" ] || die "checksum mismatch for $bpath"
    [ ! -e "$PROJECTS/$name" ] && [ ! -L "$PROJECTS/$name" ] \
      || die "destination project already exists: $PROJECTS/$name"
  done

  mkdir -p "$DATA" "$STATE" "$CONFIG" "$PROJECTS"

  # Restore data/ unless destination data/ is already a cloned records git repository.
  lease_mode=$(jq -r '.records_repo.mode // "off"' "$manifest")
  records_remote=$(jq -r '.records_repo.remote_url // empty' "$manifest")
  if [ "$lease_mode" = active ] && [ -d "$DATA/.git" ]; then
    printf 'import: destination data/ is already a git records repository; keeping it intact\n'
  elif [ -d "$src/data" ]; then
    (cd "$src/data" && tar -cf - .) | (cd "$DATA" && tar -xf -)
    printf 'import: restored data/\n'
    if [ "$lease_mode" = active ] && [ -n "$records_remote" ]; then
      printf 'warning: source data/ used a git records remote (%s); clone that records repo into data/ before running session start if you want supervisor-lease sync\n' "$records_remote"
    fi
  fi

  # Restore portable config files without overwriting existing machine-local files.
  if [ -d "$src/config" ]; then
    for f in "$src/config"/*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      name=$(basename "$f")
      if is_machine_bound_config "$name"; then
        printf 'import: skipped machine-bound config/%s\n' "$name"
        continue
      fi
      if [ -e "$CONFIG/$name" ] || [ -L "$CONFIG/$name" ]; then
        printf 'import: kept existing destination config/%s\n' "$name"
        continue
      fi
      cp -R "$f" "$CONFIG/$name"
      printf 'import: restored config/%s\n' "$name"
    done
  fi

  # Restore local-only / origin-less projects from verified git bundles.
  i=0
  while [ "$i" -lt "$n_local" ]; do
    name=$(jq -r ".local_projects[$i].name" "$manifest")
    i=$((i + 1))
    bpath="$src/local-projects/$name.bundle"
    git clone --quiet "$bpath" "$PROJECTS/$name" || die "failed to restore local project $name from $bpath"
    git -C "$PROJECTS/$name" remote remove origin 2>/dev/null || true
    printf 'import: restored local project projects/%s from bundle\n' "$name"
  done

  # Remote-backed projects: clone when --clone-projects is passed, else list commands.
  local n_remote
  n_remote=$(jq -r '.remote_projects | length' "$manifest")
  i=0
  while [ "$i" -lt "$n_remote" ]; do
    name=$(jq -r ".remote_projects[$i].name" "$manifest")
    origin=$(jq -r ".remote_projects[$i].origin" "$manifest")
    pmode=$(jq -r ".remote_projects[$i].mode" "$manifest")
    i=$((i + 1))
    case "$name" in ''|.|..|*/*|*[[:cntrl:]]*) die "unsafe remote project name in manifest: $name" ;; esac
    fm_project_origin_credential_free "$origin" || die "manifest project $name has an unsafe origin URL"
    dest_proj="$PROJECTS/$name"
    if [ "$clone_projects" -eq 1 ]; then
      if [ -e "$dest_proj" ] || [ -L "$dest_proj" ]; then
        printf 'import: kept existing projects/%s\n' "$name"
      else
        git clone --no-local --quiet -- "$origin" "$dest_proj" || die "failed to clone $name from $origin"
        printf 'import: cloned projects/%s from %s\n' "$name" "$origin"
      fi
      if [ "$pmode" = no-mistakes ] && ! git -C "$dest_proj" remote get-url no-mistakes >/dev/null 2>&1; then
        if command -v no-mistakes >/dev/null 2>&1; then
          (cd "$dest_proj" && no-mistakes init >/dev/null 2>&1) \
            || printf 'warning: no-mistakes init failed in projects/%s; run it manually\n' "$name"
        else
          printf 'next: run no-mistakes init in %s\n' "$dest_proj"
        fi
      fi
    else
      printf 'next: clone %s: git clone %s %s%s\n' \
        "$name" "$origin" "$dest_proj" \
        "$([ "$pmode" != no-mistakes ] || printf ' && (cd %s && no-mistakes init)' "$dest_proj")"
    fi
  done

  # Post-import checklist.
  has_env=$(jq -r '.has_env // false' "$manifest")
  [ "$has_env" != true ] || printf 'next: transfer .env securely from %s to %s/.env\n' "$src_machine" "$FM_HOME"
  printf 'next: review machine-local config (config/machine-id, config/lane-capacity, config/rescue-ssh) and run bin/fm-host-bootstrap.sh\n'
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf 'next: verify SSH alias and re-attach remote secondmate %s: bin/fm-on.sh %s fm-remote-doctor.sh && bin/fm-spawn.sh %s --secondmate\n' \
      "$name" "$name" "$name"
  done < <(jq -r '.remote_secondmates[]?' "$manifest")
  if [ -f "$DATA/worker-hosts.md" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      printf 'next: verify worker host %s from this new primary: bin/fm-worker-host-doctor.sh %s\n' "$name" "$name"
    done < <(worker_host_ids "$DATA" 2>/dev/null || true)
  fi
  printf 'next: start the new primary session with bin/fm-session-start.sh to acquire the supervisor lease and session lock\n'
  printf 'ok: imported primary migration bundle from %s\n' "$src_machine"
  exit 0
}

[ "$#" -ge 1 ] || usage
case "$1" in
  -h|--help) usage ;;
  preflight)
    [ "$#" -eq 1 ] || usage
    cmd_preflight
    ;;
  export)
    [ "$#" -eq 2 ] || usage
    cmd_export "$2"
    ;;
  import)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
    CLONE_FLAG=0
    if [ "${3:-}" = --clone-projects ]; then
      CLONE_FLAG=1
    elif [ "$#" -eq 3 ]; then
      usage
    fi
    cmd_import "$2" "$CLONE_FLAG"
    ;;
  *) usage ;;
esac
