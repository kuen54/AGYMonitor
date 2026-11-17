import Cocoa

// Generate AGYMonitor app icon: Antigravity delta logo rendered with an ASCII
// character texture (`AGY` + character ramp in Menlo-Bold) in Antigravity's
// cosmic blue-indigo brand palette onto a warm off-white macOS squircle.

// ── Render Antigravity logo to a mask bitmap (1.0 = inside logo, 0.0 = outside) ──

func renderLogoMask(size: Int) -> [[Double]] {
    let s = CGFloat(size)
    let padding = s * 0.18
    let logoArea = s - padding * 2
    let logoRect = NSRect(x: padding, y: padding, width: logoArea, height: logoArea)

    // Use NSBitmapImageRep directly to avoid Retina 2x backing scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: s, height: s).fill()

    // Antigravity logo path data shared with the app (Sources/AGYLogo.swift —
    // build.sh compiles it into this standalone tool alongside this file).
    let path = AGYLogo.nsBezierPath(in: logoRect)
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    var mask = Array(repeating: Array(repeating: 0.0, count: size), count: size)
    for y in 0..<size {
        for x in 0..<size {
            let c = rep.colorAt(x: x, y: y) ?? NSColor.white
            let brightness = c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114
            mask[y][x] = brightness < 0.5 ? 1.0 : 0.0  // 1.0 = inside logo
        }
    }
    return mask
}

// ── Render icon with ASCII character texture ──

func renderIcon(outputSize: Int) -> NSImage {
    let s = CGFloat(outputSize)
    let maskSize = 512
    let mask = renderLogoMask(size: maskSize)

    // ASCII character grid parameters
    let font = NSFont(name: "Menlo-Bold", size: s * 0.018)
        ?? NSFont.monospacedSystemFont(ofSize: s * 0.018, weight: .bold)
    let sampleAttrs: [NSAttributedString.Key: Any] = [.font: font]
    let charSize = "W".size(withAttributes: sampleAttrs)
    let cols = max(1, Int(s / charSize.width))
    let rows = max(1, Int(s / charSize.height))

    // Deterministic character ramp weaving "AGY" motif with dense ASCII symbols
    let agyMotif: [Character] = ["A", "G", "Y"]
    let asciiChars = Array("AGY@#$%&*+=~?/\\|{}[]()<>!^;:.,0123456789AGYABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    func charAt(_ row: Int, _ col: Int, insideLogo: Bool) -> Character {
        if insideLogo && ((row &* 5 &+ col) % 9 < 3) {
            return agyMotif[(col &+ row &* 2) % 3]
        }
        let hash = (row &* 7919) &+ (col &* 6271) &+ 3571
        return asciiChars[abs(hash) % asciiChars.count]
    }

    // Antigravity cosmic brand gradient: deep indigo-violet apex → vibrant cobalt → luminous azure wings
    func logoColorAt(row: Int, col: Int) -> NSColor {
        let v = CGFloat(row) / CGFloat(max(1, rows - 1))  // 0 = top apex, 1 = bottom wings
        let h = abs(CGFloat(col) / CGFloat(max(1, cols - 1)) - 0.5) * 2.0  // 0 = center, 1 = outer edge
        let t = min(1.0, max(0.0, v * 0.78 + h * 0.22))
        // Top (#5347F5) -> Mid (#3B66F5) -> Outer/Bottom (#2088F2)
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        if t < 0.5 {
            let u = t * 2.0
            r = 0.325 * (1 - u) + 0.231 * u
            g = 0.278 * (1 - u) + 0.400 * u
            b = 0.961 * (1 - u) + 0.961 * u
        } else {
            let u = (t - 0.5) * 2.0
            r = 0.231 * (1 - u) + 0.125 * u
            g = 0.400 * (1 - u) + 0.533 * u
            b = 0.961 * (1 - u) + 0.949 * u
        }
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    let bgCharColor = NSColor(red: 0.875, green: 0.880, blue: 0.900, alpha: 1.0)

    // Use NSBitmapImageRep directly to avoid Retina 2x backing scale
    let iconRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: outputSize, pixelsHigh: outputSize,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    iconRep.size = NSSize(width: outputSize, height: outputSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: iconRep)!

    // ── Squircle clip (0.2237 macOS icon corner radius) ──
    let radius = s * 0.2237
    let squircle = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                                 xRadius: radius, yRadius: radius)
    squircle.addClip()

    // ── Warm off-white background ──
    NSColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1.0).setFill()
    squircle.fill()

    // ── Draw ASCII character grid ──
    for row in 0..<rows {
        for col in 0..<cols {
            let x = CGFloat(col) * charSize.width
            let y = s - CGFloat(row + 1) * charSize.height  // flip y for AppKit

            // Sample cell center in the mask to determine if inside the Antigravity mark
            let maskX = Int((CGFloat(col) + 0.5) / CGFloat(cols) * CGFloat(maskSize))
            let maskY = Int((CGFloat(row) + 0.5) / CGFloat(rows) * CGFloat(maskSize))
            let mx = min(max(maskX, 0), maskSize - 1)
            let my = min(max(maskY, 0), maskSize - 1)
            let insideLogo = mask[my][mx] > 0.5

            let color = insideLogo ? logoColorAt(row: row, col: col) : bgCharColor
            let ch = String(charAt(row, col, insideLogo: insideLogo))
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            ch.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }

    // ── Subtle border ──
    NSColor(white: 0.82, alpha: 1.0).setStroke()
    squircle.lineWidth = s * 0.003
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()

    let img = NSImage(size: NSSize(width: outputSize, height: outputSize))
    img.addRepresentation(iconRep)
    return img
}

