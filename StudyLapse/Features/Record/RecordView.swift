import AVFoundation
import StudyLapseCore
import SwiftUI

/// Phase 2 record screen: the study-time timer, clip count, and
/// record / pause / resume / end controls wired to `SessionCoordinator`.
/// No preview while recording (docs/UI.md, Q-005); no overlay, tagging, or
/// export yet (BUILD.md Phase 2 non-goals).
struct RecordView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @State private var authorizationStatus: AVAuthorizationStatus = CameraPermission.status
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch authorizationStatus {
                case .authorized:
                    sessionControls
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
                    NavigationLink("Debug Log") { DebugLogView() }
                }
            }
        }
    }

    @ViewBuilder
    private var sessionControls: some View {
        Text(Formatters.studyTime(coordinator.studySeconds))
            .font(.system(size: 60, weight: .semibold, design: .monospaced))
            .monospacedDigit()

        Text(clipCountLabel)
            .foregroundStyle(.secondary)

        VStack(spacing: 12) {
            switch coordinator.status {
            case .ended:
                actionButton("Start Recording") { start() }
            case .recording:
                actionButton("Pause") { Task { await coordinator.pause() } }
                actionButton("End Session", role: .destructive) { Task { await coordinator.end() } }
            case .paused:
                actionButton("Resume") { resume() }
                actionButton("End Session", role: .destructive) { Task { await coordinator.end() } }
            }
        }

        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private var clipCountLabel: String {
        let count = coordinator.clipCount
        return "\(count) clip\(count == 1 ? "" : "s")"
    }

    private func actionButton(_ title: String, role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(title, role: role, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }

    private func start() {
        errorMessage = nil
        do {
            try coordinator.startNewSession()
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            DebugLog.write("Record", "start failed: \(error)")
        }
    }

    private func resume() {
        errorMessage = nil
        do {
            try coordinator.resume()
        } catch {
            errorMessage = "Couldn't resume: \(error.localizedDescription)"
            DebugLog.write("Record", "resume failed: \(error)")
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
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var permissionDenied: some View {
        Text("Camera access is required. Enable it in Settings to continue.")
            .multilineTextAlignment(.center)
    }
}
