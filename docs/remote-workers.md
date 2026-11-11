# Remote workers

This page covers worker hosts: other SSH-reachable machines that run individual ship and scout workers for this primary.
It is for operators preparing a worker host and for anyone checking what crosses the machine boundary.

A worker host spreads individual tasks across machines, where a [remote second mate](remote-secondmates.md) takes a whole scope of work.
The primary keeps the task record, backlog, brief, merge authority, and every captain-facing decision.
The worker host runs a headless Firstmate home with its own project clones, worktree pools, no-mistakes daemon, and runtime backend, and runs no firstmate or second-mate agent of its own.

## Current limits

- This build provides the worker host registry, its route, the host-local leg, the status mirror, and the seed and doctor that prepare and check a host, all described below.
- Placing a task on a host from the primary, and the primary's read, steer, and cleanup paths for it, are not wired yet, so no command here starts a remote worker on the primary's behalf and nothing arms the mirror.
- Automatic placement by load is not built; placement will be an explicit per-task choice first.

## How it works

1. The primary resolves a worker host from `data/worker-hosts.md` and reaches it with [`bin/fm-on.sh`](../bin/fm-on.sh), the same SSH transport, fixed entrypoint, and remote job worker that remote second mates use.
2. Every per-task operation runs [`bin/fm-remote-worker-control.sh`](../bin/fm-remote-worker-control.sh) in the host's home.
3. That leg runs the ordinary local scripts there: the host's own `fm-brief`, `fm-spawn`, `fm-crew-state`, `fm-send`, `fm-control`, `fm-t3-answer`, `fm-peek`, `fm-remote-file`, and `fm-teardown`.
4. The host keeps an ordinary local task record under the same task id, plus a placement claim that marks the task as placed by a primary.

Only the brief's `# Task` section crosses the machine boundary.
The host re-renders the rest of the brief itself, so every path a worker is told - its status file, steering inbox, report, and journal - is a path in the host's home.
The primary forwards the facts that shape the scaffold as explicit flags; the [controller header](../bin/fm-remote-worker-control.sh) owns that flag set and the route block it prints.
A brief section the primary edited by hand outside `# Task` is not carried.
The host's spawn re-validates the brief against the host's own `data/projects.md`, capacity declarations, and backend, so a host at capacity defers exactly as a local spawn does.

The host leg answers only for tasks a primary placed there.
A spawn for a task the host already holds reports the existing route instead of launching again, which makes a re-run after an unconfirmed SSH spawn safe.
The [controller header](../bin/fm-remote-worker-control.sh) owns delivery identity and retry requirements for steering.
Cleanup uses the host's ordinary [`fm-teardown.sh`](../bin/fm-teardown.sh), whose header owns the landed-work test and force exception.

## Status mirror

A placed worker appends status lines to its own status file in the host's home, and the primary mirrors them into its own status file for that task, so the watcher, the open-decision fold, crew state, and the PR gates read one stream exactly as for a local worker.
The primary keeps one listener per host, not one per task, because the remote job worker serves one lane per home; that listener's host read, [`bin/fm-remote-worker-events.sh`](../bin/fm-remote-worker-events.sh), is preemptible, so a steer, state read, or cleanup for the same host never waits behind it.
The [adapter header](../bin/fm-procevent-remote-worker.sh) owns membership, cursors, document fetch before completion (including missing-document and transport-failure handling), and recovery from broken log continuity.

## Register a worker host

Add one line per host to the primary's `data/worker-hosts.md`; [configuration](configuration.md#worker-hosts-dataworker-hostsmd) owns the record format.
The [`fm-on.sh` header](../bin/fm-on.sh) owns route uniqueness across both registries, including id and SSH-alias collisions.

## Prepare the worker host

Register the host first, then let the primary seed its home and check it:

1. Meet the [remote second mate prerequisites](remote-secondmates.md#prerequisites): an SSH alias with strict host keys and no agent forwarding, a Firstmate clone at an absolute code root, at a build that carries these commands, and the fixed entrypoint on the non-interactive `PATH`.
2. Add the host's record to the primary's `data/worker-hosts.md`, naming a home outside the code root ([register a worker host](#register-a-worker-host)).
3. From the primary, run `bin/fm-worker-host-seed.sh <id> --lanes <cap> [--capacity <project>=<n>]... <project>[=<origin-url>]...`.
4. On the host, as the worker account, sign in to every worker tool, model account, and forge identity its workers will use, including the home's own T3 sign-in when its workers use T3; every login is the operator's own step.
5. Select the host's runtime in its home's `config/backend` when it should differ from the default.
6. From the primary, run `bin/fm-worker-host-doctor.sh <id>` until it reports the host ready, and rerun it whenever the host or the primary changes.

The seed first checks the account's transport readiness with [`fm-remote-doctor.sh`](remote-secondmates.md#readiness-repair-and-the-human-steps), repairing what it can, and touches the home only once that passes.
It then creates the home with `data/`, `state/`, `config/`, and `projects/`, writes the `.fm-worker-host` marker, sets `config/backlog-backend` to `manual` because the primary's backlog owns these tasks, writes `config/lane-capacity` and `config/project-capacity` from the values given, clones each project from its origin, copies the primary's registry line for it so its delivery mode and forge binding match, and runs `no-mistakes init` in each no-mistakes project.
An explicitly named local-only project is refused, an existing capacity declaration is never overwritten, and a second-mate home or a home marked for another worker host is never changed.
Clone URLs must be credential-free; [the origin validator](../bin/fm-project-origin-lib.sh) owns the accepted forms, and authentication must be configured on the host.
The doctor reports each of those facts plus the host's T3 sign-in days left and whether its T3 version and capabilities match the primary's own; with `--fix` it repairs the gaps it owns, and the rest are named with the step that closes them.
If the primary has a T3 sign-in but its status cannot be read, the comparison remains unresolved, not ready.
If neither home has a T3 sign-in, T3 checks are skipped; an existing host sign-in is still checked even when the primary has none.
With no project named, the doctor checks every non-local-only project the primary registers that the host already clones or registers; an unresolved primary delivery posture aborts the command rather than silently omitting the project.
No credential, token, `config/` file, or `state/` record crosses from the primary.
[`fm-worker-host-doctor.sh`](../bin/fm-worker-host-doctor.sh) owns what is sent and its exit statuses, and [`fm-worker-host-home.sh`](../bin/fm-worker-host-home.sh) owns every check, repair, and output line on the host.

A worker host runs its workers with every credential placed on it, so treat it as sensitive as the primary.

## Verification

[`tests/fm-remote-worker-control.test.sh`](../tests/fm-remote-worker-control.test.sh) drives the host leg against a fake worker-host home with the real brief, spawn, steer, file, and cleanup scripts.
[`tests/fm-on.test.sh`](../tests/fm-on.test.sh) covers worker host routing beside remote second-mate routes.
[`tests/fm-remote-worker-mirror.test.sh`](../tests/fm-remote-worker-mirror.test.sh) drives the status mirror through the real entrypoint, remote job worker, and process-event runner.
[`tests/fm-worker-host-seed-doctor.test.sh`](../tests/fm-worker-host-seed-doctor.test.sh) seeds, checks, and repairs a worker host home from the primary through the real entrypoint and remote job worker, with fake T3 servers for the sign-in, version, and capability checks.