// ── Encode PNG & ICNS ──

func encodePNG(_ image: NSImage, size: Int, retina: Bool) -> Data? {
    // Use NSBitmapImageRep directly to avoid Retina 2x backing scale issues.
    // Set logical point size (`size / 2` for @2x) so PNG pHYs DPI metadata is 144 DPI
    // on @2x variants and 72 DPI on 1x variants.
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ptSize = retina ? CGFloat(size) / 2.0 : CGFloat(size)
    rep.size = NSSize(width: ptSize, height: ptSize)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: ptSize, height: ptSize))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

/// Writes a spec-compliant Apple `.icns` container directly from PNG representations
/// (`icp4`/`ic11`/`icp5`/`ic12`/`ic07`/`ic13`/`ic08`/`ic14`/`ic09`/`ic10`), so builds
/// also succeed in sandboxed environments where `iconutil`'s XPC/temp-dir access is blocked.
func writeICNS(chunks: [(tag: String, png: Data)], to url: URL) {
    func beUInt32(_ v: UInt32) -> Data {
        var big = v.bigEndian
        return Data(bytes: &big, count: 4)
    }

    var body = Data()
    for (tag, png) in chunks {
        guard let tagBytes = tag.data(using: .ascii), tagBytes.count == 4 else { continue }
        body.append(tagBytes)
        body.append(beUInt32(UInt32(8 + png.count)))
        body.append(png)
    }
    var out = Data("icns".utf8)
    out.append(beUInt32(UInt32(8 + body.count)))
    out.append(body)
    try? out.write(to: url, options: .atomic)
}

// ── Main ──
// Wrapped in @main (not top-level statements) because build.sh compiles this file
// together with Sources/AGYLogo.swift — in a multi-file swiftc invocation only a
// file literally named main.swift may contain top-level code.

@main
enum GenerateIcon {
    static func main() {
        let icon = renderIcon(outputSize: 1024)

        let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
        let iconsetURL = URL(fileURLWithPath: iconsetPath)
        try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

        let entries: [(name: String, tag: String, px: Int, retina: Bool)] = [
            ("icon_16x16.png",      "icp4", 16,   false),
            ("icon_16x16@2x.png",   "ic11", 32,   true),
            ("icon_32x32.png",      "icp5", 32,   false),
            ("icon_32x32@2x.png",   "ic12", 64,   true),
            ("icon_128x128.png",    "ic07", 128,  false),
            ("icon_128x128@2x.png", "ic13", 256,  true),
            ("icon_256x256.png",    "ic08", 256,  false),
            ("icon_256x256@2x.png", "ic14", 512,  true),
            ("icon_512x512.png",    "ic09", 512,  false),
            ("icon_512x512@2x.png", "ic10", 1024, true),
        ]

        var icnsChunks: [(tag: String, png: Data)] = []
        for entry in entries {
            guard let png = encodePNG(icon, size: entry.px, retina: entry.retina) else { continue }
            try? png.write(to: iconsetURL.appendingPathComponent(entry.name), options: .atomic)
            icnsChunks.append((tag: entry.tag, png: png))
        }

        // Also write the `.icns` directly (either explicit argv[2] or sibling `<name>.icns`
        // when argv[1] ends with `.iconset`) so sandboxed builds work without `iconutil`.
        let icnsURL: URL? = {
            if CommandLine.arguments.count > 2 {
                return URL(fileURLWithPath: CommandLine.arguments[2])
            }
            if iconsetPath.hasSuffix(".iconset") {
                let stem = String(iconsetPath.dropLast(".iconset".count))
                return URL(fileURLWithPath: stem + ".icns")
            }
            return nil
        }()
        if let icnsURL = icnsURL {
            writeICNS(chunks: icnsChunks, to: icnsURL)
        }

        print("Generated ASCII-textured Antigravity icon in \(iconsetPath)")
    }
}
