import CoreGraphics
import Foundation
import XCTest

/// Minimal pixel helpers for export verification without eyes (docs/TESTING.md).
enum PixelAssertions {
    /// RGBA8 bytes for `image`, drawn into a fresh premultiplied-last context.
    static func rgbaBytes(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (bytes, width, height)
    }

    /// Fraction of pixels in `rect` (image coordinates, origin top-left) whose
    /// channels differ by more than `channelTolerance` between the two images.
    static func fractionDiffering(_ a: CGImage, _ b: CGImage,
                                  in rect: CGRect,
                                  channelTolerance: Int = 12) -> Double {
        let ia = rgbaBytes(a)
        let ib = rgbaBytes(b)
        guard ia.width == ib.width, ia.height == ib.height else { return 1 }

        let minX = max(0, Int(rect.minX))
        let maxX = min(ia.width, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(ia.height, Int(rect.maxY))
        guard maxX > minX, maxY > minY else { return 0 }

        var differing = 0
        var total = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let i = (y * ia.width + x) * 4
                let d = abs(Int(ia.bytes[i]) - Int(ib.bytes[i]))
                    + abs(Int(ia.bytes[i + 1]) - Int(ib.bytes[i + 1]))
                    + abs(Int(ia.bytes[i + 2]) - Int(ib.bytes[i + 2]))
                if d > channelTolerance { differing += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }
}
