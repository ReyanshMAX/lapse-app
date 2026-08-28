# CAPTURE.md — camera pipeline, frame interval gating, clip files, crash recovery

## Overview

Capture runs an `AVCaptureSession` at normal frame rate and discards almost every
frame, appending only those that fall on the configured interval to an
`AVAssetWriter`. Output is a normal HEVC movie whose frames are spaced
`captureIntervalSeconds` apart in real time but one frame apart at
`outputFrameRate` — i.e. the timelapse is baked at capture, and export speed
scales it further from there.

## Non-goals

- No background capture. It is not permitted by iOS; do not attempt workarounds
- No `AVCaptureMovieFileOutput` — it records at full frame rate and defeats the
  entire point
- No audio capture (D-014)
- No stabilisation, filters, manual focus UI, or resolution picker in v1
- No frame-level Vision analysis in v1 (that is the v2 feature, BUILD Phase 10)

## Session configuration

`CaptureController` is **media-only**: it consumes a `FrameSource` (D-026) and
knows nothing about `Session`, `Clip`, or `ModelContext` — the model layer sits
above it in the dependency graph (docs/ARCHITECTURE.md). `SessionCoordinator`
drives it and persists each finalized chunk on the main actor. The
`AVCaptureSession` and its `sessionQueue` / `bufferQueue` live inside
`CameraFrameSource`, not here.

```swift
struct OpenedClip: Sendable    { let index: Int; let url: URL }
struct FinalizedClip: Sendable { let index: Int; let url: URL; let frameCount: Int }

final class CaptureController {
    // Rollover thresholds (D-015).
    static let maxSegmentSeconds: Double  // 120
    static let maxSegmentFrames: Int      // 1000

    // Single clip (Phase 1 thin slice).
    func startClip(to url: URL, intervalSeconds: Double, outputFrameRate: Int32) throws
    func finishClip() async throws -> (frameCount: Int, url: URL)

    // Continuous capture with chunk rollover (Phase 2+).
    func startRecording(firstClipIndex: Int,
                        urlForClip: @escaping @Sendable (Int) -> URL,
                        intervalSeconds: Double, outputFrameRate: Int32,
                        onClipOpened: @escaping @Sendable (OpenedClip) -> Void,
                        onClipFinalized: @escaping @Sendable (FinalizedClip) -> Void) throws
    func stopRecording() async -> FinalizedClip?   // returns the trailing chunk
}
```

`onClipOpened` fires the moment a chunk's writer is created — the coordinator
persists a `Clip` row with `isFinalized == false` right then, so a force-quit
before `finishWriting` still leaves a row for launch recovery. `onClipFinalized`
fires on the writer's completion queue for **rollover** chunks; the **trailing**
chunk is returned from `stopRecording` instead, so the coordinator persists it
inside the same awaited call with no teardown race. Both carry plain values —
`@Model` types never cross the capture-queue boundary. On a clean stop the
coordinator flips the open row to finalized (or deletes it if the chunk got
zero frames).

- Preset `.hd1920x1080`. Do not use 4K: it triples file size and thermal load for
  output that is downscaled to 1080 or smaller anyway.
- `AVCaptureVideoDataOutput` with `alwaysDiscardsLateVideoFrames = true`,
  `videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]`.
- Delegate callbacks on `bufferQueue` (serial). All session mutation on
  `sessionQueue`. Never touch either from the main thread.
- **Lock exposure and white balance for the whole session** after a short warm-up
  (~1s): `device.exposureMode = .locked`, `device.whiteBalanceMode = .locked`.
  Without this, auto-exposure hunting makes the timelapse strobe. Re-lock on each
  resume, using the values from the previous clip where the device permits it.
- Set `UIApplication.shared.isIdleTimerDisabled = true` while recording and
  restore on pause.

## Frame gating

```swift
func captureOutput(_ output: AVCaptureOutput,
                   didOutput sampleBuffer: CMSampleBuffer,
                   from connection: AVCaptureConnection) {
    let now = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard lastAcceptedPTS == nil ||
          CMTimeGetSeconds(CMTimeSubtract(now, lastAcceptedPTS!)) >= interval - tolerance
    else { return }
    lastAcceptedPTS = now
    append(sampleBuffer)
}
```

- `tolerance = 0.02` seconds, to avoid dropping a frame that arrives a hair early.
- Synthesize the written timestamp rather than passing the source PTS through:
  `CMTime(value: Int64(frameIndex), timescale: outputFrameRate)`. This is what
  makes the written file a real timelapse.
- `frameIndex` is per-clip and resets on each new clip.

## Writer configuration

```swift
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: 1920,
    AVVideoHeightKey: 1080,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 8_000_000,
        AVVideoExpectedSourceFrameRateKey: 30,
        AVVideoMaxKeyFrameIntervalKey: 30
    ]
]
```

