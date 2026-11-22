import AppKit
import CoreGraphics
import Foundation

// MARK: - Daily Blueprint Wallpaper Generator

/// Renders a quiet Swiss architectural topographic wallpaper from the user's real
/// annual Marching-Squares contour field, stores it in Application Support, prunes
/// stale images, and applies it cleanly across macOS desktop spaces.
enum WallpaperGenerator {
    private static let maxLongEdge: CGFloat = 3456
    private static let maxShortEdge: CGFloat = 2234
    private static let maxRetainedFiles = 5

    static func wallpaperDirectoryURL(home: String = NSHomeDirectory()) -> URL {
        let dirPath = (AGYLocator.appSupportDir(home: home) as NSString)
            .appendingPathComponent("wallpapers")
        return URL(fileURLWithPath: dirPath, isDirectory: true)
    }

    static func isManagedWallpaperURL(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        let managedDir = wallpaperDirectoryURL(home: home).standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        let filename = url.lastPathComponent
        return candidate.hasPrefix(managedDir) && filename.hasPrefix("agy-blueprint-")
    }

    /// Captures the user's current non-AGYMonitor wallpaper path once before first overwrite.
    static func capturePreviousWallpaperPathIfNeeded(
        existing: String?,
        home: String = NSHomeDirectory()
    ) -> String? {
        if let existing = existing, !existing.isEmpty {
            return existing
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let currentURL = NSWorkspace.shared.desktopImageURL(for: screen),
              !isManagedWallpaperURL(currentURL, home: home) else {
            return nil
        }
        return currentURL.path
    }

    /// Computes capped Retina pixel dimensions matching the main display's real aspect ratio.
    static func targetPixelSize() -> (width: Int, height: Int) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame.size ?? CGSize(width: 1512, height: 982)
        let scale = max(1.0, screen?.backingScaleFactor ?? 2.0)

        var w = max(1280, frame.width * scale)
        var h = max(720, frame.height * scale)

        let scaleFactor = min(
            1.0,
            min(maxLongEdge / max(w, h), maxShortEdge / min(w, h))
        )
        w = (w * scaleFactor).rounded()
        h = (h * scaleFactor).rounded()

        // Ensure even dimensions for crisp pixel alignment.
        let iw = max(1280, Int(w) & ~1)
        let ih = max(720, Int(h) & ~1)
        return (iw, ih)
    }

