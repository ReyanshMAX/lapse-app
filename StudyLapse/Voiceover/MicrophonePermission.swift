import AVFoundation

/// Microphone authorization, mirroring `CameraPermission`. Used only when the
/// user records a voiceover over a finished export (Phase 6).
enum MicrophonePermission {
    static var status: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static var isGranted: Bool { status == .granted }

    static func request() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
