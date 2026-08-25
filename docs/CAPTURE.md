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
- No frame-level Vision analysis in v1 (that is the v2 feature, BUILD Phase 9)

## Session configuration

```swift
final class CaptureController: NSObject {
    static let sessionQueue = DispatchQueue(label: "studylapse.capture.session")
    static let bufferQueue  = DispatchQueue(label: "studylapse.capture.buffer")

    func configure(position: AVCaptureDevice.Position) throws
    func start(session: Session) throws        // begins a new clip
    func pause() async                         // finalizes current clip, stops session
    func resume(session: Session) throws       // new clip, index = last + 1
    func end(session: Session) async           // finalize + mark session ended
}
```

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
  recorded wall time have elapsed **or** 1000 frames have been written.
- Chunk rollover must not drop a frame: open the next writer before finalizing
  the previous one, and route the first frame of the new interval into it.
- On successful `finishWriting`, set `isFinalized = true`, persist `frameCount`,
  recompute `studyOffsetStart` for the session, and write `ghost.jpg` from the
  clip's last frame.
- Worst-case loss on power failure is therefore one chunk (~2 minutes).

### Launch recovery

```swift
enum ClipRecovery {
    static func recoverUnfinalized(in context: ModelContext) async -> [Clip]
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

On resume, display `ghost.jpg` — the last frame of the previous finalized clip —
as a low-opacity overlay on the camera preview so the user can re-align the
phone. Dismissible, and hidden automatically once recording starts.

## Screen dimming

While recording, set `UIScreen.main.brightness` to 0.05 and store the previous
value for restore on pause or termination. The screen cannot be turned off
entirely while the camera runs. The recording screen itself must be near-black
with the timer as the only lit element (see docs/UI.md).

## Storage estimate

At 1080p HEVC, 8 Mbps, 30fps output and a 3-second interval, one hour of study
produces 1200 frames = 40 seconds of video ≈ 40 MB. A nine-hour day ≈ 360 MB.
Surface a running estimate in the recording UI.

## Notes

- `NSCameraUsageDescription` must explain the timelapse purpose concretely.
  Vague strings are a common rejection cause.
- Frame gating uses presentation timestamps, not `Date()` — wall clock can jump.
- Do not write clip files to `Documents`; use Application Support with backup
  exclusion (docs/DATA_MODEL.md).