    /// Renders, saves, prunes, and applies the blueprint wallpaper. Returns the written file URL.
    @discardableResult
    static func generateAndApply(
        yearDays: [String: Int],
        year: Int,
        style: BlueprintWallpaperStyle,
        date: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> URL? {
        let (width, height) = targetPixelSize()
        let todayKey = AppDate.dayKey(date)
        let currentYear = AppDate.gregorian.component(.year, from: date)
        let cutoffKey: String? = (year == currentYear) ? todayKey : nil
        let dayOfYear = AppDate.gregorian.ordinality(of: .day, in: .year, for: date) ?? 1

        let yearPrefix = String(format: "%04d-", year)
        let totalSeconds = yearDays.reduce(0) { acc, pair in
            pair.key.hasPrefix(yearPrefix) ? acc + max(0, pair.value) : acc
        }
        let totalHours = Int((Double(totalSeconds) / 3600.0).rounded())

        let field = InstrumentMath.buildYearContourField(
            days: yearDays,
            year: year,
            levelCount: 12,
            cutoffDayKey: cutoffKey
        )

        guard let cgImage = renderWallpaperCGImage(
            width: width,
            height: height,
            field: field,
            year: year,
            dayOfYear: dayOfYear,
            totalHours: totalHours,
            style: style
        ) else {
            return nil
        }

        let dirURL = wallpaperDirectoryURL(home: home)
        let fm = FileManager.default
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

        // Avoid macOS skipping desktop reload when overwriting the exact same path on the same day.
        let baseName = "agy-blueprint-\(todayKey)-\(style.rawValue)"
        var fileURL = dirURL.appendingPathComponent("\(baseName).png")
        let activeScreenURLs: Set<String> = Set(
            NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL.path }
        )
        if activeScreenURLs.contains(fileURL.standardizedFileURL.path) {
            let comps = AppDate.gregorian.dateComponents([.hour, .minute, .second], from: date)
            let stamp = String(format: "%02d%02d%02d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
            fileURL = dirURL.appendingPathComponent("\(baseName)-\(stamp).png")
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }

        let applied = applyDesktopImage(url: fileURL)
        pruneOldWallpapers(in: dirURL, keepingURL: fileURL)
        return applied ? fileURL : nil
    }

    @discardableResult
    static func applyDesktopImage(url: URL) -> Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        var anySucceeded = false
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
                anySucceeded = true
            } catch {
                continue
            }
        }
        return anySucceeded
    }

    private static func pruneOldWallpapers(in dirURL: URL, keepingURL: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let managed = items.filter {
            $0.lastPathComponent.hasPrefix("agy-blueprint-") && $0.pathExtension.lowercased() == "png"
        }
        guard managed.count > maxRetainedFiles else { return }

        let sorted = managed.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }

        let keepPath = keepingURL.standardizedFileURL.path
        var kept = 0
        for url in sorted {
            if url.standardizedFileURL.path == keepPath {
                kept += 1
                continue
            }
            if kept < maxRetainedFiles {
                kept += 1
            } else {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - CoreGraphics Swiss Architectural Renderer

    private struct Palette {
        let bg: CGColor
        let bgVignette: CGColor
        let gridMinor: CGColor
        let gridMajor: CGColor
        let crosshair: CGColor
        let frameHairline: CGColor
        let contourLow: (r: CGFloat, g: CGFloat, b: CGFloat)
        let contourPeak: (r: CGFloat, g: CGFloat, b: CGFloat)
        let stipple: CGColor
        let futureHatch: CGColor
        let datumLine: CGColor
        let stampPrimary: NSColor
        let stampMuted: NSColor
        let isDark: Bool
    }

    private static func palette(for style: BlueprintWallpaperStyle) -> Palette {
        let cs = CGColorSpaceCreateDeviceRGB()
        func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
            CGColor(colorSpace: cs, components: [r, g, b, a])!
        }

        switch style {
        case .darkMonolith:
            return Palette(
                bg: rgba(0x08 / 255.0, 0x0A / 255.0, 0x0E / 255.0, 1.0), // #080A0E Obsidian
                bgVignette: rgba(0x04 / 255.0, 0x05 / 255.0, 0x08 / 255.0, 0.85),
                gridMinor: rgba(1.0, 1.0, 1.0, 0.028),
                gridMajor: rgba(1.0, 1.0, 1.0, 0.055),
                crosshair: rgba(0x8A / 255.0, 0xA4 / 255.0, 0xD6 / 255.0, 0.14),
                frameHairline: rgba(1.0, 1.0, 1.0, 0.095),
                contourLow: (0x8A / 255.0, 0xA4 / 255.0, 0xD6 / 255.0),
                contourPeak: (0x53 / 255.0, 0x81 / 255.0, 0xFF / 255.0),
                stipple: rgba(0x53 / 255.0, 0x81 / 255.0, 0xFF / 255.0, 0.22),
                futureHatch: rgba(1.0, 1.0, 1.0, 0.055),
                datumLine: rgba(0x8A / 255.0, 0xA4 / 255.0, 0xD6 / 255.0, 0.34),
                stampPrimary: NSColor(srgbRed: 0.92, green: 0.94, blue: 0.98, alpha: 0.56),
                stampMuted: NSColor(srgbRed: 0.58, green: 0.63, blue: 0.74, alpha: 0.42),
                isDark: true
            )

        case .lightGallery:
            return Palette(
                bg: rgba(0xF3 / 255.0, 0xF2 / 255.0, 0xEE / 255.0, 1.0), // #F3F2EE Archival Paper
                bgVignette: rgba(0xE8 / 255.0, 0xE6 / 255.0, 0xE0 / 255.0, 0.65),
                gridMinor: rgba(0.08, 0.09, 0.12, 0.032),
                gridMajor: rgba(0.08, 0.09, 0.12, 0.062),
                crosshair: rgba(0x4B / 255.0, 0x5E / 255.0, 0x88 / 255.0, 0.18),
                frameHairline: rgba(0.08, 0.09, 0.12, 0.12),
                contourLow: (0x4B / 255.0, 0x5E / 255.0, 0x88 / 255.0),
                contourPeak: (0x24 / 255.0, 0x46 / 255.0, 0xFF / 255.0),
                stipple: rgba(0x24 / 255.0, 0x46 / 255.0, 0xFF / 255.0, 0.16),
                futureHatch: rgba(0.08, 0.09, 0.12, 0.055),
                datumLine: rgba(0x4B / 255.0, 0x5E / 255.0, 0x88 / 255.0, 0.36),
                stampPrimary: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.56),
                stampMuted: NSColor(srgbRed: 0.34, green: 0.37, blue: 0.44, alpha: 0.45),
                isDark: false
            )
        }
    }

    private static func renderWallpaperCGImage(
        width: Int,
        height: Int,
        field: ContourFieldResult,
        year: Int,
        dayOfYear: Int,
        totalHours: Int,
        style: BlueprintWallpaperStyle
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let scale = w / 2560.0
        let pal = palette(for: style)

        // 1. Solid archival canvas + subtle radial edge vignette
        ctx.setFillColor(pal.bg)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        if let grad = CGGradient(
            colorsSpace: colorSpace,
            colors: [pal.bg, pal.bgVignette] as CFArray,
            locations: [0.35, 1.0]
        ) {
            let center = CGPoint(x: w * 0.5, y: h * 0.52)
            ctx.drawRadialGradient(
                grad,
                startCenter: center,
                startRadius: min(w, h) * 0.18,
                endCenter: center,
                endRadius: max(w, h) * 0.78,
                options: [.drawsAfterEndLocation]
            )
        }

        // 2. Subtle architectural drafting grid (minor + major lines + `+` reticles)
        let majorStep = (128.0 * scale).rounded()
        let minorStep = majorStep * 0.25
        let originX = (w.truncatingRemainder(dividingBy: majorStep)) * 0.5
        let originY = (h.truncatingRemainder(dividingBy: majorStep)) * 0.5

        ctx.saveGState()
        ctx.setLineWidth(max(1.0, 1.0 * scale))
        ctx.setStrokeColor(pal.gridMinor)
        var x = originX
        while x < w {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: h))
            x += minorStep
        }
        var y = originY
        while y < h {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: w, y: y))
            y += minorStep
        }
        ctx.strokePath()

        ctx.setStrokeColor(pal.gridMajor)
        x = originX
        while x < w {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: h))
            x += majorStep
        }
        y = originY
        while y < h {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: w, y: y))
            y += majorStep
        }
        ctx.strokePath()

        // Crosshair ticks at major grid intersections
        let arm = 4.5 * scale
        ctx.setStrokeColor(pal.crosshair)
        ctx.setLineWidth(max(1.0, 1.15 * scale))
        x = originX
        while x < w {
            y = originY
            while y < h {
                ctx.move(to: CGPoint(x: x - arm, y: y))
                ctx.addLine(to: CGPoint(x: x + arm, y: y))
                ctx.move(to: CGPoint(x: x, y: y - arm))
                ctx.addLine(to: CGPoint(x: x, y: y + arm))
                y += majorStep
            }
            x += majorStep
        }
        ctx.strokePath()
        ctx.restoreGState()

        // 3. Central Topographic Field Plate (generous calm margin for menu bar, dock & icons)
        let plateW = w * 0.74
        let plateH = h * 0.44
        let plateX = (w - plateW) * 0.5
        let plateY = (h - plateH) * 0.5 + h * 0.015
        let plateRect = CGRect(x: plateX, y: plateY, width: plateW, height: plateH)

        // Subtle outer framing hairlines + corner L-reticles around the topographic plate
        ctx.saveGState()
        ctx.setStrokeColor(pal.frameHairline)
        ctx.setLineWidth(max(1.0, 1.0 * scale))
        ctx.stroke(plateRect)

        // 12 monthly meridian lines inside plate
        let monthCols = TimeLogic.monthLabelColumns(year: year).map(\.col)
        for col in monthCols where col > 0 {
            let mx = plateRect.minX + plateRect.width * CGFloat(col) / 53.0
            ctx.move(to: CGPoint(x: mx, y: plateRect.minY))
            ctx.addLine(to: CGPoint(x: mx, y: plateRect.maxY))
        }
        ctx.strokePath()

        // Corner L-brackets
        let bArm = 14.0 * scale
        ctx.setStrokeColor(pal.crosshair)
        ctx.setLineWidth(max(1.2, 1.4 * scale))
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: plateRect.minX, y: plateRect.minY), 1, 1),
            (CGPoint(x: plateRect.maxX, y: plateRect.minY), -1, 1),
            (CGPoint(x: plateRect.minX, y: plateRect.maxY), 1, -1),
            (CGPoint(x: plateRect.maxX, y: plateRect.maxY), -1, -1),
        ]
        for (pt, sx, sy) in corners {
            ctx.move(to: CGPoint(x: pt.x, y: pt.y + sy * bArm))
            ctx.addLine(to: pt)
            ctx.addLine(to: CGPoint(x: pt.x + sx * bArm, y: pt.y))
        }
        ctx.strokePath()
        ctx.restoreGState()

        let padY = plateRect.height * 0.08
        let innerH = max(40, plateRect.height - padY * 2)
        let cutoffX = field.cutoffNormX.map { plateRect.minX + CGFloat($0) * plateRect.width } ?? plateRect.maxX

        func mapPoint(_ p: Point2D) -> CGPoint {
            // CoreGraphics Y is bottom-up; map row 0 (Mon) near top of plate and row 6 (Sun) near bottom.
            let px = plateRect.minX + CGFloat(p.x) * plateRect.width
            let py = plateRect.maxY - padY - CGFloat(p.y) * innerH
            return CGPoint(x: px, y: py)
        }

        // 4. Marching Squares Contours + Glowing Cobalt Peak Ridge
        if !field.levels.isEmpty {
            ctx.saveGState()
            let chartedRect = CGRect(
                x: plateRect.minX,
                y: plateRect.minY,
                width: max(0, cutoffX - plateRect.minX),
                height: plateRect.height
            )
            ctx.clip(to: chartedRect)

            let totalLevels = field.levels.count

            // Subtle basin stipple dots around summit levels
            let summitIdx = min(totalLevels - 1, max(0, (totalLevels * 7) / 12))
            let summitSegs = field.levels[summitIdx].segments
            if !summitSegs.isEmpty {
                ctx.setFillColor(pal.stipple)
                let dotSize = max(1.4, 2.0 * scale)
                for (sIdx, seg) in summitSegs.enumerated() where sIdx % 2 == 0 {
                    let a = mapPoint(seg.a)
                    let b = mapPoint(seg.b)
                    let mid = CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
                    ctx.fill(CGRect(x: mid.x - dotSize * 0.5, y: mid.y - dotSize * 0.5, width: dotSize, height: dotSize))
                }
            }

            // Contour isolines
            for lvl in field.levels {
                guard !lvl.segments.isEmpty else { continue }
                let norm = totalLevels > 1 ? CGFloat(lvl.level) / CGFloat(totalLevels - 1) : 1.0
                let isTopPeak = (lvl.level == totalLevels - 1)
                let isSecondPeak = (lvl.level == totalLevels - 2) && totalLevels >= 2

                let path = CGMutablePath()
                for seg in lvl.segments {
                    path.move(to: mapPoint(seg.a))
                    path.addLine(to: mapPoint(seg.b))
                }

                if isTopPeak {
                    if pal.isDark {
                        // Soft electric cobalt peak glow
                        ctx.saveGState()
                        ctx.setStrokeColor(CGColor(
                            colorSpace: colorSpace,
                            components: [pal.contourPeak.r, pal.contourPeak.g, pal.contourPeak.b, 0.22]
                        )!)
                        ctx.setLineWidth(8.0 * scale)
                        ctx.setLineCap(.round)
                        ctx.addPath(path)
                        ctx.strokePath()
                        ctx.restoreGState()
                    }
                    ctx.setStrokeColor(CGColor(
                        colorSpace: colorSpace,
                        components: [pal.contourPeak.r, pal.contourPeak.g, pal.contourPeak.b, pal.isDark ? 0.92 : 0.85]
                    )!)
                    ctx.setLineWidth(2.2 * scale)
                    ctx.addPath(path)
                    ctx.strokePath()
                } else if isSecondPeak {
                    if pal.isDark {
                        ctx.saveGState()
                        ctx.setStrokeColor(CGColor(
                            colorSpace: colorSpace,
                            components: [pal.contourPeak.r, pal.contourPeak.g, pal.contourPeak.b, 0.12]
                        )!)
                        ctx.setLineWidth(5.0 * scale)
                        ctx.addPath(path)
                        ctx.strokePath()
                        ctx.restoreGState()
                    }
                    ctx.setStrokeColor(CGColor(
                        colorSpace: colorSpace,
                        components: [pal.contourPeak.r, pal.contourPeak.g, pal.contourPeak.b, pal.isDark ? 0.62 : 0.56]
                    )!)
                    ctx.setLineWidth(1.65 * scale)
                    ctx.addPath(path)
                    ctx.strokePath()
                } else if norm >= 0.55 {
                    let t = (norm - 0.55) / 0.45
                    let alpha: CGFloat = pal.isDark ? (0.18 + t * 0.28) : (0.16 + t * 0.24)
                    ctx.setStrokeColor(CGColor(
                        colorSpace: colorSpace,
                        components: [pal.contourPeak.r, pal.contourPeak.g, pal.contourPeak.b, alpha]
                    )!)
                    ctx.setLineWidth((1.15 + t * 0.35) * scale)
                    ctx.addPath(path)
                    ctx.strokePath()
                } else {
                    let t = norm / 0.55
                    let alpha: CGFloat = pal.isDark ? (0.09 + t * 0.16) : (0.08 + t * 0.16)
                    ctx.setStrokeColor(CGColor(
                        colorSpace: colorSpace,
                        components: [pal.contourLow.r, pal.contourLow.g, pal.contourLow.b, alpha]
                    )!)
                    ctx.setLineWidth((0.95 + t * 0.28) * scale)
                    ctx.addPath(path)
                    ctx.strokePath()
                }
            }

            // Quiet circular peak rings at top 3 summits
            for (idx, peak) in field.peaks.enumerated() {
                let pt = mapPoint(Point2D(x: peak.x, y: peak.y))
                let r = (idx == 0 ? 7.5 : 5.5) * scale
                let alpha: CGFloat = idx == 0 ? 0.78 : 0.46
                ctx.setStrokeColor(CGColor(
                    colorSpace: colorSpace,
                    components: [pal.contourPeak.r, pal.contourPeak.g, pal.contourPeak.b, alpha]
                )!)
                ctx.setLineWidth(1.3 * scale)
                ctx.strokeEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                ctx.setFillColor(CGColor(
                    colorSpace: colorSpace,
                    components: [pal.contourPeak.r, pal.contourPeak.g, pal.contourPeak.b, alpha]
                )!)
                let dotR = 1.8 * scale
                ctx.fillEllipse(in: CGRect(x: pt.x - dotR, y: pt.y - dotR, width: dotR * 2, height: dotR * 2))
            }

            ctx.restoreGState()
        }

        // 5. Honest NOW datum + delicate archival future hatch (for current year)
        if field.cutoffNormX != nil && cutoffX < plateRect.maxX - 2.0 {
            let futureRect = CGRect(
                x: cutoffX,
                y: plateRect.minY,
                width: plateRect.maxX - cutoffX,
                height: plateRect.height
            )
            ctx.saveGState()
            ctx.clip(to: futureRect)
            ctx.setStrokeColor(pal.futureHatch)
            ctx.setLineWidth(max(1.0, 1.0 * scale))
            let step = 16.0 * scale
            var hx = futureRect.minX - futureRect.height
            while hx < futureRect.maxX {
                ctx.move(to: CGPoint(x: hx, y: futureRect.minY))
                ctx.addLine(to: CGPoint(x: hx + futureRect.height, y: futureRect.maxY))
                hx += step
            }
            ctx.strokePath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(pal.datumLine)
            ctx.setLineWidth(max(1.1, 1.25 * scale))
            ctx.setLineDash(phase: 0, lengths: [6.0 * scale, 5.0 * scale])
            ctx.move(to: CGPoint(x: cutoffX, y: plateRect.minY))
            ctx.addLine(to: CGPoint(x: cutoffX, y: plateRect.maxY))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 6. Quiet bottom-right archival stamp + AGY vector mark
        let stampText = String(format: "AGY // %04d TOPOGRAPHY · DAY %03d · %d HRS", year, dayOfYear, totalHours)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let fontSize = max(12.0, 14.5 * scale)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: pal.stampPrimary,
            .kern: 1.6 * scale,
        ]
        let attrStr = NSAttributedString(string: stampText, attributes: attrs)
        let textSize = attrStr.size()
        let marginRight = 72.0 * scale
        let marginBottom = 92.0 * scale
        let textOrigin = CGPoint(x: w - marginRight - textSize.width, y: marginBottom)
        attrStr.draw(at: textOrigin)

        // Small AGY logo mark directly left of the stamp text
        let logoSize = fontSize * 1.15
        let logoRect = NSRect(
            x: textOrigin.x - logoSize - 10.0 * scale,
            y: textOrigin.y + (textSize.height - logoSize) * 0.5,
            width: logoSize,
            height: logoSize
        )
        let logoPath = AGYLogo.nsBezierPath(in: logoRect)
        NSColor(
            srgbRed: pal.contourPeak.r,
            green: pal.contourPeak.g,
            blue: pal.contourPeak.b,
            alpha: pal.isDark ? 0.72 : 0.68
        ).setFill()
        logoPath.fill()

        // Delicate hairline rule under the stamp
        let ruleY = textOrigin.y - 7.0 * scale
        let rulePath = NSBezierPath()
        rulePath.move(to: NSPoint(x: logoRect.minX, y: ruleY))
        rulePath.line(to: NSPoint(x: w - marginRight, y: ruleY))
        rulePath.lineWidth = max(1.0, 1.0 * scale)
        pal.stampMuted.setStroke()
        rulePath.stroke()

        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }
}
