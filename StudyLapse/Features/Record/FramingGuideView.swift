import SwiftUI

/// Rule-of-thirds grid plus a centre-crop 9:16 safe-area rectangle, overlaid
/// on the idle-screen camera preview (docs/UI.md screen 1; BUILD.md Phase 7).
/// The safe area matches `AspectPreset.portrait9x16`'s render size
/// (docs/EXPORT.md) — the region that survives export's centre crop.
struct FramingGuideView: View {
    /// width / height of the export's centre-crop target.
    private static let safeAreaAspect: CGFloat = 1080.0 / 1920.0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                thirdsGrid(in: size)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
                safeAreaRect(in: size)
                    .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func thirdsGrid(in size: CGSize) -> Path {
        Path { path in
            let thirdW = size.width / 3
            let thirdH = size.height / 3
            for i in 1...2 {
                path.move(to: CGPoint(x: thirdW * CGFloat(i), y: 0))
                path.addLine(to: CGPoint(x: thirdW * CGFloat(i), y: size.height))
                path.move(to: CGPoint(x: 0, y: thirdH * CGFloat(i)))
                path.addLine(to: CGPoint(x: size.width, y: thirdH * CGFloat(i)))
            }
        }
    }

    /// The 9:16 crop as it would land within a preview of `size`, matching
    /// `AVFoundationSessionExporter.cropTransform`'s centre-crop-to-fill.
    private func safeAreaRect(in size: CGSize) -> Path {
        let rectSize: CGSize
        if size.width / size.height > Self.safeAreaAspect {
            rectSize = CGSize(width: size.height * Self.safeAreaAspect, height: size.height)
        } else {
            rectSize = CGSize(width: size.width, height: size.width / Self.safeAreaAspect)
        }
        let origin = CGPoint(x: (size.width - rectSize.width) / 2,
                             y: (size.height - rectSize.height) / 2)
        return Path(CGRect(origin: origin, size: rectSize))
    }
}
