# Multi-host and macOS setup

This guide covers bringing up a new macOS host, moving the primary Firstmate home to it, running another host as an equal worker or second-mate host with load balancing, and temporarily reserving a host for gaming or server hosting.
Each underlying subsystem keeps its own owner: [remote second mates](remote-secondmates.md), [remote workers](remote-workers.md), [configuration](configuration.md), and [supervising from another machine](supervisor-takeover.md).

## 1. Bootstrap a fresh Mac

Clone Firstmate to an absolute path on the new Mac (separate from any worker or second-mate home), then run the idempotent host bootstrap:

```sh
bin/fm-host-bootstrap.sh --role both --backend <backend>
bin/fm-host-bootstrap.sh --fix --role both --backend <backend>
```

Or run it from an existing host over SSH before registering the Mac:

```sh
bin/fm-host-bootstrap.sh --ssh <ssh-alias> --remote-root <abs-firstmate-root> --fix --role both
```

- `--role` selects `primary`, `worker`, or `both` (default `both`, so the machine can act as either a primary or a remote worker and second-mate host).
- `--fix` installs missing automatable tools through `bin/fm-bootstrap.sh install`, upgrades outdated automatable tools, links `~/.local/bin/fm-remote-entrypoint.sh` when absent without overwriting non-Firstmate files, and delegates Aqua LaunchAgents and version-manager wrappers to [`bin/fm-remote-doctor.sh`](remote-secondmates.md#readiness-repair-and-the-human-steps).
- Rerunning converges and exits `0` once every automated check and every verifiable sign-in passes; the [`bin/fm-host-bootstrap.sh` header](../bin/fm-host-bootstrap.sh) owns the exact flags and line protocol.

### Human-only sign-ins

Firstmate never automates interactive logins, passwords, or macOS security settings.
`fm-host-bootstrap.sh` keeps listing each sign-in it can verify (macOS console session, GitHub, and T3 Code on the `t3code` backend) as a gating `human:` step until it is completed on that Mac.
Claude and Antigravity sign-ins cannot be verified non-interactively, and T3 Code is not needed on other backends, so those print as non-gating `reminder:` lines with their action:

| Sign-in | What a person does at the Mac |
| --- | --- |
| Apple ID and macOS console | Sign in at the console so an Aqua GUI session exists, enable System Settings > General > Sharing > Remote Login (SSH), and choose your automatic-login and FileVault posture for headless reboots ([remote second mate prerequisites](remote-secondmates.md#steps-only-a-person-can-take)). |
| GitHub | Run `gh auth login` as the host account. |
| Claude | Run `claude` inside the Aqua GUI session and complete `/login` so credentials land in the login keychain. |
| Antigravity | Install `agy` and complete its interactive login if this host runs Antigravity. |
| T3 Code | Open T3 Code on that Mac and run `<firstmate-root>/bin/fm-t3-mcp.mjs login --access full-access --token-file <home>/config/t3code-token` ([T3 Code sign-in](t3code-backend.md)). |

## 2. Migrate the primary Firstmate home

Use [`bin/fm-primary-migrate.sh`](../bin/fm-primary-migrate.sh) for a planned move of the primary home to a new Mac.
For an unplanned takeover when the old primary is unreachable, follow [Supervising from another machine](supervisor-takeover.md) instead.

1. Finish or hand off in-flight local tasks, worker-host-placed tasks, and local second mates on the old primary, then run `/stow` so durable memory and backlog state are written.
   Running remote second mates may stay up on their own hosts.
2. Stop the old primary session and exit any away or quiet posture so `state/.lock` is free.
3. Run the read-only gate on the old primary and resolve every reported `blocker:`:

   ```sh
   bin/fm-primary-migrate.sh preflight
   ```

   Preflight refuses live locks, active away records, local or placed task records, pending backlog closes, handoff outboxes, unresolved pending replies, unpruned rescue refs, dirty or unpushed project clones, and dirty or unpushed records repositories rather than guessing.
4. If `data/` is a records repository with a remote ([supervisor lease](configuration.md#supervisor-lease-datasupervisorlease)), sync and release the lease on the old primary:

   ```sh
   bin/fm-supervisor-lease.sh sync --reason "pre-migration"
   bin/fm-supervisor-lease.sh release
   ```

5. Export a verified migration bundle on the old primary (refuses if any blocker or held lease remains):

   ```sh
   bin/fm-primary-migrate.sh export /path/to/fm-migration-bundle
   ```

   The bundle carries `data/`, portable `config/` files, `git bundle --all` archives for `local-only` or origin-less projects, and credential-free origin URLs for remote-backed projects.
   It never copies `state/.lock`, local PIDs, `.env` secrets, or machine-bound config (`t3code-token`, `machine-id`, `rescue-ssh`, `lane-capacity`, `project-capacity`, `obsidian-vault`, `record-export-root`, account pins).
6. Copy the bundle to the new Mac (for example over AirDrop, Thunderbolt, or `scp`), bootstrap the new Mac with `bin/fm-host-bootstrap.sh`, and write a distinct `config/machine-id` on the new Mac.
7. If `data/` uses a records remote, clone that records repository into the new home's `data/` before importing, then run:

   ```sh
   bin/fm-primary-migrate.sh import /path/to/fm-migration-bundle --clone-projects
   ```

   Omit `--clone-projects` to print the clone and `no-mistakes init` commands instead of cloning immediately.
8. Complete the printed post-import checklist: transfer `.env` securely if used, set machine-local config (`config/lane-capacity`, `config/rescue-ssh`, `config/auto-placement`), complete human sign-ins, configure SSH aliases on the new Mac for every remote host, verify each remote second mate (`bin/fm-on.sh <id> fm-remote-doctor.sh && bin/fm-spawn.sh <id> --secondmate` adopts an already-running remote mate without launching a duplicate) and each worker host (`bin/fm-worker-host-doctor.sh <id>`), and start the new primary with `bin/fm-session-start.sh`.

## 3. Equal worker hosts and load balancing

Any bootstrapped Mac or Linux host can run individual ship and scout workers beside the primary, and can also host remote second-mate homes at the same time.

### Add a worker host

1. Configure an SSH alias in the primary's `~/.ssh/config` with public-key authentication, strict host keys, and no agent forwarding ([SSH prerequisites](remote-secondmates.md#ssh-access-from-the-primary)).
2. Add one line to the primary's `data/worker-hosts.md` ([record format](configuration.md#worker-hosts-dataworker-hostsmd)) with a home path outside the remote code root.
   When a machine hosts both a worker-host home and one or more remote second-mate homes, give the worker host and each second mate distinct ids that differ from the shared SSH alias so `bin/fm-on.sh` always routes unambiguously.
3. Seed the worker-host home from the primary, using `--lanes auto` for measured adaptive budgeting (or a fixed integer cap):

   ```sh
   bin/fm-worker-host-seed.sh <host-id> --lanes auto <project>[=<origin-url>]...
   ```

   Rerun `bin/fm-worker-host-doctor.sh <host-id>` until it exits `0` ([remote workers](remote-workers.md#prepare-the-worker-host)).
4. Optionally seed remote second-mate homes on the same machine at separate non-overlapping home paths via [`bin/fm-remote-home-seed.sh`](remote-secondmates.md#provision-a-route).

### Balance across all available hosts

1. Declare `config/lane-capacity` (for example `auto` with `admit-spawns`, or a fixed cap) on the primary and on every worker host ([lane capacity](configuration.md#lane-capacity-configlane-capacity)).
2. Enable automatic placement on the primary:

   ```sh
   touch "$FM_HOME/config/auto-placement"
   ```

3. Preview placement decisions without spawning using `bin/fm-placement.sh <project>`.
   [`bin/fm-placement.sh`](../bin/fm-placement.sh) treats the primary and every registered worker host as equals, compares open share against each machine's fixed cap or adaptive budget, and skips unreachable, reserved, or project-less hosts.
   Use `fm-spawn.sh --host <id>` or `--host local` for an explicit per-task override, and `bin/fm-handoff.sh <task> --to <host-id|local>` to move a running task across hosts.

### Remove a worker host

1. Pause new placement on the host so no fresh task lands there while draining:

   ```sh
   bin/fm-host-reserve.sh pause --host <host-id> --reason "draining host"
   ```

2. Wait for placed tasks on that host to finish and clean up through `bin/fm-teardown.sh`, or move them with `bin/fm-handoff.sh <task> --to local` (or another host).
3. Remove the host's record line from the primary's `data/worker-hosts.md` once no placed tasks remain.
4. Retire any remote second-mate homes on that host separately through `bin/fm-teardown.sh <secondmate-id>` ([retirement](remote-secondmates.md#retire-a-remote-second-mate)).

## 4. Owner-reserved use (gaming or server hosting)

Use [`bin/fm-host-reserve.sh`](../bin/fm-host-reserve.sh) to pause or shrink new placement on the primary or any worker host without interrupting or killing running workers.

```sh
# Skip this host completely for new placement (for example while gaming)
bin/fm-host-reserve.sh pause --host <host-id> --reason "gaming" --for 4h

# Shrink capacity while hosting a server (keep 32 GB RAM and cap at 4 lanes)
bin/fm-host-reserve.sh reduce --host <host-id> --max-lanes 4 --keep-gb 32 --reason "game server"

# Check reservation status across the primary and all worker hosts
bin/fm-host-reserve.sh status --all

# Release manually before any --for duration expires
bin/fm-host-reserve.sh release --host <host-id>
```

- Omit `--host` (or pass `--host local`) to reserve the machine this command runs on.
- The reservation is machine-wide: it lives in the account's `~/.firstmate/host-reserve`, so every Firstmate home on that Mac (the primary or worker host home and any second-mate homes) skips or shrinks new placement together.
- `bin/fm-capacity.sh` reads that file live on every check, so `bin/fm-placement.sh` and `admit-spawns` skip a paused host or compute the shrunk capacity of a reduced host immediately while leaving running lanes untouched.
- External automation (such as a game-launch watcher script on a workstation or gaming PC) can continue using `reserve-flag <path> [label]` in `config/lane-capacity` ([lane capacity](configuration.md#lane-capacity-configlane-capacity)); both mechanisms compose cleanly.

## Verification

- [`tests/fm-host-bootstrap.test.sh`](../tests/fm-host-bootstrap.test.sh) exercises check mode, `--fix` tool installation and entrypoint linking, gating and reminder sign-in reporting, convergence to exit `0`, and safe SSH forwarding.
- [`tests/fm-primary-migrate.test.sh`](../tests/fm-primary-migrate.test.sh) exercises preflight refusals, supervisor-lease release gating, clean export, local-only git bundle preservation of every branch and tag, pre-cloned records repositories, machine-bound config exclusion, and guarded import.
- [`tests/fm-host-reserve.test.sh`](../tests/fm-host-reserve.test.sh) exercises pause, reduce (`--max-lanes`, `--keep-gb`), machine-wide reach across every home on the host, timed expiry, fail-closed malformed files, remote `--host` delegation, and `fm-placement.sh` balancing without disturbing running tasks.
- [`tests/fm-worker-host-seed-doctor.test.sh`](../tests/fm-worker-host-seed-doctor.test.sh) covers `--lanes auto` worker-host seeding and doctor checks alongside fixed caps.