`AVAssetWriterInput` with `expectsMediaDataInRealTime = false` — frames arrive
every few seconds, not in real time, and setting `true` causes the writer to
misjudge its pacing. Feed through an `AVAssetWriterInputPixelBufferAdaptor`.

## Chunking and durability (D-015)

- Finalize the current clip and open the next when **either** 120 seconds of
  recorded time have elapsed (measured as the source-PTS delta from the chunk's
  first accepted frame — this is real elapsed time while the capture session
  runs, and pauses don't count because the session is torn down on pause)
  **or** 1000 frames have been written.
- Chunk rollover must not drop a frame: the frame that trips the threshold is
  routed into the new chunk as its frame 0, and the previous chunk's writer is
  finalized asynchronously so frames keep flowing.
- A `Clip` row is inserted with `isFinalized == false` when a chunk *opens*
  (`onClipOpened`), so a crash before `finishWriting` still leaves a row.
- On successful `finishWriting`, flip that row: `isFinalized = true`, persist
  `frameCount`, recompute `studyOffsetStart` for the session.
- Worst-case loss on power failure is therefore one chunk (~2 minutes).

### Launch recovery

```swift
enum ClipRecovery {
    static func recoverUnfinalized(in context: ModelContext) async -> [Clip]
    static func demoteRecordingSessions(in context: ModelContext) -> [Session]
}
```

On every launch, find `Clip` rows where `isFinalized == false`:

1. If the file is missing or zero-length → delete the row.
2. Otherwise load as `AVURLAsset` and read `.isReadable` and `duration`. A
   `.mov` written by `AVAssetWriter` without a successful finish is often still
   partially readable, since sample data is written incrementally.
3. If readable and `duration > 0`: set `frameCount` from
   `duration * outputFrameRate` (rounded down), `isFinalized = true`,
   `wasRecovered = true`.
4. If unreadable → delete row and file.
5. Recompute all `studyOffsetStart` values for affected sessions.

Any session left in `.recording` at launch is moved to `.paused` — the app was
not running, so it was not recording.

## Lifecycle (D-016)

| Event | Behavior |
|---|---|
| `scenePhase` → `.inactive` or `.background` | auto-pause: finalize clip, stop session, keep session open, start/refresh Live Activity |
| `AVCaptureSessionWasInterrupted` (call, another app took the camera) | auto-pause, same as backgrounding |
| `AVCaptureSessionInterruptionEnded` | do **not** auto-resume; require an explicit user tap |
| `AVAudioSession`/`MediaServicesWereReset` | tear down and rebuild the session; if recording, finalize first |
| App termination while paused | nothing to do — clips already finalized |

## Guards

| Condition | Threshold | Action |
|---|---|---|
| Battery at session start | < 30% and unplugged | Warn, offer to continue (D-018) |
| Battery during recording | ≤ 10% | Non-blocking banner |
| Battery during recording | ≤ 5% | Auto-pause and end the session cleanly |
| `ProcessInfo.thermalState` | `.serious` | Banner; reduce preview refresh |
| `ProcessInfo.thermalState` | `.critical` | Auto-pause |
| Free disk space at session start | < 1 GB | Warn |
| Free disk space during recording | < 300 MB | Auto-pause and end |

Observe `ProcessInfo.thermalStateDidChangeNotification` and
`UIDevice.batteryLevelDidChangeNotification` (requires
`isBatteryMonitoringEnabled = true`).

## Framing continuity

The camera preview (docs/UI.md screens 1–3) is shown continuously — idle,
recording, and paused — so the user can see and correct framing at any point,
not just at resume (D-028). This replaced an earlier last-frame "ghost
overlay" design, built and then removed the same day: with the live feed
always visible, a static echo of the previous frame added nothing.

## Screen dimming

While recording, set `UIScreen.main.brightness` to 0.05 and store the previous
value for restore on pause or termination. The screen cannot be turned off
entirely while the camera runs. `UIScreen.main.brightness` dims everything
rendered, including the live camera preview (D-028) — the recording screen
reads as near-black with the timer as the only clearly lit element, not
because the preview is hidden but because the whole display is dimmed (see
docs/UI.md).

## Storage estimate

At 1080p HEVC, 8 Mbps, 30fps output and the 2-second default interval, one hour
of study produces 1800 frames = 60 seconds of video ≈ 60 MB. A nine-hour day
≈ 540 MB. Surface a running estimate in the recording UI.

## Notes

- `NSCameraUsageDescription` must explain the timelapse purpose concretely.
  Vague strings are a common rejection cause.
- Frame gating uses presentation timestamps, not `Date()` — wall clock can jump.
- Do not write clip files to `Documents`; use Application Support with backup
  exclusion (docs/DATA_MODEL.md).
