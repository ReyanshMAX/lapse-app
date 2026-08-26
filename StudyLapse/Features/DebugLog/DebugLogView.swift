import SwiftUI
import UIKit

/// Scrollable view over `DebugLog`'s ring buffer with copy-to-clipboard.
/// With no console access during the no-Mac period, this is the only way
/// to see what capture is doing (D-024).
struct DebugLogView: View {
    @State private var lines: [String] = DebugLog.lines

    var body: some View {
        List(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line)
                .font(.system(.footnote, design: .monospaced))
        }
        .navigationTitle("Debug Log")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Refresh") {
                    lines = DebugLog.lines
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Copy") {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                }
            }
        }
        .onAppear {
            lines = DebugLog.lines
        }
    }
}
