# Status

**Last updated:** 2026-08-24
**Current phase:** 0 of 9 — Core logic, provable without a Mac
**Next action:** Scaffold the repo — `.gitignore`, `project.yml`, the placeholder
app target, and `.github/workflows/ci.yml` per docs/SETUP.md — then get all three
CI jobs green and sideload the resulting .ipa to confirm the delivery pipeline
end to end before writing real code.

**Environment:** No Mac access for approximately one week. Builds run on GitHub
Actions macOS runners; the `ipa` job produces an unsigned .ipa that is signed
with a free Apple ID and sideloaded from Windows, so `[device]` and `[eyes-on]`
criteria remain reachable. What is unavailable is the Xcode debugger, `os_log`
console streaming, Instruments, and any paid-program entitlement. A green CI run
still never satisfies a `[device]` or `[eyes-on]` criterion — verify on the
sideloaded build.

---

## Done

Nothing yet. Spec suite generated 2026-08-24.

## In progress

- **Phase 0 — Core logic, provable without a Mac**
  - [ ] Repo layout, `.gitignore`, `project.yml`
  - [ ] `.github/workflows/ci.yml` with the `core`, `app`, and `ipa` jobs
  - [ ] Placeholder app target that builds, archives, and sideloads
  - [ ] `StudyLapseCore` package skeleton, Foundation-only
  - [ ] `TimeAxis` — study/output conversions, speed, minimum-speed floor
  - [ ] `DayBoundary` — `dayKey`, `closeDeadline`
  - [ ] `TagRangeMath` — seed, split, merge, resize, validate
  - [ ] `Formatters` — `H:MM` and `MM:SS`
  - [ ] Property test over random tag-range operation sequences (≥1000 cases)
  - [ ] CI grep step asserting no SwiftData/AVFoundation/SwiftUI/UIKit imports

## Next up

1. Finish Phase 0 and keep CI green
2. Phase 1 — one clip captured and played back, via the sideloaded .ipa
3. Phase 2 — multi-clip session, SwiftData, recovery

## Blocked

- **Q-004** paid developer program enrolment — no phase blocker until Phase 8,
  but it has real lead time. Raise it now.

Not blocking, but constraining while there is no Mac:

- No debugger, no console — rely on the Phase 1 on-device debug log (D-024)
- Free-ID certificates expire every 7 days; re-sideload when the app stops
  launching with no code change
- Three apps per free Apple ID, so hold off on the widget extension until Phase 7
- **Q-001** app name and bundle identifier — does not block Phase 0 or the
  sideload path (the sideloader rewrites the bundle ID), but must be settled
  before real provisioning is set up on a Mac

## Deviations from spec

None.

---

## Update protocol

Write to this file when any of these happen:

- A phase completes — move it to Done with the date and note any deviations
- A phase's individual criterion completes — check the box
- Work stops mid-phase — update **Next action** to the specific next step, not a
  vague area. "Implement `TagRangeMath.resize` per Phase 0 criterion 5" is
  resumable; "continue on core" is not
- Something becomes blocked — add it to Blocked with the question ID
- Implementation diverges from a spec doc — log it under Deviations *and* update
  the spec doc itself (standing rule 2)

**Next action** is the highest-value field. It should always be specific enough
to start typing from.

**Do not check off a `[device]` or `[eyes-on]` criterion on the strength of a
green CI run.** See the capability table in docs/SETUP.md.

**Nothing compiles locally.** The dev machine is Windows with no Swift toolchain.
Verify by pushing and reading the run with `gh run watch` / `gh run view
--log-failed`.
