# Local validation result

Verdict: inconclusive. No source changes were made. All disposable homes, sockets, selected-test copies, and fixture data were removed. No owned background processes remained. No upstream contribution or forge write was attempted.

## Executed product surfaces

- The real `fm-stow-guard.sh` consumed synthetic Claude Stop payloads and usage transcripts in a disposable plain checkout. Absent opt-in was inert; 310000 tokens requested `/stow`; repeated crossing was silent; falling to 100000 tokens rearmed the next crossing; an old stow requested a fresh pass with throttling. Grok markers, Cursor payloads, and linked-task-worktree scope remained inert. See `local-product-transcript.md`.
- Installed Claude Code 2.1.322, using its existing login, ran interactively in a 140x45 pane on the marked home's private `fm-lab` tmux socket. It executed `bin/fm-lock.sh; bin/fm-lock.sh status` and replied `LAB_LOCK_DONE`. The recorded dead owner 9999999 became 71329; both stale primary and steal directories disappeared. See `primary-transcript.md`, `primary-lock-state.json`, and the captured TUI rendered as `primary-screen.html`. The initial trust dialog selected exit; the corrected launch selected the disposable workspace and succeeded. The private server was stopped and the home removed in the same command.
- The actual host's probes drove `fm-capacity.sh`, `--json`, and `--publish`, then `fm-placement.sh disposable --local-dir <disposable-checkout>`. The measured adaptive report published target 3 / status ok and selected the local machine. This is local-host validation, not real worker-host/SSH validation.

## Targeted supporting checks (not live product scenarios)

The initial concurrent supporting command ran stow, Claude autoarm, capacity, placement, teardown, and PR-merge test files. Its 600-second command bound expired before the aggregate result was retained. Complete-looking logs are not claimed as known exit statuses. Teardown's export fixture was rejected because the initial TMPDIR was inside the effective project root. No product repair was needed: subsequent fixtures were placed under the explicitly permitted evidence directory, outside the project root.

Focused selector runs then retained exit 0 for stow guard; adaptive placement (including fake SSH and unavailable-budget rejection); expected-head matching/mismatch/race/malformed-input guards; stale-directory recovery, live-owner preservation and named permission refusal; routed-worker lane exclusions and real-host capacity smoke; record-export ordering and teardown stale-ref refresh, failed-refresh refusal, and unlanded-work refusal. `focused-results.json` retains statuses and selectors. The second broad placement invocation exceeded its 165-second bound and its entire process group was stopped; the requested adaptive-placement selector subsequently completed with exit 0. No broad-suite completion is claimed.

## Remaining acceptance gaps

- Continued-session Stop auto-arm takeover and real API-error StopFailure recovery remain untested live. The permitted real primary launch worked, but the required gate checkout is a linked worktree, which intentionally fails the genuine-primary scope predicate for these hooks. The synthetic behavior suite is supporting evidence only. A real launch from a disposable plain checkout requires additional authorization under the supplied runbook; no fake CLI or login was substituted.
- Real GitHub-backed registration/review parking/expected-head merge/cleanup remains untested. Local disposable Git remotes and scripted forge-boundary regressions were exercised, but they do not establish an authenticated GitHub lifecycle. No authorized throwaway GitHub repository/account was supplied; the fork and upstream are not safe mutation targets. A local Forgejo service would not establish the required GitHub account-routing contract. Provide an authorized disposable GitHub repository and permission to drive its lifecycle to complete this check.

These evidence gaps were already declined as findings in earlier runs; they are recorded as untested scenarios rather than raised again. Existing declined product policies and tests were not changed.
