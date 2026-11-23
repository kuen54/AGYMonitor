import AppKit
import SwiftUI

// ── Antigravity logo path data (single source of truth) ──
//
// Official Google Antigravity vector mark (viewBox 0 0 113 113, y axis top-down,
// SVG convention).
//
// Rendered in two contexts from this single command list:
//   - SwiftUI Path (LogoShape / AGYLogoShape) — used by the popover header, the
//     notch pill, and the menu-bar icon via SessionAwareLogo
//   - NSBezierPath — the standalone app icon generator (generate_icon.swift,
//     compiled together with this file by build.sh)
enum AGYLogo {
    enum Command {
        case move(CGFloat, CGFloat)
        case line(CGFloat, CGFloat)
        case curve(CGFloat, CGFloat, c1x: CGFloat, c1y: CGFloat, c2x: CGFloat, c2y: CGFloat)
        case close
    }

    /// Original SVG coordinate space edge length (`viewBox="0 0 113 113"`).
    static let viewBoxSize: CGFloat = 113.0

    /// Optically centered square normalization box around the ink bounds
    /// (`x: 13.95…97.50`, `y: 18.445…95.334`, symmetry axis `x = 55.8659`,
    /// vertical midpoint `y = 56.89`). Side 92 gives crisp menu-bar weight at
    /// rest while keeping all wingtips inside the rotation sweep during 360° spin.
    static let normalizedBox = CGRect(x: 9.8659, y: 10.89, width: 92.0, height: 92.0)

    static let commands: [Command] = [
        .move(89.6992, 93.695),
        .curve(94.9492, 88.445, c1x: 94.3659, c1y: 97.195, c2x: 101.366, c2y: 94.8617),
        .curve(55.8659, 18.445, c1x: 75.6992, c1y: 69.7783, c2x: 79.7825, c2y: 18.445),
        .curve(16.7825, 88.445, c1x: 31.9492, c1y: 18.445, c2x: 36.0325, c2y: 69.7783),
        .curve(22.0325, 93.695, c1x: 9.78251, c1y: 95.445, c2x: 17.3658, c2y: 97.195),
        .curve(55.8659, 59.8617, c1x: 40.1159, c1y: 81.445, c2x: 38.9492, c2y: 59.8617),
        .curve(89.6992, 93.695, c1x: 72.7825, c1y: 59.8617, c2x: 71.6159, c2y: 81.445),
        .close,
    ]

    /// Builds an NSBezierPath by mapping every SVG-space point through `transform`
    /// (callers own scaling and SVG top-down → AppKit bottom-up y flip).
    static func nsBezierPath(transform: (CGFloat, CGFloat) -> NSPoint) -> NSBezierPath {
        let path = NSBezierPath()
        for cmd in commands {
            switch cmd {
            case let .move(x, y):
                path.move(to: transform(x, y))
            case let .line(x, y):
                path.line(to: transform(x, y))
            case let .curve(x, y, c1x, c1y, c2x, c2y):
                path.curve(to: transform(x, y),
                           controlPoint1: transform(c1x, c1y),
                           controlPoint2: transform(c2x, c2y))
            case .close:
                path.close()
            }
        }
        return path
    }

    /// Builds an aspect-fitted, optically centered NSBezierPath inside `rect`
    /// (flipping SVG top-down y to AppKit bottom-up y).
    static func nsBezierPath(in rect: NSRect) -> NSBezierPath {
        let box = normalizedBox
        guard box.width > 0, box.height > 0, rect.width > 0, rect.height > 0 else {
            return NSBezierPath()
        }
        let scale = min(rect.width / box.width, rect.height / box.height)
        let ox = rect.minX + (rect.width - box.width * scale) / 2.0
        let oy = rect.minY + (rect.height - box.height * scale) / 2.0
        return nsBezierPath { x, y in
            NSPoint(
                x: ox + (x - box.minX) * scale,
                y: oy + (box.maxY - y) * scale
            )
        }
    }

    /// Builds a SwiftUI Path scaled by `s` points per raw SVG unit (`0…113` space,
    /// top-down orientation matching SwiftUI).
    static func swiftUIPath(scale s: CGFloat) -> SwiftUI.Path {
        var p = SwiftUI.Path()
        for cmd in commands {
            switch cmd {
            case let .move(x, y):
                p.move(to: CGPoint(x: x * s, y: y * s))
            case let .line(x, y):
                p.addLine(to: CGPoint(x: x * s, y: y * s))
            case let .curve(x, y, c1x, c1y, c2x, c2y):
                p.addCurve(to: CGPoint(x: x * s, y: y * s),
                           control1: CGPoint(x: c1x * s, y: c1y * s),
                           control2: CGPoint(x: c2x * s, y: c2y * s))
            case .close:
                p.closeSubpath()
            }
        }
        return p
    }

    /// Builds an aspect-fitted, optically centered `CGPath` inside `rect`.
    /// - Parameter flippedForCoreAnimation: Pass `false` (default) for top-down coordinate
    ///   systems (SwiftUI, flipped `NSView` / `CALayer` with `isGeometryFlipped == true`).
    ///   Pass `true` for standard bottom-up Core Animation / Core Graphics contexts
    ///   (`isGeometryFlipped == false`).
    static func cgPath(in rect: CGRect, flippedForCoreAnimation: Bool = false) -> CGPath {
        let box = normalizedBox
        guard box.width > 0, box.height > 0, rect.width > 0, rect.height > 0 else {
            return CGMutablePath()
        }
        let scale = min(rect.width / box.width, rect.height / box.height)
        let ox = rect.minX + (rect.width - box.width * scale) / 2.0
        let oy = rect.minY + (rect.height - box.height * scale) / 2.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let py = flippedForCoreAnimation
                ? oy + (box.maxY - y) * scale
                : oy + (y - box.minY) * scale
            return CGPoint(x: ox + (x - box.minX) * scale, y: py)
        }
        let path = CGMutablePath()
        for cmd in commands {
            switch cmd {
            case let .move(x, y):
                path.move(to: pt(x, y))
            case let .line(x, y):
                path.addLine(to: pt(x, y))
            case let .curve(x, y, c1x, c1y, c2x, c2y):
                path.addCurve(to: pt(x, y),
                              control1: pt(c1x, c1y),
                              control2: pt(c2x, c2y))
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    /// Builds an aspect-fitted, optically centered SwiftUI Path inside `rect`
    /// (normalized from the `0…113` SVG viewBox so small menu-bar/header frames
    /// render with balanced visual weight).
    static func swiftUIPath(in rect: CGRect) -> SwiftUI.Path {
        SwiftUI.Path(cgPath(in: rect, flippedForCoreAnimation: false))
    }
}
