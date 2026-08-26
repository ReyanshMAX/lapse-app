# LOOP.md — unattended build-loop protocol

This file defines **how** an unattended loop operates on this repo. It contains
no task-specific instructions — no phase content, no "build TimeAxis next." The
scope of any given loop run is supplied at kickoff, each time, by whoever starts
it. This file only governs process: orientation, the work/commit/verify cycle,
failure handling, boundaries, and when to stop.

Read this file whenever a session is told to "work in a loop" or "follow
LOOP.md." Everything else — CLAUDE.md, STATUS.md, BUILD.md, DECISIONS.md,
OPEN_QUESTIONS.md — still applies exactly as normal; this file adds process on
top, it doesn't replace the standing rules.

---

## Mechanism

Unattended runs use `loop.ps1`, a persistent PowerShell wrapper on the
developer's own machine — not a session-local `/loop`, not cloud cron. The
wrapper has no model calls in it: it just shells out to `claude -p` (headless,
non-interactive) with a fixed scope prompt, waits for it to exit, sleeps, and
repeats. Because the trigger itself is dumb infrastructure external to any one
Claude session, a session dying mid-work — usage limit, crash, whatever —
can't take the loop down with it. The next cycle is a fresh `claude -p`
process regardless of how the last one ended.

**Usage limits specifically:** the wrapper doesn't try to detect or parse a
usage-limit error. Any failed cycle — limit, transient network blip, a real
bug — triggers the same response: back off (starting at 30 minutes, doubling,
capped at 2 hours) and try again. This is safe because every cycle is a cold
start that re-reads STATUS.md and picks up wherever the repo actually is; a
retry during a still-active limit just fails fast and backs off further, and
a retry after the limit resets just works.

**Consequence:** every cycle is a cold start with zero memory of any previous
cycle — there is no session persisting between them, on this machine or
anywhere else. All state that matters must live in the repo: STATUS.md, git
history, OPEN_QUESTIONS.md. The orientation step below exists because of this.

**Default cadence:** every 20 minutes between successful cycles (CI round
trips run 5–10 minutes per docs/SETUP.md), with the failure backoff above
taking over after a failed cycle. Both are `loop.ps1` parameters.

**The loop runs only while `loop.ps1` runs.** Unlike cloud cron there's no
independent scheduler behind it — closing the terminal, sleeping the machine,
or a reboot stops it, and nothing restarts it automatically. This is the
tradeoff for not using cloud: fine for a machine that's just going to sit on
overnight, not fine for a machine that sleeps or that Windows Update reboots.

### Before first use — verify once, don't assume

- The repo must be **public** — confirmed (`ReyanshMAX/lapse-app`, PUBLIC).
  D-027: a private repo bills macOS runner minutes at 10×, which makes
  unattended overnight runs non-viable.
- Set the machine's power plan to never sleep (at least while plugged in) for
  the duration of any overnight run — `loop.ps1` cannot survive a sleep cycle.
- `--permission-mode dontAsk` has to actually cover everything a work cycle
  needs, since a headless `-p` process has no one to answer a permission
  prompt — it would just hang until `-TimeoutMinutes` kills it, burning a
  whole cycle for nothing. Run one short, low-stakes scope first and watch
  `loop.log` before trusting a scope to run all night unsupervised.

---

## Cold-start orientation (every cycle, no exceptions)

1. CLAUDE.md — standing rules, environment constraints. Always in force.
2. STATUS.md — current phase, in-progress checklist, blocked list, and any
   "Needs developer verification" section.
3. BUILD.md — acceptance criteria for the phase(s) in scope, and their
   `[ci]` / `[device]` / `[eyes-on]` tags.
4. The **scope line** in this cycle's own prompt (see Kickoff below) — the
   only source of what to work on this cycle. This file never decides scope,
   narrows it, or expands it.

## Overlap guard

Before picking any new work: `gh run list`. If the most recent run from a prior
push is still in progress, `gh run watch` it to completion first. Cycles are
independent and don't know about each other — don't start parallel work on top
of a run still in flight.

## Unit of work

One unchecked line from STATUS.md's in-progress checklist (or, if the
checklist hasn't caught up yet, one `[ci]` acceptance criterion from BUILD.md)
= one commit. Small and focused, one concern per commit, per CLAUDE.md's
commit guidance. Commits go **directly to main** — no branches, no PRs. This
matches how SETUP.md already describes the push/CI loop for this repo.

