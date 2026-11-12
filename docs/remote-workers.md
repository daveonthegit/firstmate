# Remote workers

This page covers worker hosts: other SSH-reachable machines that run individual ship and scout workers for this primary.
It is for operators preparing a worker host and for anyone checking what crosses the machine boundary.

A worker host spreads individual tasks across machines, where a [remote second mate](remote-secondmates.md) takes a whole scope of work.
The primary keeps the task record, backlog, brief, merge authority, and every captain-facing decision.
The worker host runs a headless Firstmate home with its own project clones, worktree pools, no-mistakes daemon, and runtime backend, and runs no firstmate or second-mate agent of its own.

## Current limits

- This build provides the worker host registry, its route, the host-local leg, the status mirror, the seed and doctor that prepare and check a host, placement from the primary with `fm-spawn.sh --host`, steering, state, peek, interrupt, exit, answering, and ready-PR recording of a placed task from the primary, and cleanup from the primary with `fm-teardown.sh`, all described below.
- The primary cannot yet relaunch a placed task: `fm-control relaunch` recognizes its placement and refuses.
- With [automatic placement](configuration.md#automatic-placement-configauto-placement) on, a spawn with no machine named runs on the machine with the most room ([how placement is chosen](#how-placement-is-chosen)); with it off, the default, placement is an explicit per-task choice.
- Placement never pins a project to a machine, never seeds a project onto a host, and never moves a running task to rebalance load.
- A running task moves between the primary and a worker host, or between two worker hosts, with `fm-handoff.sh <task> --to <host-id|local>` (Moving a task between machines below); the rescue repository lives only on the primary, and neither mirroring it to another machine nor fetching placed copies' branches into it on a schedule is built.

## How it works

1. Firstmate places a ship or scout with [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) `--host <id>`, or automatic placement picks that host ([how placement is chosen](#how-placement-is-chosen)); the spawn resolves the worker host from `data/worker-hosts.md` and reaches it with [`bin/fm-on.sh`](../bin/fm-on.sh), the same SSH transport, fixed entrypoint, and remote job worker that remote second mates use.
2. Every per-task operation runs [`bin/fm-remote-worker-control.sh`](../bin/fm-remote-worker-control.sh) in the host's home.
3. That leg runs the ordinary local scripts there: the host's own `fm-brief`, `fm-spawn`, `fm-crew-state`, `fm-send`, `fm-control`, `fm-t3-answer`, `fm-peek`, `fm-remote-file`, and `fm-teardown`.
4. The host keeps an ordinary local task record under the same task id, plus a placement claim that marks the task as placed by a primary.
5. The primary records the route the host returned in its own task record, moves the backlog item In flight, and arms the host's status mirror.
6. Cleanup on the primary runs in two legs: the host first runs its own full `fm-teardown.sh`, and only after that succeeds does the primary retire its records, release the task from the host's status mirror, and move the backlog item exactly as a local cleanup does.

[`bin/fm-task-route-lib.sh`](../bin/fm-task-route-lib.sh) owns route discrimination between placed tasks, local tasks, and remote second mates.
A host at capacity defers the placement exactly as a local spawn defers, and the backlog item stays queued.
The [`fm-spawn.sh` header](../bin/fm-spawn.sh) owns the forwarded flags, local checks, recorded keys, and placement recovery, including a re-run after a failed mirror arm.

Of the brief itself, only its `# Task` section crosses the machine boundary.
For a continuation, the [`fm-spawn.sh` header](../bin/fm-spawn.sh) also owns the carried documents and preservation metadata sent to the host.
The host re-renders the rest of the brief itself, so every path a worker is told - its status file, steering inbox, report, and journal - is a path in the host's home.
The primary forwards the facts that shape the scaffold as explicit flags; the [controller header](../bin/fm-remote-worker-control.sh) owns that flag set and the route block it prints.
A brief section the primary edited by hand outside `# Task` is not carried.
The host's spawn re-validates the brief against the host's own `data/projects.md`, capacity declarations, and backend.

The host leg answers only for tasks a primary placed there.
A spawn for a task the host already holds reports the existing route instead of launching again, which makes a re-run after an unconfirmed SSH spawn safe.
The [controller header](../bin/fm-remote-worker-control.sh) owns delivery identity and retry requirements for steering.
Cleanup uses the host's ordinary [`fm-teardown.sh`](../bin/fm-teardown.sh), whose header owns the landed-work test, the force exception, and the two-leg worker-host cleanup.
See that header's worker-host cleanup contract for document refresh, the scout completion gate, failure preservation, and safe retries after an unconfirmed host answer.

## How placement is chosen

A machine named for the task always wins: `--host <id>` places it on that worker host, and `--host local` keeps it on the supervisor's machine on purpose.
With no machine named and automatic placement on, the spawn treats the supervisor's machine and every worker host as equals and asks each one for its own capacity report, the host through its leg's `headroom` verb.

- A machine is eligible only when it already has the project's clone; a host's clone comes from its seed, and placement never seeds one.
- A machine admits the task when its own lane cap has an open lane and none of its host checks (load, memory, disk, pressure, a reserve flag, battery) holds it closed.
- A host that cannot be reached, does not answer in time, has no lane cap, or lacks the project is skipped, never treated as free.
- Each task counts against the machine it runs on: a task placed on a host holds a lane there and none on the supervisor's machine.
- The admitting machines are ranked by their open share of their own cap, so a small and a large machine compare fairly; a tie goes to more open lanes, then to the supervisor's machine, then to worker hosts in registry order.

The spawn prints every machine it considered with its open lanes, load, and free memory, or why it was skipped, and then its choice.
It then runs the ordinary placement on the best machine; a machine that still defers at spawn passes the task to the next, and when none admits it the task stays queued with exit 75, exactly like a full machine today.
Run [`bin/fm-placement.sh`](../bin/fm-placement.sh) `<project>` to see the same decision without spawning anything; its header owns the rules above in full, and the [`fm-spawn.sh` header](../bin/fm-spawn.sh) owns retries, including how a placement whose answer was lost goes back to the same host instead of starting a second worker.

## Reaching a placed worker

The primary's ordinary per-task commands recognize a placed task and run the matching host leg verb instead of touching any local endpoint:

- [`fm-send.sh`](../bin/fm-send.sh) steers through `send-stdin`, under a delivery id the primary mints, and its header owns the retry, resend, and decision-closing contract.
- [`fm-crew-state.sh`](../bin/fm-crew-state.sh) relays the host's own reading through `state`, and reports `unknown-remote` when the host cannot be reached, never dead and never a local reading.
- [`fm-peek.sh`](../bin/fm-peek.sh) reads the worker's pane through `capture`.
- [`fm-control.sh`](../bin/fm-control.sh) runs `interrupt` and `exit` through `control`, and refuses `relaunch`.
- [`fm-t3-answer.sh`](../bin/fm-t3-answer.sh) reads and answers a T3 worker's pending questions through `answer`.
- [`fm-pr-check.sh`](../bin/fm-pr-check.sh), and the watcher's scan and `fm-pr-merge.sh` through it, record a ready PR once the host's own named-head gate accepts it through `named-head`; [`fm-dod-lib.sh`](../bin/fm-dod-lib.sh) owns that gate and its cannot-verify-now outcome when the host does not answer.

An SSH exit 255 leaves the remote outcome unknown; the linked command headers own each operation's reporting and recovery contract.

## Status mirror

A placed worker appends status lines to its own status file in the host's home, and the primary mirrors them into its own status file for that task, so the watcher, the open-decision fold, and the PR gates read one stream exactly as for a local worker.
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

## Moving a task between machines

[`bin/fm-handoff.sh`](../bin/fm-handoff.sh) `<task> --to <host-id>` hands a task running on the primary to a worker host, and `--to local` or `--to <other-host-id>` hands a placed task back or onward; its header owns the steps, preflight, and refusals.
The work crosses as commits on a remote both machines reach: origin, or the primary's private rescue repository ([`bin/fm-rescue.sh`](../bin/fm-rescue.sh)), which a worker host reaches over SSH at the destination named in `config/rescue-ssh` ([configuration](configuration.md#rescue-remote-configrescue-ssh)).
Using the rescue repository needs SSH from the worker host back to the primary, with strict host-key checking and no agent forwarding as in the [transport prerequisites](remote-secondmates.md#prerequisites).
The [`fm-handoff.sh` header](../bin/fm-handoff.sh) owns readiness and preservation checks before cleanup, including waiting for an unresponsive worker and retrying a partial finish.

## Verification

[`tests/fm-remote-worker-control.test.sh`](../tests/fm-remote-worker-control.test.sh) drives the host leg against a fake worker-host home with the real brief, spawn, steer, file, and cleanup scripts.
[`tests/fm-spawn-host.test.sh`](../tests/fm-spawn-host.test.sh) drives placement from a primary through a fake SSH into that same host leg, covering capacity deferral, a re-run after an unknown SSH result, and mirror-arm recovery under away admission limits.
[`tests/fm-placement.test.sh`](../tests/fm-placement.test.sh) drives automatic placement through a fake SSH into two worker-host homes, covering the ranking and its ties, a host that is unreachable, uncapped, or lacks the project, placed tasks counted on their host, the setting off by default, `--host local`, a deferral that falls to the next machine, nothing admitting, and a lost answer re-run on the same host.
[`tests/fm-teardown-host.test.sh`](../tests/fm-teardown-host.test.sh) drives two-leg cleanup through a fake SSH into that host leg, covering success, an unreachable host, a lost answer and its re-run, a host refusal for unlanded work, a drifted route, a shared mirror, and a scout's report and captain-call gate.
[`tests/fm-handoff-host.test.sh`](../tests/fm-handoff-host.test.sh) drives `fm-handoff.sh --to <host>` through a fake SSH into two worker-host homes and a fake git SSH transport into the primary's rescue repository, covering a ship moving to a host, back to the primary, and between hosts, a scout with its interim report, and the target, worker, and record refusals.
[`tests/fm-pr-check-host.test.sh`](../tests/fm-pr-check-host.test.sh) drives ready-PR recording of a placed ship through a fake SSH into the host leg, covering a pushed head, a head only in the host's disposable copy, and an unreachable host that the watcher's scan retries.
[`tests/fm-task-route-lib.test.sh`](../tests/fm-task-route-lib.test.sh) covers shared route discrimination and placed operations that never touch a local backend.
[`tests/fm-placed-task-control.test.sh`](../tests/fm-placed-task-control.test.sh) drives steering, state, peek, control, and answering of a placed task from a primary through a fake SSH into the host leg, covering a resend that reuses its delivery id and `unknown-remote` on SSH exit 255.
[`tests/fm-on.test.sh`](../tests/fm-on.test.sh) covers worker host routing beside remote second-mate routes.
[`tests/fm-remote-worker-mirror.test.sh`](../tests/fm-remote-worker-mirror.test.sh) drives the status mirror through the real entrypoint, remote job worker, and process-event runner.
[`tests/fm-worker-host-seed-doctor.test.sh`](../tests/fm-worker-host-seed-doctor.test.sh) seeds, checks, and repairs a worker host home from the primary through the real entrypoint and remote job worker, with fake T3 servers for the sign-in, version, and capability checks.
