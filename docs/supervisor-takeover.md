# Supervising from another machine

This page is for an operator whose supervising machine is unreachable and who wants to run Firstmate from another machine for a while.
For a planned primary-home migration to a new machine, follow [Multi-host and macOS setup](host-setup.md#2-migrate-the-primary-firstmate-home).
It applies only to a home whose `data/` is a records repository with a remote, the setup the [supervisor lease](configuration.md#supervisor-lease-datasupervisorlease) describes.

## What the records remote holds

The records remote holds the last successfully published records: the backlog, captain preferences, learnings, briefs, reports, and the other curated records admitted by the [records sync](configuration.md#supervisor-lease-datasupervisorlease).
It never holds `state/` (task records, status logs, the wake queue), `config/`, or `projects/`, so those start empty or stale on the other machine.
A withheld, deferred, or refused sync leaves the remote behind until a later sync succeeds; do not assume it contains work recorded since the last successful publication.
The [`bin/fm-supervisor-lease.sh` header](../bin/fm-supervisor-lease.sh) owns sync diagnostics, outcome files, and recovery instructions.

## Take over

1. Prepare a Firstmate home on the other machine with its own `config/machine-id` (or a distinct host name), so the two machines never share an identity.
2. Put the records in that home's `data/`: clone the records repository there, or fast-forward an existing clone with `git -C data pull --ff-only`.
3. Copy any `config/` choices the fleet depends on, such as the runtime backend, dispatch profiles, and `config/secret-scan-allowlist`.
4. Run `bin/fm-supervisor-lease.sh status` and read which machine holds the lease and since when.
5. Only on the owner's explicit word, run `bin/fm-supervisor-lease.sh steal --owner-approved`.
6. Run session start as usual; it acquires the lease it now holds and takes the session lock.
7. Clone the projects the work needs, as for any new home.

## Reconcile work that ran on the lost machine

The backlog shows that work In flight, but this machine has no task record for it, because task records live in `state/`.
Treat each such item by what reached a remote:

- A pull request or pushed branch on the forge is intact; supervise the pull request or dispatch a new ship that continues from that branch.
- Work in a worktree on the lost machine that was never pushed, and anything in that machine's rescue repository (`bin/fm-rescue.sh`), is out of reach until that machine returns.
- A brief and any report under `data/<task-id>/` came across with the records, so a re-dispatch can reuse the brief's task text.
- A task placed on a worker host keeps running on that host, but this machine has no record of the placement and cannot adopt it; leave it for the original supervisor or re-dispatch it.

Re-dispatching starts a new task with a new id; leave the original backlog item in place until the lost machine's work is accounted for, and record that link in its note.

## When the original machine returns

The original machine can no longer supervise: its next session start finds the lease held elsewhere, or its records diverged from the remote, and stays read-only.
A session still running there stands down at its next records sync or push, queues a `supervisor-lease-lost` wake, and stops spawning, steering, and merging.
Its workers keep running, and its `state/` still knows them.

To move supervision back, run `bin/fm-supervisor-lease.sh release` on the temporary machine, then reconcile the original machine's `data/` with the remote before its session start.
Any records it committed while offline sit on a local branch that diverges from the remote; keep them on a separate branch, bring `data/` back to the remote's history, and carry over by hand whatever the temporary machine does not already have.
Session start there then acquires the lease, and its own task records resume supervision of the workers it still runs.
