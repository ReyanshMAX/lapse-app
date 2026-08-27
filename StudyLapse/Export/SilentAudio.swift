import AVFoundation

/// Generates a silent LPCM `.caf` file of a given duration. Export always
/// carries a full-length silent audio track (D-014) so voiceover takes mix in
/// later without re-encoding the video. LPCM into `.caf` is used rather than
/// AAC/`.m4a`: the AAC encoder path through `AVAudioFile` is the flakier one on
/// the simulator, and `AVAssetExportSession` transcodes the track anyway.
enum SilentAudio {
    static let sampleRate: Double = 44_100

    static func makeFile(duration seconds: Double) throws -> URL {
        let clamped = max(seconds, 0.1)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)
        // `write(from:)` requires buffers in the file's *processing* format,
        // which is float32 regardless of the on-disk LPCM format above.
        let format = file.processingFormat

        let totalFrames = AVAudioFrameCount((clamped * sampleRate).rounded())
        let chunk: AVAudioFrameCount = 44_100 * 10          // 10s at a time
        var remaining = totalFrames
        while remaining > 0 {
            let n = min(chunk, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else {
                throw ExportError.compositionFailed("could not allocate silent audio buffer")
            }
            buffer.frameLength = n
            if let channels = buffer.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    memset(channels[c], 0, Int(n) * MemoryLayout<Float>.size)
                }
            }
            try file.write(from: buffer)
            remaining -= n
        }
        return url
    }
}