## Build and verify

1. Implement the unit of work.
2. Commit, push.
3. `gh run watch`.
4. Green → go to STATUS.md discipline, below.
5. Red → CI failure handling, below.

## CI failure handling — delegate the log, not just read it

On a red run, don't pull `gh run view --log-failed` into this session's own
context. Dispatch a fresh subagent to do the whole cycle:

- fetch the failing log (`gh run view --log-failed`)
- diagnose the failure
- fix it in the working tree
- commit and push the fix
- report back a short summary only (what broke, what changed, the commit)

This keeps raw log output out of the main session's context, so one cycle can
survive several fix/iterate rounds instead of drowning in log text after the
first failure. After the subagent reports back, `gh run watch` the new push.

**Three strikes:** if the same unit of work is still red after 3 consecutive
pushes, stop iterating on it. Record in STATUS.md what was tried and what was
ruled out, then move to the next unblocked item in scope. Don't burn a whole
cycle on one stuck item.

## Boundaries — hold every cycle, no exceptions

- **Never compile locally.** No `xcodebuild`, `swift`, `xcrun`, `xcodegen`, or
  `brew` in-session — they don't exist in this environment. CI is the only
  compiler (CLAUDE.md environment note).
- **Never check off a `[device]` or `[eyes-on]` criterion.** Add it to
  STATUS.md's "Needs developer verification" section instead, with exactly
  what to look for.
- **Never move a phase to STATUS.md's Done section** while any of its BUILD.md
  acceptance criteria are `[device]`/`[eyes-on]` — even once every `[ci]` item
  is green. Leave it in "In progress" with a note that only developer
  verification remains.
- **Never step outside the scope given at kickoff**, even if that scope
  finishes clean and a later phase looks unblocked. Scope is decided by
  whoever kicks off the loop, not by this file or by the session running it.
- **Never invent unspecified behavior** (CLAUDE.md standing rule 3). If a
  requirement is missing, ambiguous, or contradicts another doc: add an entry
  to OPEN_QUESTIONS.md following its existing format (`## Q-NNN: <title>` with
  Blocking / Options / Depends-on-it), then move to the next unblocked item in
  scope. Only end the cycle entirely if nothing else in scope is unblocked.
- **Never relitigate DECISIONS.md** (standing rule 4).

## STATUS.md discipline

- Check a box only after the run that proves it green — never in anticipation
  of one.
- "Next action" must always be specific enough for a cold session to resume
  from — the next cycle has no memory of this one.
- Commit STATUS.md updates as their own commit whenever: an item completes,
  an item gets parked (three strikes), something becomes blocked, or a
  phase-level note changes.

## Stopping / self-termination

The current loop scope is over when either is true:

- **(a) Done** — every item in the requested scope is checked and green.
- **(b) Stuck** — everything remaining in scope is blocked: by
  `[device]`/`[eyes-on]` verification, by an open question with no unblocked
  alternative left in scope, or by three-strikes exhaustion across everything
  that was unblocked.

When either is true:

1. Write a clear summary to STATUS.md: what's done, what's waiting on the
   developer, what's blocked and why.
2. Create a file named `.loop-stop` in the repo root, containing a one-line
   reason (e.g. `Phase 0 complete, all remaining Phase 1 items are [device]`).
   `loop.ps1` checks for this file after every cycle and exits when it finds
   one — this is the local equivalent of deleting a cron job. This file is
   gitignored; it's a signal to the wrapper script on this machine, not repo
   state, and must never be committed.
3. End the turn without picking new scope. Starting the next phase is a
   decision for whoever kicks off the next loop, not for this one.

---

## Kickoff — how a new loop scope gets started

Not something this file does to itself — run once, by a live session or by
you, each time a new scope should start running unattended. From the repo
root, in PowerShell:

```powershell
.\loop.ps1 -Scope "<phase/task>"
```

That's it — `loop.ps1` builds the `Follow LOOP.md. Scope for this loop:
<phase/task>.` prompt itself and re-sends it verbatim every cycle, so the
scope doesn't need to be recorded anywhere else. Progress lives in STATUS.md
and git; `loop.log` in the repo root (gitignored) has a timestamped record of
every cycle for the morning read-through.
