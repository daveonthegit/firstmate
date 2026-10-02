---
name: firstmate-vault
description: >-
  Agent-only contract for the captain's opt-in Obsidian vault: the long-term work journal, career archive, dated decision record, and domain notes firstmate keeps outside its own memory.
  Load when `bin/fm-vault.sh path` succeeds and you are about to record a captain decision or durable domain knowledge in the vault, rerun or repair a journal export, or answer from the vault: resume, CV, portfolio, or interview-preparation work, or a question about what was done or decided in the past beyond the backlog's recent Done history.
user-invocable: false
metadata:
  internal: true
---

# firstmate-vault

The vault is the captain's, not firstmate's.
It is a human-readable archive of finished work and decisions that outlives the backlog's short Done history; firstmate's operating memory stays in `data/captain.md`, `data/learnings.md`, and the backlog, and firstmate never reads the vault to operate the fleet.
The feature is on only when this home's `config/obsidian-vault` names the vault; `bin/fm-vault.sh path` prints it or exits 1, and every other part of this skill is moot when it exits 1.
`docs/configuration.md` "Obsidian vault journal" owns the configuration, and `bin/fm-vault.sh`'s header owns the note layout, write safety, redaction, git opt-in, and fail-open mechanics.

## What lives where

Firstmate writes only under the vault's `Journal/` folder.
Everything else in the vault - its root `README.md` contract, `Me.md`, `Career/`, `Work/`, `Domain/`, `Index/` - is the captain's, and firstmate changes it only on a concrete captain request for that change.
Inside `Journal/`, write below a note's `fm-journal:generated` marker, or outside a hub's begin and end markers, never above or inside them; regeneration replaces that text.

Keep one owner per fact:

- Knowledge a worker needs while coding stays in that project's own `AGENTS.md`, `docs/`, or ADRs; the vault's project hub links it and never restates it.
- Fleet memory and captain operating preferences stay in `data/`; the vault never mirrors them.
- Work-item state stays in the backlog; scout reports stay in `data/<id>/report.md` and the vault indexes their paths.
- A captain decision's canonical text stays in its backlog hold or the repo ADR that embodies it; the vault keeps a dated record that links it.
  When the canonical source changes, set the old vault note's `status: superseded` and `superseded_by:` link and record the new decision; never rewrite history into a second truth.
- Cross-project business or domain knowledge with no repo home (vendor quirks, compliance rules, partner integration behaviour) goes in a captain-reviewable note under `Journal/Domain/`, generalised where confidential.

## When to write

- **Task close.** Teardown runs `fm-vault.sh journal <id>` itself after a successful cleanup; do nothing extra.
  If it printed an `fm-vault:` line, report the concrete problem to the captain only when it repeats or needs their action (an unreachable vault path, a refused commit), then rerun `fm-vault.sh journal <id>` once it is fixed; a rerun without metadata keeps every value the earlier note recorded.
- **Captain decisions.** A decision closed through `bin/fm-decision-hold.sh` reaches the vault with its origin task's journal export when the origin metadata lists its key.
  For a decision that closed after its origin was already journaled, or one recorded only in a file, run `fm-vault.sh decision <origin> <key>` (with `--decision-file <path>` when the backlog hold does not hold the text).
- **Domain knowledge.** When work under way teaches durable cross-project domain knowledge with no repo home, write or update one `Journal/Domain/<topic>.md` note with dated, sourced facts and links to the reports that hold the evidence, then tell the captain in one line that it was recorded.
- **Never** write secrets, credentials, personal data, anything derived from private mail, revenue or partner commercial terms, or licensed material; the script redacts common shapes, but you are the first filter.

## When to read

Read the vault, not the backlog or chat memory, for:

- resume, CV, cover-letter, portfolio, or career-ops work: query task notes by `skills`, `employer`, and `closed`, or read `Journal/Skills/<skill>.md`; use only `review: captain-reviewed` notes for anything printed and only `metrics: evidenced` numbers; cite the note `id` behind every bullet.
- interview preparation: read the STAR summary, hard-parts, and role sections of the relevant task notes; keep the captain-versus-AI-worker attribution honest.
- "what did we decide or do about X" beyond the recent Done history: read `Journal/Decisions/`, the project hub, and the month notes, then follow their links to the canonical report, hold, or ADR before answering.

A draft note is a lead to verify, not a fact to repeat; check its linked PR or report before relying on it.
The captain's own `Career/` and `Domain/` notes are authoritative for their content.
