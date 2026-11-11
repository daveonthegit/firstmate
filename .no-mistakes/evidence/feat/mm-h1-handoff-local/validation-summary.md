# H1 local handoff validation

## Executed
- `bash tests/fm-handoff.test.sh`: exit 0; all eight targeted behavior tests passed. These tests simulate the terminal and worker and are NOT live agent-handoff proof.
- Real private tmux lab, 120x40 grid, marked FM_HOME, disposable Git project, bare local origin, real treehouse and tasks-axi.
- Normal Claude authentication was available. Primary `claude -p` executed the initial spawn commands using the existing login.
- First spawn failed because zsh compinit consumed the initial treehouse command. Set only the private tmux server's shell to bash and retried. Real scout spawn then returned 0 and published metadata, but the worker stopped at Claude's Bypass Permissions acceptance dialog.
- Alternative supported raw Claude print-mode launch attempted to avoid the interactive permission dialog. Spawn refused trust pre-registration because the synthetic project's external CLAUDE.md imports had been declined. It explicitly required changing the user-level trust entry and approving imports interactively. No credential changes, login workaround, or trust-consent override was attempted.
- Real `fm-handoff.sh` guard execution: `live-guards.log` and `live-ship-guards.log`, both exit 0. Guard fixtures deliberately supply synthetic protocol status lines and, for ship preservation checks, synthetic task metadata and a real Git commit. They do not demonstrate a model obeying a handoff instruction.

## Observations
The running CLI refused missing preservation destination, nonlocal target, custom identity, unresolved decision, absent remote, absent/empty notes, dirty untracked work, and an unpublished carried branch. REQUEST, FINISH and CANCEL all refused worker-host and stand-down markers. Checksums, inbox inventory and persisted metadata demonstrated that rejected authority operations did not mutate the request or clean up the old task. Waiting returned 75. Cancellation removed the request and queued the resume instruction.

## Not established
A scout model completing quiescence then a fresh model completing its report, and a ship continuation preserving both halves in an actual PR, were not established. The normal login exists; the blocker is the consent/trust configuration boundary, not missing credentials. The print-mode alternative still enters Firstmate's user-level Claude trust pre-registration. A permitted pre-consented harness environment is needed. The ship PR proof additionally needs an explicitly authorized disposable forge repository/publication destination; a local bare origin is not an actual PR consumer.

## Cleanup
Stopped the private tmux server; enumerated descendants of its pane PIDs before shutdown and confirmed no owned pane/child processes survived. Removed the disposable lab, repository, pool and socket directory. Product-created read-only hook directories required local chmod before removal. No intentional source/test changes remain. No linter, formatter, full test suite, pipeline control, push, PR or CI phase was run. This is a CLI tooling change; evidence is CLI transcripts rather than screenshots.
