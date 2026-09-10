import StudyLapseCore
import SwiftData
import SwiftUI

/// "Merge Sessions" picker (Library toolbar, developer request, 2026-09-10 —
/// "merge multiple study sessions at export... not merge the source clips").
/// Multi-select finished sessions, optionally narrowed by the same
/// Today/this-week windows Home and Stats already use, then push `ExportView`
/// with all of them — nothing about `Session`/`Clip` storage changes; this is
/// purely an alternate way to build an `ExportPlan` from more than one
/// session's clips (`ExportCoordinator.buildPlan(sessions:profile:)`).
struct MergeSessionsView: View {
    @Query(sort: \Session.startedAt, order: .reverse) private var allSessions: [Session]
    @Environment(\.modelContext) private var context

    @State private var selectedIDs: Set<UUID> = []
    @State private var filter: DateFilter = .all

    private enum DateFilter: String, CaseIterable {
        case today = "Today"
        case week = "This Week"
        case all = "All"
    }

    /// Same cutoff-aware "today" every other screen uses (Home, Stats) —
    /// `UserDefaults`-backed `dayCutoffHour`, not a raw calendar day.
    private var todayKey: String {
        let hour = UserDefaults.standard.object(forKey: "dayCutoffHour") as? Int ?? 4
        return DayBoundary(cutoffHour: hour).dayKey(for: Date())
    }

    /// Finished, re-exportable, non-empty sessions only — the same
    /// eligibility a normal re-export already requires (`canReExport`,
    /// docs/DATA_MODEL.md), plus "has something to actually concatenate".
    private var eligibleSessions: [Session] {
        allSessions.filter {
            $0.status == .ended && $0.canReExport && !$0.orderedFinalizedClips.isEmpty
        }
    }

    private var filteredSessions: [Session] {
        switch filter {
        case .all:
            return eligibleSessions
        case .today:
            return eligibleSessions.filter { $0.dayKey == todayKey }
        case .week:
            let dayKeys = Set(Stats.recentDayKeys(count: 7, endingOn: Date()))
            return eligibleSessions.filter { dayKeys.contains($0.dayKey) }
        }
    }

    private var selectedSessions: [Session] {
        eligibleSessions.filter { selectedIDs.contains($0.id) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// The capture settings the first selection fixes — every other session
    /// must match to be selectable (`ExportError.mismatchedCaptureSettings`
    /// is the same check `buildPlan(sessions:)` makes; this is the UI-level
    /// guard so an incompatible row is disabled rather than failing at
    /// render time).
    private var lockedCaptureSettings: (interval: Double, fps: Int32)? {
        guard let first = selectedSessions.first else { return nil }
        return (first.captureIntervalSeconds, first.outputFrameRate)
    }

    private func isCompatible(_ session: Session) -> Bool {
        guard let locked = lockedCaptureSettings else { return true }
        return session.captureIntervalSeconds == locked.interval
            && session.outputFrameRate == locked.fps
    }

    private var totalStudySeconds: Double {
        selectedSessions.reduce(0) { $0 + $1.orderedFinalizedClips.reduce(0) { $0 + $1.studyDuration } }
    }

    var body: some View {
        Group {
            if eligibleSessions.isEmpty {
                EmptyStateView(
                    systemImage: "rectangle.stack.badge.plus",
                    title: "No sessions to merge",
                    message: "Finish a couple of study sessions first, then merge them here.")
            } else {
                List {
                    Section {
                        Picker("Filter", selection: $filter) {
                            ForEach(DateFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        if filteredSessions.isEmpty {
                            Text("No sessions in this window.")
                                .foregroundStyle(Color.slTextSecondary)
                        }
                        ForEach(filteredSessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .tokenizedListStyle()
                .safeAreaInset(edge: .bottom) { footer }
            }
        }
        .navigationTitle("Merge Sessions")
        .screenBackground()
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let isSelected = selectedIDs.contains(session.id)
        let compatible = isSelected || isCompatible(session)
        let studySeconds = session.orderedFinalizedClips.reduce(0.0) { $0 + $1.studyDuration }
        let tagNames = Array(Set(session.tagRanges.flatMap(\.tagNames))).sorted()

        Button {
            if isSelected {
                selectedIDs.remove(session.id)
            } else {
                selectedIDs.insert(session.id)
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.slAccent : Color.slTextSecondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(Color.slTextPrimary)
                    Text(Formatters.studyTime(studySeconds))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.slTextSecondary)
                    if !tagNames.isEmpty {
                        TagChipRow(names: tagNames, colorFor: { tagColor($0, in: context) })
                    }
                    if !compatible {
                        Text("Different capture settings — can't merge with the current selection")
                            .font(.caption2)
                            .foregroundStyle(Color.slWarning)
                    }
                }
                Spacer()
            }
        }
        .disabled(!compatible)
        .opacity(compatible ? 1 : 0.5)
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            if !selectedSessions.isEmpty {
                Text("\(selectedSessions.count) sessions · \(Formatters.studyTime(totalStudySeconds)) total")
                    .font(.footnote)
                    .foregroundStyle(Color.slTextSecondary)
            }
            NavigationLink {
                ExportView(sessions: selectedSessions)
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedSessions.count < 2)
        }
        .padding(DesignTokens.Spacing.lg)
        .background(Color.slSurface)
    }
}
