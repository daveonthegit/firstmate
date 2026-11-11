# Remote workers

This page covers worker hosts: other SSH-reachable machines that run individual ship and scout workers for this primary.
It is for operators preparing a worker host and for anyone checking what crosses the machine boundary.

A worker host spreads individual tasks across machines, where a [remote second mate](remote-secondmates.md) takes a whole scope of work.
The primary keeps the task record, backlog, brief, merge authority, and every captain-facing decision.
The worker host runs a headless Firstmate home with its own project clones, worktree pools, no-mistakes daemon, and runtime backend, and runs no firstmate or second-mate agent of its own.

## Current limits

- This build provides the worker host registry, its route, the host-local leg, the status mirror, and placement from the primary with `fm-spawn.sh --host`, all described below.
- The primary cannot yet read, peek at, steer, interrupt, answer, or clean up a placed task: `fm-send`, `fm-peek`, `fm-control`, `fm-t3-answer`, and `fm-teardown` recognize its placement and explicitly refuse unsupported operations, while `fm-crew-state` reports unknown state and names the worker host; those steps run on the host itself for now.
- Placement is an explicit per-task choice; automatic placement by load or by project is not built.

## How it works

1. Firstmate places a ship or scout with [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) `--host <id>`, which resolves the worker host from `data/worker-hosts.md` and reaches it with [`bin/fm-on.sh`](../bin/fm-on.sh), the same SSH transport, fixed entrypoint, and remote job worker that remote second mates use.
2. Every per-task operation runs [`bin/fm-remote-worker-control.sh`](../bin/fm-remote-worker-control.sh) in the host's home.
3. That leg runs the ordinary local scripts there: the host's own `fm-brief`, `fm-spawn`, `fm-crew-state`, `fm-send`, `fm-control`, `fm-t3-answer`, `fm-peek`, `fm-remote-file`, and `fm-teardown`.
4. The host keeps an ordinary local task record under the same task id, plus a placement claim that marks the task as placed by a primary.
5. The primary records the route the host returned in its own task record, moves the backlog item In flight, and arms the host's status mirror.

The primary's task record names the host with `remote_worker_host=` and never with the second-mate key `remote_host=`, and it records the host's paths only under `remote_*` keys, so nothing here mistakes them for a local copy and this machine's project capacity does not count the task.
[`bin/fm-task-route-lib.sh`](../bin/fm-task-route-lib.sh) is the one helper that tells a placed task from a local task and from a remote second mate.
A host at capacity defers the placement exactly as a local spawn defers, and the backlog item stays queued.
The [`fm-spawn.sh` header](../bin/fm-spawn.sh) owns the forwarded flags, local checks, recorded keys, and placement recovery, including a re-run after a failed mirror arm.

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

A placed worker appends status lines to its own status file in the host's home, and the primary mirrors them into its own status file for that task, so the watcher, the open-decision fold, and the PR gates read one stream exactly as for a local worker.
The primary keeps one listener per host, not one per task, because the remote job worker serves one lane per home; that listener's host read, [`bin/fm-remote-worker-events.sh`](../bin/fm-remote-worker-events.sh), is preemptible, so a steer, state read, or cleanup for the same host never waits behind it.
The [adapter header](../bin/fm-procevent-remote-worker.sh) owns membership, cursors, document fetch before completion (including missing-document and transport-failure handling), and recovery from broken log continuity.

## Register a worker host

Add one line per host to the primary's `data/worker-hosts.md`; [configuration](configuration.md#worker-hosts-dataworker-hostsmd) owns the record format.
The [`fm-on.sh` header](../bin/fm-on.sh) owns route uniqueness across both registries, including id and SSH-alias collisions.

## Prepare the worker host

There is no seed or doctor for a worker host yet, so prepare it by hand:

1. Meet the [remote second mate prerequisites](remote-secondmates.md#prerequisites): an SSH alias with strict host keys and no agent forwarding, a Firstmate clone at an absolute code root, the fixed entrypoint on the non-interactive `PATH`, and the remote job worker installed by `fm-remote-doctor.sh --fix`.
2. Create the home directory separately from the code root, with `data/`, `state/`, `config/`, and `projects/` inside it.
3. Write an `.fm-worker-host` marker file at the home root, and do not make the home a second-mate home.
4. Write `manual` to the home's `config/backlog-backend`, because the primary's backlog owns these tasks.
5. Clone each project the host should work on into the home's `projects/`, register it in the home's `data/projects.md` with the same delivery mode and forge binding as the primary, and run `no-mistakes init` in each no-mistakes project.
6. Select the host's runtime in its own `config/backend` and declare its limits in `config/project-capacity` and `config/lane-capacity`.
7. Sign in on the host to every worker tool, model account, and forge identity its workers will use; every login is the operator's own step.

A worker host runs its workers with every credential placed on it, so treat it as sensitive as the primary.

## Verification

[`tests/fm-remote-worker-control.test.sh`](../tests/fm-remote-worker-control.test.sh) drives the host leg against a fake worker-host home with the real brief, spawn, steer, file, and cleanup scripts.
[`tests/fm-spawn-host.test.sh`](../tests/fm-spawn-host.test.sh) drives placement from a primary through a fake SSH into that same host leg, covering capacity deferral, a re-run after an unknown SSH result, and mirror-arm recovery under away admission limits.
[`tests/fm-task-route-lib.test.sh`](../tests/fm-task-route-lib.test.sh) covers shared route discrimination and primary entry-point refusals without local backend actions.
[`tests/fm-on.test.sh`](../tests/fm-on.test.sh) covers worker host routing beside remote second-mate routes.
[`tests/fm-remote-worker-mirror.test.sh`](../tests/fm-remote-worker-mirror.test.sh) drives the status mirror through the real entrypoint, remote job worker, and process-event runner.
