import StudyLapseCore
import SwiftData
import SwiftUI

/// Stats screen (docs/UI.md §8): total hours, current streak by `dayKey`,
/// per-tag time split as a horizontal bar with an explicit untagged band, and
/// a calendar heatmap. All aggregation is `StudyLapseCore.Stats`; this view
/// only maps `@Model` rows to its plain inputs.
struct StatsView: View {
    @Query private var sessions: [Session]
    @Query private var tagRanges: [TagRange]

    private var finishedSessions: [Session] {
        sessions.filter { $0.status == .ended }
    }

    private func studySeconds(_ session: Session) -> Double {
        session.orderedFinalizedClips.reduce(0) { $0 + $1.studyDuration }
    }

    private var totalSeconds: Double {
        finishedSessions.reduce(0) { $0 + studySeconds($1) }
    }

    private var todayKey: String {
        let hour = UserDefaults.standard.object(forKey: "dayCutoffHour") as? Int ?? 4
        return DayBoundary(cutoffHour: hour).dayKey(for: Date())
    }

    private var studiedDayKeys: Set<String> {
        Set(finishedSessions.map(\.dayKey))
    }

    private var streak: Int {
        Stats.currentStreak(studiedDayKeys: studiedDayKeys, today: todayKey)
    }

    private var longestStreak: Int {
        Stats.longestStreak(studiedDayKeys: studiedDayKeys)
    }

    private var split: Stats.Split {
        let endedSessionIDs = Set(finishedSessions.map(\.id))
        let ranges = tagRanges
            .filter { $0.session.map { endedSessionIDs.contains($0.id) } ?? false }
            .map { TagRangeMath.Range(start: $0.startStudySeconds,
                                     end: $0.endStudySeconds,
                                     tags: $0.tagNames) }
        return Stats.perTagSplit(ranges: ranges)
    }

    private var dailySeconds: [String: Double] {
        var totals: [String: Double] = [:]
        for session in finishedSessions {
            totals[session.dayKey, default: 0] += studySeconds(session)
        }
        return totals
    }

    var body: some View {
        List {
            Section("Totals") {
                LabeledContent("Total study time", value: Formatters.studyTime(totalSeconds))
                LabeledContent("Sessions", value: "\(finishedSessions.count)")
                LabeledContent("Current streak",
                               value: "\(streak) day\(streak == 1 ? "" : "s")")
                LabeledContent("Longest streak",
                               value: "\(longestStreak) day\(longestStreak == 1 ? "" : "s")")
            }

            Section("By tag") {
                if split.total <= 0 {
                    Text("No tagged sessions yet").foregroundStyle(.secondary)
                } else {
                    TagSplitBar(split: split)
                    ForEach(split.shares, id: \.tag) { share in
                        LabeledContent(share.tag, value: Formatters.studyTime(share.seconds))
                    }
                    if split.untagged > 0 {
                        LabeledContent("Untagged", value: Formatters.studyTime(split.untagged))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Last 12 weeks") {
                HeatmapView(dailySeconds: dailySeconds)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A single horizontal bar partitioned into per-tag bands plus untagged.
private struct TagSplitBar: View {
    let split: Stats.Split

    private let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .yellow]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(split.shares.enumerated()), id: \.element.tag) { index, share in
                    Rectangle()
                        .fill(palette[index % palette.count])
                        .frame(width: width(share.seconds, in: geo.size.width))
                }
                if split.untagged > 0 {
                    Rectangle()
                        .fill(Color.gray.opacity(0.35))
                        .frame(width: width(split.untagged, in: geo.size.width))
                }
            }
        }
        .frame(height: 18)
        .clipShape(Capsule())
    }

    private func width(_ seconds: Double, in total: CGFloat) -> CGFloat {
        guard split.total > 0 else { return 0 }
        return max(0, total * CGFloat(seconds / split.total))
    }
}

/// GitHub-style calendar heatmap: one column per week, intensity by study time.
private struct HeatmapView: View {
    let dailySeconds: [String: Double]

    private let weeks = 12

    private var columns: [[String]] {
        let keys = Stats.recentDayKeys(count: weeks * 7, endingOn: Date())
        return stride(from: 0, to: keys.count, by: 7).map {
            Array(keys[$0..<min($0 + 7, keys.count)])
        }
    }

    private var maxSeconds: Double {
        max(dailySeconds.values.max() ?? 0, 1)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(week, id: \.self) { key in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: dailySeconds[key] ?? 0))
                                .frame(width: 16, height: 16)
                        }
                    }
                }
            }
        }
    }

    private func color(for seconds: Double) -> Color {
        guard seconds > 0 else { return Color.gray.opacity(0.15) }
        let intensity = 0.25 + 0.75 * min(seconds / maxSeconds, 1)
        return Color.accentColor.opacity(intensity)
    }
}
