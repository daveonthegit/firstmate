# Placed-task cleanup: local live validation

All nine scoped scenarios passed. The independent oracle was the W3 two-leg cleanup contract and the recorded R1/R2/R3 decisions: host success precedes primary retirement/backlog movement; unknown transport preserves primary records; deliverables refresh while readable; shared mirror membership and retirement are serialized; backlog failures leave replayable markers without orphan cursors.

## Executed surfaces

- Existing focused suite: `TMPDIR="$PWD/.test-tmp" bash tests/fm-teardown-host.test.sh` (exit 0, complete). Its fake SSH/tmux/Treehouse checks are supplemental integration evidence, not the basis for live claims.
- Manual executable driver: `python3 .test-tmp/live-cleanup.py` (exit 0, `LIVE_DRIVER_COMPLETE`). Retained as `live-cleanup-driver.py`.
- Real `/usr/sbin/sshd` listening only on localhost port 22487, disposable host/client Ed25519 keys and SSH configuration inside the worktree; real `/usr/bin/ssh` through `fm-on.sh`.
- Real `fm-teardown.sh`, `fm-remote-worker-control.sh`, deliverable fetching, `fm-captain-hold.sh`, process-event registration/retirement, and `tasks-axi` against disposable operational homes and Markdown backlog.
- Real tmux task windows on a private socket and real Treehouse durable leases/worktree returns for a synthetic Git project. Both operational homes were marked by `bin/fm-lab-home.sh`.

The localhost SSH server used a forced-command installation adapter that decoded fm-on's argv protocol and executed the actual tracked worker-control command with isolated environment and HOME. It did not run the production remote-entrypoint/job-worker installation path. No real harness/model session, operator data, credentials, default tmux server, Herdr session, second Mac, or T3 endpoint was used or validated.

## Scenarios and observable outcomes

1. Ship: host task/placement claim removed, final journal copied, primary task/status removed, backlog done, real pool slot returned.
2. SSH unavailable: stopped the disposable sshd; cleanup returned 255 and both homes plus in-flight backlog remained. Restarted sshd and retried successfully.
3. Lost host answer: injected remote exit 255 after the actual host teardown completed. Primary record, registration and in-flight backlog remained; retry observed no host task and converged to done using cached journal.
4. Dirty host copy: cleanup refused and preserved synthetic scratch bytes and both records. Removed only the synthetic scratch file; retry refreshed the updated journal and completed. The supplemental suite additionally exercised explicit force forwarding.
5. Sibling mirror registration: cleanup of the first of two real synthetic placements retained the shared registration and sibling record; cleanup of the last removed the registration.
6. Lifecycle lock: paused SSH response after host teardown and held the real mirror lifecycle lock; primary cleanup waited with task/status intact, then retired them after release. This drives serialization, not an active long-poll ingestion process.
7. Backlog close/retain failures: a workspace-local tasks-axi fault injector rejected only the final mutation, delegating other calls to real tasks-axi. Actual cleanup removed host/primary membership and retired cursor/registration while retaining pending transition markers. Both close and retain were exercised.
8. Route drift: changed only the disposable registry home; cleanup refused without removing host or primary task. Restored registry and cleaned up.
9. Scout: absent report refused, then missing captain-call inventory refused after fetching report. Changed report, completed inventory through the actual CLI, and retried; refreshed final findings persisted and both legs completed with backlog done.

## Teardown

Every launched subprocess was waited for. Disposable SSH server processes and private tmux server were stopped; process inspection found no remaining driver, SSH server or task sleep processes. Generated homes, keys, worktrees, driver and temporary files were removed from the worktree after evidence capture. No tracked source changes were needed. No broad suite, lint, formatting, static analysis, push, or other gate phase was run.
