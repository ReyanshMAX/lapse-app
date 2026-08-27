import AVFoundation

/// The only type that touches `AVAudioRecorder` / `AVAudioSession`. Kept thin
/// and logic-free so `VoiceoverCoordinator` is testable in CI with a stub
/// (mirrors the `FrameSource` seam — docs/TESTING.md).
protocol VoiceoverRecording: AnyObject {
    var isRecording: Bool { get }
    /// Begin recording to `url`. Throws `VoiceoverError.recorderFailedToStart`
    /// if the audio session or hardware refuses.
    func start(to url: URL) throws
    /// Stop and return the recorded duration in seconds (0 if nothing usable).
    func stop() -> Double
}

/// Device implementation. Records mono AAC into `.m4a`. Every step logs to the
/// on-device debug log — with no Xcode console this is how a failed take is
/// diagnosed on device (same pattern as Phase 3's `Export verify:` line).
final class AVAudioRecorderVoiceover: NSObject, VoiceoverRecording {
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start(to url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.soloAmbient` (the default) blocks `record()` while an AVPlayer
            // is up — the voiceover screen always has one. `.playAndRecord` is
            // required.
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            DebugLog.write("Voiceover", "audio session .playAndRecord active")
        } catch {
            DebugLog.write("Voiceover", "audio session setup failed: \(error)")
            throw VoiceoverError.recorderFailedToStart
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            let ok = recorder.record()
            DebugLog.write("Voiceover", "record() -> \(ok)")
            guard ok else { throw VoiceoverError.recorderFailedToStart }
            self.recorder = recorder
            self.startedAt = Date()
        } catch {
            DebugLog.write("Voiceover", "recorder failed to start: \(error)")
            throw VoiceoverError.recorderFailedToStart
        }
    }

    func stop() -> Double {
        guard let recorder else { return 0 }
        let recorded = recorder.currentTime          // valid only while recording
        recorder.stop()
        self.recorder = nil
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? recorded
        startedAt = nil
        // Return the session to a playback category — leaving it on
        // `.playAndRecord` makes the export playback quieter for the rest of
        // the screen's life.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            DebugLog.write("Voiceover", "audio session back to .playback")
        } catch {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            DebugLog.write("Voiceover", "audio session restore failed: \(error)")
        }
        let duration = recorded > 0 ? recorded : elapsed
        DebugLog.write("Voiceover", String(format: "stopped take: %.2fs (recorder %.2fs / elapsed %.2fs)",
                                            duration, recorded, elapsed))
        return duration
    }
}
