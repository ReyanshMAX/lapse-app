# SETUP.md — build and deploy workflow (Windows → SSH → shared Mac → iPhone)

## Overview

Two environments, used in sequence.

**Interim (no Mac access).** Builds and tests run on GitHub Actions macOS
runners. CI compiles the app target for the simulator and runs the
`StudyLapseCore` test suite. It cannot sign for a device, cannot install to a
phone, and has no camera. This is enough to prove all of Phase 0 and to keep
later phases compiling, and nothing more.

**Primary (Mac access restored).** The developer works from Windows and SSHes
into a shared macOS machine. Xcode's GUI is available only in limited windows;
SSH works concurrently with the other user's session. Prefer command-line builds
and installs, and batch anything requiring the Xcode GUI.

## Non-goals

- No Fastlane
- No TestFlight during the build phase (requires the paid developer program)
- No signed device builds in CI — free provisioning cannot be automated, so CI
  never produces an installable artifact
- Do not attempt to build on Windows — there is no Swift toolchain, no Xcode, no
  iOS SDK, and no simulator. `xcodebuild`, `swift build`, `swift test`, `xcrun`,
  `xcodegen`, and `brew` all fail. Push and read CI instead

## Interim: GitHub Actions builds

### Project generation

`StudyLapse.xcodeproj` is **generated, not committed** (D-025). The source of
truth is `project.yml` at the repo root, edited by hand from Windows. Every CI
job regenerates the project before building.

```yaml
name: StudyLapse
options:
  bundleIdPrefix: com.placeholder          # rewritten by the sideloader; see Q-001
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
packages:
  StudyLapseCore:
    path: StudyLapseCore
targets:
  StudyLapse:
    type: application
    platform: iOS
    sources:
      - path: StudyLapse
        excludes:
          - Info.plist
      # Crosses the app/widget-extension process boundary — compiled into
      # both targets from this one file rather than a separate framework
      # (docs/ARCHITECTURE.md non-goals).
      - path: StudyLapseActivity/StudyLapseActivityAttributes.swift
    dependencies:
      - package: StudyLapseCore
      - target: StudyLapseActivity
        embed: true
    scheme:
      testTargets:
        - StudyLapseTests
    settings:
      base:
        PRODUCT_NAME: StudyLapse
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        INFOPLIST_FILE: StudyLapse/Info.plist
  StudyLapseTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: StudyLapseTests
    dependencies:
      - target: StudyLapse
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
  # Live Activity widget extension (docs/UI.md "Live Activity"; BUILD.md
  # Phase 7) — a second bundle ID, so it stayed out of scope until Phase 7
  # (three-app free-ID limit, below).
  StudyLapseActivity:
    type: app-extension
    platform: iOS
    sources:
      - path: StudyLapseActivity
        excludes:
          - Info.plist
    dependencies:
      - package: StudyLapseCore
    settings:
      base:
        PRODUCT_NAME: StudyLapseActivity
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        INFOPLIST_FILE: StudyLapseActivity/Info.plist
        SKIP_INSTALL: YES
        TARGETED_DEVICE_FAMILY: "1"
        # Must be the parent app's bundle ID, prefixed — XcodeGen's default
        # per-target ID (bundleIdPrefix.TargetName) gives siblings, which
        # both the simulator and a real install refuse ("Mismatched bundle
        # IDs").
        PRODUCT_BUNDLE_IDENTIFIER: com.placeholder.StudyLapse.StudyLapseActivity
```

`StudyLapse` moved from `GENERATE_INFOPLIST_FILE: YES` (build-setting-synthesized) to a
checked-in `Info.plist` + `INFOPLIST_FILE` in Phase 7 — `CFBundleURLTypes` (the Resume deep
link) and `NSSupportsLiveActivities` are an array/boolean that a build-setting-only Info.plist
can't express (XcodeGen's `info.properties` merge needs an explicit `info.path`, which turns
into the same checked-in-file approach anyway — simpler to do it directly). `StudyLapseTests`
and the new `StudyLapseActivity` extension still use `GENERATE_INFOPLIST_FILE: YES` /
`INFOPLIST_FILE`; the `excludes: [Info.plist]` on each target's `sources` keeps the checked-in
file from *also* being picked up as a bundle resource by the normal directory glob.

`StudyLapseTests` is a minimal placeholder XCTest target so the `StudyLapse` scheme's test
action is non-empty (see "Simulator tests" below); real simulator-level tests land here in
later phases per the repo structure table in CLAUDE.md. The `scheme.testTargets` entry wires
it into the `StudyLapse` scheme's test action explicitly — XcodeGen does not always infer this
automatically, so don't rely on the default.

Every CI job runs this first:

```yaml
      - name: Generate project
        run: |
          brew install xcodegen
          xcodegen generate
```

