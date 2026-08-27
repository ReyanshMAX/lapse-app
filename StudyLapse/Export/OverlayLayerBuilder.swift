import AVFoundation
import QuartzCore
import StudyLapseCore
import UIKit

/// The parent/video layer pair the `AVVideoCompositionCoreAnimationTool` needs.
///
/// Deviation from BUILD.md's `OverlayLayerBuilder.build(...) -> CALayer`
/// contract: the Core Animation tool requires *both* the video layer and its
/// superlayer, and they must be wired together before the tool is constructed.
/// Returning the pair is clearer than having the caller dig the video layer out
/// of `parent.sublayers` by name. See docs/EXPORT.md.
struct OverlayLayers {
    let parent: CALayer
    let video: CALayer
}

/// Builds the CALayer tree burned into the export by
/// `AVVideoCompositionCoreAnimationTool`. The timer shows **study time**, not
/// output time (docs/EXPORT.md): the composition is uniformly scaled, so a
/// discrete keyframe stack of pre-rendered text layers is switched on and off
/// over the output timeline.
enum OverlayLayerBuilder {
    /// Corner inset on each axis, in render-space points (docs/EXPORT.md).
    static let cornerInset: CGFloat = 48

    static func build(renderSize: CGSize,
                      style: OverlayStyle,
                      corner: OverlayCorner,
                      totalStudySeconds: Double,
                      outputDuration: Double,
                      includeIntroCard: Bool,
                      introText: String,
                      includeOutroCard: Bool,
                      outroText: String) -> OverlayLayers {
        let bounds = CGRect(origin: .zero, size: renderSize)

        let parent = CALayer()
        parent.frame = bounds
        // Layer coordinates match video orientation (docs/EXPORT.md).
        parent.isGeometryFlipped = true

        let video = CALayer()
        video.frame = bounds
        parent.addSublayer(video)

        if includeIntroCard {
            parent.addSublayer(cardLayer(text: introText, bounds: bounds, fadeOutAt: 1.5))
        }

        parent.addSublayer(timerLayer(renderSize: renderSize, style: style, corner: corner,
                                      totalStudySeconds: totalStudySeconds,
                                      outputDuration: outputDuration))

        if includeOutroCard, outputDuration > 1.5 {
            parent.addSublayer(cardLayer(text: outroText, bounds: bounds,
                                         fadeInAt: outputDuration - 1.5))
        }

        return OverlayLayers(parent: parent, video: video)
    }

    // MARK: Timer

    private static func timerLayer(renderSize: CGSize,
                                   style: OverlayStyle,
                                   corner: OverlayCorner,
                                   totalStudySeconds: Double,
                                   outputDuration: Double) -> CALayer {
        let granularity: TimerGranularity = totalStudySeconds < 600 ? .seconds : .minutes
        let keyframes = TimerOverlay.timerKeyframes(totalStudySeconds: totalStudySeconds,
                                                    outputDuration: outputDuration,
                                                    granularity: granularity)

        let (fontName, fontSize, hasShadow, hasBackground) = styleAttributes(style)
        let widest = keyframes.map(\.text).max(by: { $0.count < $1.count }) ?? "0:00"
        let textSize = measured(widest, fontName: fontName, fontSize: fontSize)
        let padding: CGFloat = hasBackground ? 12 : 0
        let boxSize = CGSize(width: textSize.width + padding * 2,
                             height: textSize.height + padding * 2)

        let container = CALayer()
        container.frame = CGRect(origin: originFor(corner: corner, boxSize: boxSize,
                                                   renderSize: renderSize),
                                 size: boxSize)

        if hasBackground {
            container.backgroundColor = UIColor.black.withAlphaComponent(0.6).cgColor
            container.cornerRadius = 14
        }

        let d = max(outputDuration, 0.0001)
        for (i, keyframe) in keyframes.enumerated() {
            let text = CATextLayer()
            text.string = keyframe.text
            text.font = fontName as CFString
            text.fontSize = fontSize
            text.foregroundColor = UIColor.white.cgColor
            text.alignmentMode = .center
            text.contentsScale = 2
            text.frame = CGRect(x: padding, y: padding,
                                width: textSize.width, height: textSize.height)
            if hasShadow {
                text.shadowColor = UIColor.black.cgColor
                text.shadowOpacity = 0.6
                text.shadowRadius = 4
                text.shadowOffset = CGSize(width: 0, height: 2)
            }

            let start = min(keyframe.time / d, 0.999_999)
            let end = (i == keyframes.count - 1) ? 1.0 : min(keyframes[i + 1].time / d, 1.0)

            if keyframes.count == 1 {
                text.opacity = 1
            } else {
                text.opacity = 0
                text.add(opacityAnimation(start: start, end: end, duration: d),
                         forKey: "opacity")
            }
            container.addSublayer(text)
        }
        return container
    }

