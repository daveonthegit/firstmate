# Account-pin live validation

Scope: disposable marked homes, real local T3 server and real tmux panes. No production repository permission claim and no real lander restart.

## T3 secondmate launch with pre-existing daveonthegit pin
Real MCP launch accepted; launch-owned previous account key removed from persisted settings and task metadata. This tests environment generation/launch, not model reply quality. The thread was archived after inspection; its archived run status is failed (not a successful model conversation).
```
fm-gate-refuse: gate agent lifecycle permitted only against lab home {run-worktree}/.gate-lab/primary
warning: secondmate gh-live-t3-pin sync skipped before launch: primary default-branch commit cannot be resolved
spawned gh-live-t3-pin harness=claude kind=secondmate mode=secondmate yolo=off window=fm-gh-live-t3-pin worktree={run-worktree}/.gate-lab/mate
```
```json
{
  "FM_GH_ACCOUNT": null,
  "metadataAccount": null,
  "perTaskGhShimOnPath": false
}
```

## Real interactive pane launches and stale-token replacement launches
Each file contains observations from a transparent wrapper immediately before exec of the installed real Claude CLI. First line is fresh launch; second is --relaunch into an agent-free shell exporting old-launch-owner-token. No CLI or tmux was stubbed. tmux grids were 120x35. The private socket was reached using a transport wrapper to avoid the worktree path exceeding the Unix socket path length.
### bash
```
GH_TOKEN=EMPTY FM_GH_ACCOUNT=ABSENT
GH_TOKEN=EMPTY FM_GH_ACCOUNT=ABSENT
```
fm-gate-refuse: gate agent lifecycle permitted only against lab home {run-worktree}/.gate-lab/primary
warning: secondmate gh-live-pane-bash sync skipped before launch: primary default-branch commit cannot be resolved
spawned gh-live-pane-bash harness=claude kind=secondmate mode=secondmate yolo=off window=primary:fm-gh-live-pane-bash worktree={run-worktree}/.gate-lab/mate-bash
### fish
```
GH_TOKEN=EMPTY FM_GH_ACCOUNT=ABSENT
GH_TOKEN=EMPTY FM_GH_ACCOUNT=ABSENT
```
fm-gate-refuse: gate agent lifecycle permitted only against lab home {run-worktree}/.gate-lab/primary
warning: secondmate gh-live-pane-fish sync skipped before launch: primary default-branch commit cannot be resolved
spawned gh-live-pane-fish harness=claude kind=secondmate mode=secondmate yolo=off window=primary:fm-gh-live-pane-fish worktree={run-worktree}/.gate-lab/mate-fish

## Repository-specific reads: real gh against localhost GitHub emulator
Two synthetic logins (fixture-source and fixture-target) avoid the operator keychain identities. The active disposable account is fixture-source; the home map chooses fixture-target for BG-Media-LLC. These are not production credentials. All API traffic uses the local TLS proxy.
Mapped repository response:
```json
{"full_name": "BG-Media-LLC/validation", "private": true, "permissions": {"admin": true, "push": true, "pull": true}}
```
Old launch pin deliberately restored (must 404):
```
{"message": "Not Found"}gh: Not Found (HTTP 404)
```
Active account after successful mapped read (must remain fixture-source):
```json
{"login": "fixture-source", "id": 1}
```

## Targeted checks
- fm-gh-account.test.sh passed, including Fish after downloading/unpacking Fish only inside the worktree.
- Targeted T3 account-removal and secondmate-env tests passed (with existing top-level stale-watcher checks).
- No full repository suite, linter, formatter, push, PR, or CI phase was run.
- No UI behavior or placement changed; CLI transcripts and persisted state are the relevant evidence.
- Disposable tmux servers and API/server processes stopped; workspace fixtures removed after evidence capture.
