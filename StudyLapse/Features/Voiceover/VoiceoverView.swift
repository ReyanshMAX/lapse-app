import AVFoundation
import AVKit
import Combine
import StudyLapseCore
import SwiftData
import SwiftUI

/// Voiceover screen (docs/UI.md §6). Plays the rendered export with a scrubber;
/// the record button captures a take starting at the current output position
/// and stops on tap or at end of video. Takes show as blocks on a timeline
/// strip, each tappable to mute or delete. Overlapping takes are prevented at
/// creation — the button is disabled while the playhead sits inside an existing
/// take. A banner appears when a take is stale against the current export
/// profile revision.
struct VoiceoverView: View {
    let session: Session
    let export: ExportRecord

    @Environment(\.modelContext) private var context
    @State private var coordinator: VoiceoverCoordinator?
    @State private var profile: ExportProfile?

    @State private var player = AVPlayer()
    @State private var playhead: Double = 0
    @State private var duration: Double = 0

    @State private var micStatus = MicrophonePermission.status
    @State private var errorMessage: String?

    // `@State` so the publisher is created once, not rebuilt on every body
    // evaluation (which would restart the 0.1s countdown and can freeze the
    // playhead readout).
    @State private var ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private var url: URL { StorageLocator.url(forRelativePath: export.relativePath) }

    var body: some View {
        Group {
            if let coordinator, let profile {
                content(coordinator: coordinator, profile: profile)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Voiceover")
        .navigationBarTitleDisplayMode(.inline)
        .task { await setup() }
        .onDisappear { stopIfRecording(); player.pause() }
        .onReceive(ticker) { _ in
            let t = player.currentTime().seconds
            playhead = t.isFinite ? t : 0
            if coordinator?.isRecording == true, duration > 0, playhead >= duration - 0.1 {
                stopIfRecording()
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(coordinator: VoiceoverCoordinator, profile: ExportProfile) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                staleBanner(coordinator: coordinator, profile: profile)
                timelineStrip(coordinator: coordinator)

                Text("\(Formatters.minutesSeconds(playhead)) / \(Formatters.minutesSeconds(duration))")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)

                recordControl(coordinator: coordinator)

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                takeList(coordinator: coordinator)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func staleBanner(coordinator: VoiceoverCoordinator, profile: ExportProfile) -> some View {
        let stale = coordinator.staleTakes(for: profile)
        if !stale.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(stale.count) take\(stale.count == 1 ? "" : "s") no longer line up with the current export settings and will be skipped on re-export.")
                    .font(.footnote)
                Button("Delete misaligned takes", role: .destructive) {
                    coordinator.deleteStaleTakes(for: profile)
                }
                .font(.footnote)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.yellow.opacity(0.18)))
        }
    }

    @ViewBuilder
    private func timelineStrip(coordinator: VoiceoverCoordinator) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                ForEach(coordinator.takes) { take in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(take.isMuted ? Color.secondary.opacity(0.4) : Color.accentColor.opacity(0.7))
                        .frame(width: max(fraction(take.durationSeconds) * width, 3))
                        .offset(x: fraction(take.outputStartSeconds) * width)
                }
                Rectangle().fill(Color.red).frame(width: 2)
                    .offset(x: fraction(playhead) * width)
            }
        }
        .frame(height: 28)
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / duration, 0), 1))
    }

    @ViewBuilder
    private func recordControl(coordinator: VoiceoverCoordinator) -> some View {
        let insideTake = coordinator.playheadIsInsideTake(playhead)
        VStack(spacing: 4) {
            if coordinator.isRecording {
                Button("Stop", role: .destructive) { stopIfRecording() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button {
                    startTake(coordinator)
                } label: {
                    Label("Record from \(Formatters.minutesSeconds(playhead))",
                          systemImage: "mic.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(insideTake || micStatus == .denied)
            }

            if insideTake {
                Text("Playhead is inside an existing take — move it to record here.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if micStatus == .denied {
                Text("Microphone access is off. Enable it in Settings.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func takeList(coordinator: VoiceoverCoordinator) -> some View {
        if coordinator.takes.isEmpty {
            Text("No takes yet.").font(.footnote).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(coordinator.takes) { take in
                    HStack {
                        Text("\(Formatters.minutesSeconds(take.outputStartSeconds)) · \(String(format: "%.1fs", take.durationSeconds))")
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                        Button(take.isMuted ? "Unmute" : "Mute") {
                            coordinator.setMuted(!take.isMuted, for: take)
                        }
                        .font(.caption).buttonStyle(.bordered)
                        Button("Delete", role: .destructive) { coordinator.delete(take) }
                            .font(.caption).buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    // MARK: Actions

    private func startTake(_ coordinator: VoiceoverCoordinator) {
        errorMessage = nil
        Task {
            if micStatus == .undetermined {
                _ = await MicrophonePermission.request()
                micStatus = MicrophonePermission.status
            }
            guard micStatus == .granted else {
                if micStatus == .denied { errorMessage = VoiceoverError.permissionDenied.errorDescription }
                return
            }
            player.pause()
            do {
                try coordinator.startTake(at: playhead)
                player.play()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func stopIfRecording() {
        guard let coordinator, coordinator.isRecording else { return }
        player.pause()
        Task { _ = await coordinator.stopTake() }
    }

    // MARK: Setup

    private func setup() async {
        if coordinator == nil {
            coordinator = VoiceoverCoordinator(context: context, session: session,
                                               recordedAgainstRevision: export.profileRevision)
        }
        if profile == nil { profile = session.exportProfile }

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        let loaded = try? await item.asset.load(.duration)
        duration = (loaded?.seconds).flatMap { $0.isFinite ? $0 : nil } ?? export.durationSeconds
    }
}
