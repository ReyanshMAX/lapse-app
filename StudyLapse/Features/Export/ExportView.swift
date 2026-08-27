import SwiftData
import SwiftUI

/// Phase 3 export screen (docs/UI.md §5): speed, aspect, overlay, intro/outro,
/// a live estimated output duration, then render → progress → Save to Photos /
/// Share. Reached per-session from the debug clip browser until Phase 4 wires
/// the tagging → export flow.
struct ExportView: View {
    let session: Session

    @Environment(\.modelContext) private var modelContext
    @State private var coordinator: ExportCoordinator?
    @State private var profile: ExportProfile?

    var body: some View {
        Group {
            if let profile, let coordinator {
                ExportControls(session: session, profile: profile, coordinator: coordinator)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Export")
        .onAppear(perform: setup)
    }

    private func setup() {
        if coordinator == nil {
            coordinator = ExportCoordinator(context: modelContext)
        }
        guard profile == nil else { return }
        if let existing = session.exportProfile {
            profile = existing
        } else {
            let created = ExportProfile(session: session)
            session.exportProfile = created
            modelContext.insert(created)
            try? modelContext.save()
            profile = created
        }
    }
}

private struct ExportControls: View {
    let session: Session
    @Bindable var profile: ExportProfile
    let coordinator: ExportCoordinator

    @State private var saveState: SaveState = .idle

    private enum SaveState: Equatable {
        case idle, saving, saved, failed(String)
    }

    private var finalizedClipCount: Int { session.orderedFinalizedClips.count }

    private var estimatedDuration: Double {
        ExportCoordinator.estimatedOutputDuration(session: session, profile: profile)
    }

    private var isClamped: Bool {
        ExportCoordinator.isClampedToFloor(session: session, profile: profile)
    }

    var body: some View {
        Form {
            Section("Speed") {
                Picker("Mode", selection: $profile.speedModeRaw) {
                    Text("Multiplier").tag("multiplier")
                    Text("Fit to duration").tag("fitToDuration")
                }
                .pickerStyle(.segmented)

                if profile.speedModeRaw == "fitToDuration" {
                    Picker("Target", selection: $profile.targetDurationSeconds) {
                        Text("15s").tag(15.0)
                        Text("30s").tag(30.0)
                        Text("60s").tag(60.0)
                    }
                } else {
                    Stepper(value: $profile.speedMultiplier, in: 10...600, step: 10) {
                        Text("\(Int(profile.speedMultiplier))×")
                    }
                }
            }

            Section("Format") {
                Picker("Aspect", selection: $profile.aspectRaw) {
                    ForEach(AspectPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                }
                Picker("Timer style", selection: $profile.overlayStyleRaw) {
                    ForEach(OverlayStyle.allCases, id: \.rawValue) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                Picker("Timer corner", selection: $profile.overlayCornerRaw) {
                    ForEach(OverlayCorner.allCases, id: \.rawValue) { corner in
                        Text(corner.label).tag(corner.rawValue)
                    }
                }
                Toggle("Intro card", isOn: $profile.includeIntroCard)
                Toggle("Outro card", isOn: $profile.includeOutroCard)
            }

            Section("Output") {
                LabeledContent("Estimated length",
                               value: String(format: "%.2fs", estimatedDuration))
                if isClamped {
                    Text("Clamped to the minimum speed for this capture interval — "
                         + "the video can't be slower than one captured frame per output frame.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Finished clips", value: "\(finalizedClipCount)")
            }

            renderSection
        }
        // NOTE: docs/DATA_MODEL.md says `revision` bumps on any profile edit,
        // to invalidate stale voiceover takes. Nothing reads it before Phase 6
        // (voiceover), and doing it here risks bumping on screen-open. Phase 6
        // owns "profile-revision staleness detection" — it wires this properly.
    }

    @ViewBuilder
    private var renderSection: some View {
        Section {
            if coordinator.isExporting {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: coordinator.progress ?? 0)
                    Button("Cancel", role: .destructive) { coordinator.cancel() }
                }
            } else {
                Button("Render") {
                    saveState = .idle
                    Task { await coordinator.export(session: session, profile: profile) }
                }
                .disabled(finalizedClipCount == 0)
            }

            if let error = coordinator.lastError {
                Text(error).foregroundStyle(.red)
            }

            if let url = coordinator.lastExportURL, !coordinator.isExporting {
                resultRows(url: url)
            }
        }
    }

    @ViewBuilder
    private func resultRows(url: URL) -> some View {
        NavigationLink("Preview") { PlaybackView(url: url) }
        ShareLink("Share", item: url)
        Button {
            saveState = .saving
            Task {
                do {
                    try await PhotosSaver.save(url)
                    saveState = .saved
                } catch {
                    saveState = .failed((error as? LocalizedError)?.errorDescription
                                        ?? error.localizedDescription)
                }
            }
        } label: {
            switch saveState {
            case .saving: Text("Saving…")
            case .saved:  Label("Saved to Photos", systemImage: "checkmark")
            default:      Text("Save to Photos")
            }
        }
        .disabled(saveState == .saving || saveState == .saved)

        if case .failed(let message) = saveState {
            Text(message).foregroundStyle(.red).font(.footnote)
        }
    }
}
