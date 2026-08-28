import ActivityKit
import StudyLapseCore
import SwiftUI
import WidgetKit

/// docs/UI.md "Live Activity": compact leading = app glyph, compact trailing
/// = accumulated study time, expanded = study time + clip count + Resume.
/// The Resume control is a plain `Link` to the `studylapse://resume` deep
/// link, not an `AppIntent` — an `AppIntent`'s `perform()` runs in this
/// extension's process and has no App-Group-free way to reach the app's live
/// `SessionCoordinator` (Q-004), so the URL itself has to carry the whole
/// signal; `StudyLapseApp.onOpenURL` does the actual resume.
struct StudyLapseActivityWidget: Widget {
    private static let resumeURL = URL(string: "studylapse://resume")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StudyLapseActivityAttributes.self) { context in
            LockScreenView(context: context)
                .widgetURL(Self.resumeURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "clock.fill")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(Formatters.studyTime(context.state.studySeconds))
                        .font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Link(destination: Self.resumeURL) {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } compactLeading: {
                Image(systemName: "clock.fill")
            } compactTrailing: {
                Text(Formatters.studyTime(context.state.studySeconds))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "clock.fill")
            }
            .widgetURL(Self.resumeURL)
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<StudyLapseActivityAttributes>

    private var clipLabel: String {
        let count = context.state.clipCount
        return "\(count) clip\(count == 1 ? "" : "s")"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("StudyLapse — Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Formatters.studyTime(context.state.studySeconds))
                    .font(.title2.monospacedDigit())
                Text(clipLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link(destination: URL(string: "studylapse://resume")!) {
                Label("Resume", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
                    .padding(12)
                    .background(Circle().fill(.tint))
                    .foregroundStyle(.white)
            }
        }
        .padding()
        .activityBackgroundTint(Color.black)
        .activitySystemActionForegroundColor(Color.white)
    }
}
