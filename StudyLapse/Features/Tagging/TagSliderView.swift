import StudyLapseCore
import SwiftData
import SwiftUI

/// Slider / refine mode (docs/UI.md §4): a horizontal track spanning total
/// study time with draggable boundary handles. Dragging a handle resizes the
/// two adjacent ranges live (`TagRangeMath.resize` via `TagEditor`), persisting
/// only on release so a many-range session doesn't write per drag frame
/// (criterion 4). Tap a segment to tag it; Split halves the selected segment.
struct TagSliderView: View {
    @Bindable var editor: TagEditor
    let context: ModelContext
    let onEditTags: (Int) -> Void

    @State private var selected: Int = 0
    @State private var draggingBoundary: Int?

    private let trackHeight: CGFloat = 64
    private let handleWidth: CGFloat = 22

    private var total: Double { max(editor.totalStudySeconds, 1) }

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    segments(width: width)
                    handles(width: width)
                }
                .frame(height: trackHeight)
            }
            .frame(height: trackHeight)
            .padding(.horizontal)

            controls
            Spacer()
        }
        .padding(.top, 8)
        .screenBackground()
    }

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat(seconds / total) * width
    }

    private func seconds(forX px: CGFloat, width: CGFloat) -> Double {
        Double(max(0, min(px, width)) / max(width, 1)) * total
    }

    @ViewBuilder
    private func segments(width: CGFloat) -> some View {
        ForEach(Array(editor.ranges.enumerated()), id: \.offset) { index, range in
            let x0 = x(for: range.start, width: width)
            let x1 = x(for: range.end, width: width)
            let fill = range.tags.first.map { tagColor($0, in: context) } ?? .slTextSecondary
            Rectangle()
                .fill(fill.opacity(index == selected ? 0.6 : 0.3))
                .overlay(Rectangle().stroke(Color.slTextPrimary.opacity(index == selected ? 0.5 : 0.15)))
                .frame(width: max(x1 - x0, 1), height: trackHeight)
                .offset(x: x0)
                // Segment label: `.overlay(alignment: .center)` on this
                // (already-offset) rectangle already centers within its own
                // [x0, x1] frame — no extra offset math needed. The previous
                // version added `x0 + (x1-x0)/2 - width/2` on top of that,
                // which double-shifted the label away from segment center for
                // any segment not already centered in the middle of the whole
                // track (STATUS.md known rough edge).
                .overlay(alignment: .center) {
                    if x1 - x0 > 40 {
                        Text(range.tags.isEmpty ? "—" : range.tags.joined(separator: ", "))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.slTextPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                }
                .onTapGesture {
                    selected = index
                    onEditTags(index)
                }
        }
    }

    @ViewBuilder
    private func handles(width: CGFloat) -> some View {
        ForEach(Array(1..<max(editor.ranges.count, 1)), id: \.self) { boundary in
            let seconds = editor.ranges[boundary].start
            Capsule()
                .fill(Color.slTextPrimary.opacity(0.85))
                .frame(width: handleWidth, height: trackHeight + 12)
                .offset(x: x(for: seconds, width: width) - handleWidth / 2, y: -6)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            draggingBoundary = boundary - 1
                            editor.previewResize(boundaryIndex: boundary - 1,
                                                 to: self.seconds(forX: value.location.x, width: width))
                        }
                        .onEnded { _ in
                            editor.commitResize()
                            draggingBoundary = nil
                        }
                )
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            Button("Split") {
                guard editor.ranges.indices.contains(selected) else { return }
                let r = editor.ranges[selected]
                editor.split(at: (r.start + r.end) / 2)
            }
            .buttonStyle(.bordered)

            Button("Merge →") {
                guard selected < editor.ranges.count - 1 else { return }
                editor.merge(at: selected)
            }
            .buttonStyle(.bordered)
            .disabled(selected >= editor.ranges.count - 1)

            Spacer()

            if editor.ranges.indices.contains(selected) {
                let r = editor.ranges[selected]
                Text("\(Formatters.minutesSeconds(r.start)) – \(Formatters.minutesSeconds(r.end))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.slTextSecondary)
            }
        }
        .padding(.horizontal)
    }
}
