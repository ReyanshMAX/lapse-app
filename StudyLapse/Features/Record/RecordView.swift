import AVFoundation
import SwiftUI

/// Phase 1 thin slice: prime/request camera permission, run one hardcoded
/// 60s capture at a 3s interval, then hand off to playback. No sessions, no
/// pause/resume, no overlay — see BUILD.md Phase 1 non-goals.
struct RecordView: View {
    @State private var authorizationStatus: AVAuthorizationStatus = CameraPermission.status
    @State private var isCapturing = false
    @State private var secondsRemaining = Int(RecordView.captureDurationSeconds)
    @State private var resultURL: URL?
    @State private var errorMessage: String?

    private static let captureIntervalSeconds: Double = 3
    private static let outputFrameRate: Int32 = 30
    private static let captureDurationSeconds: Double = 60

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch authorizationStatus {
                case .authorized:
                    captureContent
                case .notDetermined:
                    permissionPrime
                default:
                    permissionDenied
                }
            }
            .padding()
            .navigationTitle("StudyLapse")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink("Debug Log") {
                        DebugLogView()
                    }
                }
            }
            .navigationDestination(item: $resultURL) { url in
                PlaybackView(url: url)
            }
        }
    }

    @ViewBuilder
    private var permissionPrime: some View {
        VStack(spacing: 16) {
            Text("StudyLapse needs camera access to record your study timelapse. Video stays on this device and is never uploaded.")
                .multilineTextAlignment(.center)
            Button("Enable Camera") {
                Task {
                    _ = await CameraPermission.requestAccess()
                    authorizationStatus = CameraPermission.status
                    DebugLog.write("Permission", "camera authorization now \(authorizationStatus.rawValue)")
                }
            }
        }
    }

    @ViewBuilder
    private var permissionDenied: some View {
        Text("Camera access is required. Enable it in Settings to continue.")
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var captureContent: some View {
        if isCapturing {
            VStack(spacing: 16) {
                Text("\(secondsRemaining)s remaining")
                    .font(.system(.largeTitle, design: .monospaced))
                ProgressView(value: Self.captureDurationSeconds - Double(secondsRemaining), total: Self.captureDurationSeconds)
            }
        } else {
            VStack(spacing: 16) {
                Button("Start 60s Capture") {
                    startCapture()
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func startCapture() {
        errorMessage = nil

        let clipURL = StorageLocator.url(forRelativePath: "phase1-clips/\(UUID().uuidString).mov")
        try? FileManager.default.createDirectory(
            at: clipURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let source = CameraFrameSource()
        let controller = CaptureController(source: source)

        do {
            try controller.startClip(
                to: clipURL,
                intervalSeconds: Self.captureIntervalSeconds,
                outputFrameRate: Self.outputFrameRate
            )
        } catch {
            errorMessage = "Failed to start capture: \(error.localizedDescription)"
            DebugLog.write("Capture", "start failed: \(error)")
            return
        }

        isCapturing = true
        secondsRemaining = Int(Self.captureDurationSeconds)

        Task {
            while secondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                secondsRemaining -= 1
            }
            do {
                let result = try await controller.finishClip()
                isCapturing = false
                resultURL = result.url
            } catch {
                isCapturing = false
                errorMessage = "Failed to finish capture: \(error.localizedDescription)"
                DebugLog.write("Capture", "finish failed: \(error)")
            }
        }
    }
}
