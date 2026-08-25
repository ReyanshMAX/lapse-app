# TESTING.md — what is verifiable without a camera, and how

## Overview

The developer has no Mac and no debugger; CI is the only compiler and the only
test runner. This document exists so that "works" means something checkable in CI
rather than "compiled and looked plausible." The central technique is to keep
real hardware at the outermost edge of the system, so everything inside it can be
driven by synthetic input on a simulator.

Three tiers, matching the BUILD.md criteria tags:

| Tier | Runs on | Covers |
|---|---|---|
| `[ci]` unit | macOS runner, `swift test` | `StudyLapseCore` — pure logic, no Apple frameworks |
| `[ci]` simulator | macOS runner, `xcodebuild test` | SwiftData, session lifecycle, recovery, the entire export pipeline, view models |
| `[device]` / `[eyes-on]` | sideloaded build, developer holding the phone | `AVCaptureSession` configuration and real camera behaviour only |

The goal is to make the third tier as small as possible.

## Non-goals

- No UI tests (XCUITest) in v1 — slow, flaky, and they would not run unattended
- No snapshot-image testing of SwiftUI views
- No mocking framework — hand-written test doubles only
- No code coverage targets

## Making capture testable: the frame source seam

`AVCaptureSession` cannot run on a simulator. Do **not** let that fact leak into
the frame-gating, chunking, or writing logic. Split the capture pipeline at a
protocol:

```swift
/// The only type that touches AVCaptureSession. Untestable in CI by design —
/// keep it thin and free of logic.
protocol FrameSource: AnyObject {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)? { get set }
    func start() throws
    func stop()
}

final class CameraFrameSource: FrameSource   // real device only
final class SyntheticFrameSource: FrameSource // CI: emits generated buffers
```

Everything downstream — interval gating, `frameIndex` assignment, timestamp
synthesis, chunk rollover at 120s/1000 frames, `AVAssetWriter` handling,
`Clip` persistence, `studyOffsetStart` recomputation — consumes `FrameSource` and
is therefore fully testable in CI.

`SyntheticFrameSource` generates solid-colour or gradient `CVPixelBuffer`s at a
caller-specified virtual rate, with a controllable clock so a simulated nine-hour
session runs in under a second:

```swift
final class SyntheticFrameSource: FrameSource {
    init(size: CGSize, virtualFrameRate: Double, clock: VirtualClock)
    func emit(seconds: Double)     // advance the virtual clock and emit frames
}
```

**Rule:** if a bug can be reproduced by feeding a `SyntheticFrameSource`, it must
have a CI test. Only genuine camera behaviour — exposure locking, thermal
response, real device orientation, preview layer — is allowed to be device-only.

## What this buys, concretely

Fully verifiable in CI with no camera:

- Interval gating hits the configured spacing across jitter, dropped frames, and
  clock irregularity
- Chunk rollover produces contiguous clips with no lost or duplicated frame
- Killing the writer mid-clip leaves a file that `ClipRecovery` repairs, and the
  repaired `frameCount` matches expectations
- `studyOffsetStart` tiling invariant survives arbitrary insert/finalize/delete
  orders
- Day-boundary auto-close fires only when paused, and not during recording
- The full export path: composition, speed scaling, minimum-speed clamping,
  aspect transforms, overlay layer tree, silent audio track, voiceover placement

## Export verification without eyes

Export output is checkable by inspection rather than by looking at it:

```swift
// Duration and tracks
XCTAssertEqual(asset.duration.seconds, expected, accuracy: 0.1)
XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1)
XCTAssertEqual(asset.tracks(withMediaType: .video).first?.naturalSize, CGSize(width: 1080, height: 1920))

// Overlay actually rendered: sample frames and assert pixels changed in the
// timer's corner region between t=0 and t=end
let a = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
let b = try imageGenerator.copyCGImage(at: asset.duration, actualTime: nil)
XCTAssertFalse(pixelsEqual(a, b, in: timerRect))
```

Use a `SyntheticFrameSource` producing a known solid colour so the background is
uniform — then any pixel difference in the timer region is the overlay, and a
missing overlay is an unambiguous test failure. This catches the most likely
`AVVideoCompositionCoreAnimationTool` failure mode, which is silently rendering
nothing when `beginTime` is wrong.

What still needs eyes: whether the overlay is *legible*, whether the crop framing
is good, whether the timelapse looks right. Tests prove it rendered; only the
developer can say it looks right.

## Fixtures

```
StudyLapseTests/Fixtures/
  FixtureFactory.swift    builds Sessions with N clips of specified durations
  VirtualClock.swift      injectable clock; all time-dependent code takes one
  PixelAssertions.swift   pixelsEqual, averageColor, regionDiffers
```

No time-dependent code may call `Date()` or `CACurrentMediaTime()` directly —
inject a clock. This is what makes a nine-hour session testable in milliseconds
and is non-negotiable for unattended runs.

## Running unattended

For an overnight agent session to be worth anything, each iteration must be
self-verifying. The loop is: change code, push, `gh run watch`, read the result,
fix, repeat — with the test suite as the judge.

Two rules that keep an unattended run honest:

- A phase criterion tagged `[device]` or `[eyes-on]` is **never** checked off
  during an unattended run. Add it to STATUS.md under a "Needs developer
  verification" heading instead.
- If the same test fails three consecutive pushes, stop. Write what was tried to
  STATUS.md and leave it for the developer. Do not keep burning runner minutes on
  the same failure.

## Notes

- Simulator tests need a destination that exists on the runner image; prefer
  `-destination 'generic/platform=iOS Simulator'` over a named device.
- `AVAssetExportSession` works on the simulator, though slower than on device.
  Keep test sessions short — a few hundred synthetic frames, not thousands.
- Recovery tests must actually truncate a written file rather than simulating a
  truncation, or they test nothing.