Never hand-edit the generated `.xcodeproj`; it is git-ignored and regenerated on
every build. Add files by adding them to disk under `StudyLapse/` — XcodeGen
picks them up from the `sources` path automatically.


`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
  pull_request:
  workflow_dispatch:

jobs:
  core:
    name: StudyLapseCore tests
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Show toolchain
        run: swift --version && ls /Applications | grep Xcode
      - name: Test
        run: swift test --package-path StudyLapseCore

  simulator:
    name: Simulator tests
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Generate project
        run: |
          brew install xcodegen
          xcodegen generate
      - name: Test
        run: |
          xcodebuild \
            -project StudyLapse.xcodeproj \
            -scheme StudyLapse \
            -destination 'platform=iOS Simulator,name=iPhone 17' \
            CODE_SIGNING_ALLOWED=NO \
            test

  app:
    name: App target compiles
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Generate project
        run: |
          brew install xcodegen
          xcodegen generate
      - name: Build for simulator (unsigned)
        run: |
          xcodebuild \
            -project StudyLapse.xcodeproj \
            -scheme StudyLapse \
            -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath build \
            CODE_SIGNING_ALLOWED=NO \
            build
```

Notes on this workflow:

- Runner images move. Do not hardcode an Xcode path or a simulator device name
  without first checking the `Show toolchain` output — if the named simulator
  does not exist on the image, use
  `-destination 'generic/platform=iOS Simulator'` instead. This works for a
  plain `build` action (no concrete device needed to compile), but **not**
  for a `test` action — running tests requires a real bootable simulator, so
  the `simulator` job's `test` step must always name a device that actually
  exists on the current runner image (check `Show toolchain` / the
  "Available destinations" list in a failed run's log).
- `CODE_SIGNING_ALLOWED=NO` is what makes an unsigned build possible. Do not add
  signing secrets to CI: free provisioning is device-specific and issued through
  the Xcode GUI, so it cannot be reproduced on a runner.
- **The repository must be public** (D-027). macOS runner minutes bill at 10× on
  private repos, so the free tier yields roughly 200 macOS minutes per month —
  fewer than 30 runs, which one unattended session will consume before morning.
  Public repositories have unlimited free Actions minutes. If the repo must stay
  private, unattended overnight runs are not viable and CI should be restricted
  to `workflow_dispatch` plus pushes to `main`.
- The `core` job is the one that matters during Phase 0. The `app` job exists to
  catch compile errors in camera and export code that cannot be run anywhere yet.

### Producing a sideloadable build

CI cannot sign for a device, but it can produce an **unsigned .ipa** that a
free-Apple-ID sideloader signs on Windows. Add to `ci.yml`:

```yaml
  ipa:
    name: Unsigned IPA artifact
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Generate project
        run: |
          brew install xcodegen
          xcodegen generate
      - name: Archive unsigned
        run: |
          xcodebuild \
            -project StudyLapse.xcodeproj \
            -scheme StudyLapse \
            -configuration Debug \
            -destination 'generic/platform=iOS' \
            -archivePath build/StudyLapse.xcarchive \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" \
            archive
      - name: Package .ipa
        run: |
          mkdir -p Payload
          cp -R build/StudyLapse.xcarchive/Products/Applications/StudyLapse.app Payload/
          zip -qry StudyLapse.ipa Payload
      - uses: actions/upload-artifact@v4
        with:
          name: StudyLapse-unsigned-ipa
          path: StudyLapse.ipa
```

On Windows: download the artifact, unzip to get `StudyLapse.ipa`, and install it
with **Sideloadly** or **AltStore/AltServer** using the developer's free Apple
ID. Both require Apple's mobile device drivers — follow the tool's own
installation docs, since which iTunes/iCloud build is required has changed over
time and the Microsoft Store versions are not always the right ones.

The sideloader rewrites the bundle identifier and re-signs, so Q-001 still does
not block this path.

### Reading CI results from Windows

The agent cannot compile anything locally, so CI logs are the only compiler
feedback available. Use the GitHub CLI:

```bash
gh auth login                                 # once
gh run watch                                  # follow the current run
gh run view --log-failed                      # failing steps only
gh run view <run-id> --job <job-id> --log     # full log for one job
gh run download -n StudyLapse-unsigned-ipa    # fetch the sideloadable artifact
gh run rerun --failed                         # retry after a flaky runner
```

Push small and often. A 5–10 minute CI round trip punishes large speculative
changes: one focused commit whose failure mode is obvious beats five files
changed at once.

### Constraints of the sideload loop

- **Certificates expire after 7 days.** The app stops launching with no code
  change — re-sideload. AltStore can refresh automatically over wifi if AltServer
  is running; Sideloadly is manual.
- **Three apps per free Apple ID**, and a weekly cap on new app IDs. A widget
  extension is a second bundle ID and counts against these — another reason the
  Live Activity work stays in Phase 7.
- **No entitlements requiring the paid program**: App Groups, push, CloudKit.
  Nothing in Phases 0–6 needs them.
- **No debugger and no console.** `os_log` output is unreadable without a Mac, and
  `lldb` is unavailable. Anything that needs observing must be visible in the app
  itself — see the debug log requirement in BUILD.md Phase 1.
- Loop time is roughly 5–10 minutes of CI plus a minute or two to sideload. Fine
  for "does this work at all", poor for tuning frame timing.



Three capability tiers exist during the no-Mac period:

| Tier | Available now | Proves |
|---|---|---|
| `[ci]` | yes | `StudyLapseCore` logic, that the app target compiles, SwiftData models build |
| `[device]` | yes, via unsigned IPA + sideload | camera capture, clip files, export output, persistence on real hardware |
| `[eyes-on]` | yes, same path | framing, overlay legibility, exposure strobing, anything visual |

What remains genuinely blocked until Mac access returns:

- Xcode's debugger, view hierarchy inspector, and Instruments
- `os_log` console streaming (`xcrun devicectl --console`)
- Anything needing App Groups, push, or CloudKit entitlements
- Thermal and energy profiling on long captures

Do not mark a `[device]` or `[eyes-on]` criterion complete on the strength of a
green CI run — it must be verified on the sideloaded build.

## One-time setup (requires the Xcode GUI)

Batch these into a single GUI session:

1. Log into the developer's own macOS user account graphically at least once.
2. Install Xcode; launch it once and accept the license
   (`sudo xcodebuild -license accept`).
3. Xcode → Settings → Accounts → add the developer's personal Apple ID. This is
   independent of the Mac's iCloud sign-in.
4. Select the personal team on the app target. Free provisioning signs to the
   developer's own device; certificates expire after 7 days, so re-deploy weekly.
5. Connect the iPhone by cable, trust the pairing, then Window → Devices and
   Simulators → enable **Connect via Network**. After this the phone deploys over
   the LAN and the cable is unnecessary.
6. Enable Remote Login: System Settings → General → Sharing → Remote Login.

## Per-session SSH preamble

Codesigning reads the login keychain, which is locked or unattended over SSH.
Run at the start of each session:

```bash
security unlock-keychain -p "$MAC_LOGIN_PASSWORD" ~/Library/Keychains/login.keychain-db
```

Run once, after the signing identity first exists, so `codesign` stops prompting:

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$MAC_LOGIN_PASSWORD" ~/Library/Keychains/login.keychain-db
```

## Build

```bash
# Debug build for a connected/paired device
xcodebuild -project StudyLapse.xcodeproj \
           -scheme StudyLapse \
           -configuration Debug \
           -destination 'generic/platform=iOS' \
           -derivedDataPath build \
           build
```

```bash
# Unit tests — StudyLapseCore only, runs on the simulator, no device needed
xcodebuild -project StudyLapse.xcodeproj \
           -scheme StudyLapseCoreTests \
           -destination 'platform=iOS Simulator,name=iPhone 15' \
           test
```

The simulator has **no camera**, so anything in `Capture/` cannot be verified
there. Simulator runs are for `StudyLapseCore`, tag-range math, and non-camera UI
only.

## Deploy to device

```bash
xcrun devicectl list devices                      # find the device identifier
xcrun devicectl device install app \
      --device <DEVICE_ID> \
      build/Build/Products/Debug-iphoneos/StudyLapse.app
xcrun devicectl device process launch \
      --device <DEVICE_ID> \
      com.<developer>.studylapse
```

Streaming logs without Xcode:

```bash
xcrun devicectl device process launch --console \
      --device <DEVICE_ID> com.<developer>.studylapse
```

Use `os_log` with a dedicated subsystem (`com.<developer>.studylapse`) and
categories per module so console output is filterable.

## What still requires the GUI

Batch into the limited exclusive-access windows:

- Initial device pairing and trust
- Signing, capabilities, and entitlement changes
- Instruments profiling (thermal, energy, memory during long captures)
- Anything needing the view hierarchy debugger

## Loop shape

Claude Code runs on the Mac over SSH and owns the build/error/fix cycle. It
cannot see the phone. Visual verification — framing guide alignment, overlay
legibility at speed, live preview quality, exported video quality — is the
developer's job with the device in hand. Acceptance criteria in BUILD.md are
written to distinguish machine-checkable from eyes-on criteria.

## Notes

- Commit and push constantly. The working tree lives on a machine the developer
  does not control.
- Long builds spin the fans on a shared machine. Avoid unattended builds while
  the other user is working.
- Free provisioning caps at 3 apps per device and re-signing every 7 days. If the
  app stops launching with no code change, that is the certificate expiring —
  rebuild and reinstall.
- App Groups, push, and CloudKit all require the paid program (OPEN_QUESTIONS.md
  Q-004). Do not add capabilities that need it without checking first.
