# T3 compatibility live validation

Disposable official T3 0.1.5 and 0.1.0 CLI releases were installed inside `.t3-validation`, with separate loopback servers on ports 18379 and 18380, separate data directories, telemetry disabled, and disposable OAuth credentials. No production T3 server, credentials, login, or model turns were used. Both servers and their downloaded runtime/data were removed after validation.

## Live product evidence

- `t3-0.1.5-live.log`: real current tool family gate; live values-array catalog; accepted high effort; refused invalid effort; preservation of a boolean false project default alongside effort; idle thread launch with configuration read-back; empty pending-question list; typed refusal when responding to a nonexistent question; archive read-back; mismatched environment refusal.
- `t3-0.1.0-live.log`: same operations against earlier tool families (dedicated configuration read and split pending-request tools).
- `baseline-refusal.log`: the base commit adapter's `status` against the same disposable 0.1.5 server exits 4 because it requires obsolete tools. The target adapter succeeds against that server.
- `codex-worker-path-live.log`: real Codex 0.166.0 app-server starts with its toolchain PATH stripped (only a private node bootstrap link remains). A command executes using Firstmate's generated per-project configuration and resolves node from the spawning session's actual nvm directory, not the bootstrap directory. Thread transport in this focused spawn test is fake; Codex configuration consumption and command execution are real. This does not claim a model turn or a T3-hosted agent turn.
- `live-guard.log`: existing token-free live guard passed against disposable 0.1.5.

## Targeted checks and retries

`TMPDIR="$PWD/.t3-validation/tmp" bash tests/fm-t3-mcp.test.sh` passed, including incomplete-family refusals, mixed-generation preference, successful question response fixtures, and values-array validation.

`TMPDIR="$PWD/.t3-validation/tmp" bash tests/fm-backend-t3code.test.sh` initially hit the legitimate restriction that a secondmate home cannot be inside the Firstmate repository. Re-running with the test runner's normal ephemeral fixture location passed (`backend-targeted-tests-rerun.log`).

The new stripped-PATH test initially prevented the npm Codex launcher's own node bootstrap; supplying a private bootstrap node link corrected the fixture without restoring the worker's toolchain PATH. An expanded backend re-run then demonstrated the PATH proof but exceeded the 240-second command limit later during unrelated teardown checks. No product failure was shown by that timeout. The changed selector was subsequently run independently and passed:

- `FM_TEST_ONLY=test_spawn_codex_preserves_tracked_codex_config bash tests/fm-backend-t3code.test.sh`
- `FM_TEST_ONLY=test_spawn_leases_slot_creates_thread_and_starts_launch_turn bash tests/fm-backend-t3code.test.sh`
- `FM_TEST_ONLY=test_spawn_codex_warns_unless_codex_trusts_the_project bash tests/fm-backend-t3code.test.sh`

The latter two use fake T3 transport and verify emitted Claude/Codex configuration, including account-shim ordering and unpinned PATH. They are supporting tests, not live T3-hosted agent-turn evidence. There is no UI-facing change, so no screenshot was required. No complete repository suite, linter, formatter, pipeline control, push, or PR phase was run.