    /// Discrete opacity animation making a layer visible during `[start, end)`
    /// of a normalised 0…1 timeline. `keyTimes.count == values.count + 1` for
    /// `.discrete` (Core Animation).
    private static func opacityAnimation(start: Double, end: Double,
                                         duration: Double) -> CAKeyframeAnimation {
        let s = min(max(start, 0), 1)
        let e = min(max(end, s), 1)

        var bounds: [Double] = [0]
        var values: [Double] = []
        if s > 0 {
            values.append(0)
            bounds.append(s)
        }
        values.append(1)
        bounds.append(max(e, s + 1e-9))
        if bounds.last! < 1 {
            values.append(0)
            bounds.append(1)
        }
        // Guarantee strictly increasing bounds ending at exactly 1.
        bounds = normaliseBounds(bounds)

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.calculationMode = .discrete
        anim.keyTimes = bounds.map { NSNumber(value: $0) }
        anim.values = values.map { NSNumber(value: $0) }
        anim.duration = duration
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        return anim
    }

    private static func normaliseBounds(_ input: [Double]) -> [Double] {
        var out: [Double] = []
        for value in input {
            let clamped = min(max(value, 0), 1)
            if let last = out.last {
                out.append(max(clamped, last + 1e-9))
            } else {
                out.append(clamped)
            }
        }
        if let last = out.last, last < 1 { out[out.count - 1] = 1 }
        return out
    }

    private static func styleAttributes(_ style: OverlayStyle)
        -> (fontName: String, fontSize: CGFloat, shadow: Bool, background: Bool) {
        switch style {
        case .minimal: return ("Menlo-Bold", 64, true, false)
        case .boxed:   return ("Menlo-Bold", 64, false, true)
        case .mono:    return ("Menlo", 96, false, false)
        }
    }

    private static func originFor(corner: OverlayCorner, boxSize: CGSize,
                                  renderSize: CGSize) -> CGPoint {
        // Layer space is top-left origin because `parent.isGeometryFlipped`.
        let maxX = renderSize.width - boxSize.width - cornerInset
        let maxY = renderSize.height - boxSize.height - cornerInset
        switch corner {
        case .topLeft:     return CGPoint(x: cornerInset, y: cornerInset)
        case .topRight:    return CGPoint(x: maxX, y: cornerInset)
        case .bottomLeft:  return CGPoint(x: cornerInset, y: maxY)
        case .bottomRight: return CGPoint(x: maxX, y: maxY)
        }
    }

    // MARK: Cards

    private static func cardLayer(text: String, bounds: CGRect,
                                  fadeOutAt: Double? = nil,
                                  fadeInAt: Double? = nil) -> CALayer {
        let background = CALayer()
        background.frame = bounds
        background.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1).cgColor

        let label = CATextLayer()
        label.string = text
        label.font = "Menlo-Bold" as CFString
        label.fontSize = 56
        label.foregroundColor = UIColor.white.cgColor
        label.alignmentMode = .center
        label.isWrapped = true
        label.contentsScale = 2
        label.frame = bounds.insetBy(dx: 64, dy: max(bounds.height / 2 - 120, 0))
        background.addSublayer(label)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        fade.duration = 0.4
        if let fadeOutAt {
            background.opacity = 1
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.beginTime = AVCoreAnimationBeginTimeAtZero + fadeOutAt
            background.add(fade, forKey: "opacity")
        } else if let fadeInAt {
            background.opacity = 0
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.beginTime = AVCoreAnimationBeginTimeAtZero + fadeInAt
            background.add(fade, forKey: "opacity")
        }
        return background
    }

    private static func measured(_ text: String, fontName: String, fontSize: CGFloat) -> CGSize {
        let font = UIFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width) + 8, height: ceil(size.height) + 4)
    }
}
