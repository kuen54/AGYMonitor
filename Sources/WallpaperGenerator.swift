import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    static func fileExists(atPath path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: trimmed)
    }

    static func isManagedWallpaperURL(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        let directoryURL = wallpaperDirectoryURL(home: home)
        return BlueprintWallpaperPath.isManagedPath(
            url.standardizedFileURL.path,
            directoryPath: directoryURL.standardizedFileURL.path
        )
    }

    /// Captures the user's current non-AGYMonitor wallpaper path once before overwrite.
    /// Validates any existing saved path still exists and is not a managed AGY wallpaper;
    /// if missing or managed, captures the active screen's current desktop image path.
    static func capturePreviousWallpaperPathIfNeeded(
        existingSavedPath: String?,
        home: String = NSHomeDirectory()
    ) -> String? {
        let dirPath = wallpaperDirectoryURL(home: home).standardizedFileURL.path
        if let saved = existingSavedPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty,
           !BlueprintWallpaperPath.isManagedPath(saved, directoryPath: dirPath),
           fileExists(atPath: saved) {
            return saved
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let currentURL = NSWorkspace.shared.desktopImageURL(for: screen),
              !isManagedWallpaperURL(currentURL, home: home),
              fileExists(atPath: currentURL.path) else {
            return nil
        }
        return currentURL.path
    }

    /// Computes capped Retina pixel dimensions matching the main display's real aspect ratio.
    /// Pure CoreGraphics (no `NSScreen` access) so it is safe to call off the main thread.
    static func targetPixelSize(maxPixelWidth: Int = 3456) -> (width: Int, height: Int) {
        let displayID = CGMainDisplayID()
        let rawW: CGFloat
        let rawH: CGFloat
        if let mode = CGDisplayCopyDisplayMode(displayID),
           mode.pixelWidth > 0, mode.pixelHeight > 0 {
            rawW = CGFloat(mode.pixelWidth)
            rawH = CGFloat(mode.pixelHeight)
        } else {
            let pw = CGDisplayPixelsWide(displayID)
            let ph = CGDisplayPixelsHigh(displayID)
            if pw > 0, ph > 0 {
                rawW = CGFloat(pw)
                rawH = CGFloat(ph)
            } else {
                rawW = 3024
                rawH = 1964
            }
        }

        var w = max(1280, rawW.isFinite ? rawW : 3024)
        var h = max(720, rawH.isFinite ? rawH : 1964)

        let longCap = CGFloat(max(1280, min(maxPixelWidth, Int(maxLongEdge))))
        let shortCap = min(maxShortEdge, longCap)
        let scaleFactor = min(
            1.0,
            min(longCap / max(w, h), shortCap / min(w, h))
        )
        w = (w * scaleFactor).rounded()
        h = (h * scaleFactor).rounded()

        // Ensure even dimensions for crisp pixel alignment (guarded against non-finite values).
        let clampedW = w.isFinite ? min(max(1280, w), maxLongEdge) : 1280
        let clampedH = h.isFinite ? min(max(720, h), maxShortEdge) : 720
        let iw = max(1280, Int(clampedW) & ~1)
        let ih = max(720, Int(clampedH) & ~1)
        return (iw, ih)
    }

    /// Pure off-main-thread-safe CoreGraphics render + atomic PNG write + pruning (5 files).
    /// Accepts `[String: Double]` day-seconds values and returns the written PNG file URL.
    static func renderBlueprintPNG(
        days: [String: Double],
        year: Int,
        style: BlueprintWallpaperStyle,
        dateKey: String,
        maxPixelWidth: Int = 3456,
        home: String = NSHomeDirectory()
    ) -> URL? {
        var intDays: [String: Int] = [:]
        intDays.reserveCapacity(days.count)
        let maxDaySeconds = 86_400.0 * 366.0
        for (k, v) in days {
            guard v.isFinite else { continue }
            let clamped = min(max(0.0, v), maxDaySeconds).rounded()
            intDays[k] = Int(clamped)
        }
        return renderBlueprintPNG(
            days: intDays,
            year: year,
            style: style,
            dateKey: dateKey,
            maxPixelWidth: maxPixelWidth,
            home: home
        )
    }

    /// Pure off-main-thread-safe CoreGraphics render + atomic PNG write + pruning (5 files).
    /// Accepts `[String: Int]` day-seconds values and returns the written PNG file URL.
    static func renderBlueprintPNG(
        days: [String: Int],
        year: Int,
        style: BlueprintWallpaperStyle,
        dateKey: String,
        maxPixelWidth: Int = 3456,
        home: String = NSHomeDirectory()
    ) -> URL? {
        let (width, height) = targetPixelSize(maxPixelWidth: maxPixelWidth)
        let yearPrefix = String(format: "%04d-", year)
        let trimmedKey = dateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDateKey = trimmedKey.isEmpty ? AppDate.dayKey(Date()) : trimmedKey
        let cutoffKey: String? = effectiveDateKey.hasPrefix(yearPrefix) ? effectiveDateKey : nil
        let dayOrdinal = dayOfYear(for: effectiveDateKey)

        let totalSeconds = days.reduce(0) { acc, pair in
            pair.key.hasPrefix(yearPrefix) ? acc + max(0, pair.value) : acc
        }
        let totalHoursRaw = (Double(totalSeconds) / 3600.0).rounded()
        let totalHours = totalHoursRaw.isFinite
            ? Int(min(max(0.0, totalHoursRaw), Double(Int.max / 2)))
            : 0

        let field = InstrumentMath.buildYearContourField(
            days: days,
            year: year,
            levelCount: 12,
            cutoffDayKey: cutoffKey
        )

        guard let cgImage = renderWallpaperCGImage(
            width: width,
            height: height,
            field: field,
            year: year,
            dayOfYear: dayOrdinal,
            totalHours: totalHours,
            style: style
        ) else {
            return nil
        }

        guard let pngData = encodePNGData(from: cgImage) else {
            return nil
        }

        let dirURL = wallpaperDirectoryURL(home: home)
        let fm = FileManager.default
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

        // Unique millisecond + UUID suffix guarantees same-second repeat applies never collide
        // on disk or hit macOS's identical-URL desktop-reload skip.
        let nowMsRaw = (Date().timeIntervalSince1970 * 1000.0).rounded()
        let ms: Int64 = nowMsRaw.isFinite
            ? Int64(min(max(0.0, nowMsRaw), Double(Int64.max / 2)))
            : 0
        let token = UUID().uuidString.prefix(8).lowercased()
        let fileName = "agy-blueprint-\(effectiveDateKey)-\(style.rawValue)-\(ms)-\(token).png"
        let fileURL = dirURL.appendingPathComponent(fileName)

        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }

        pruneOldWallpapers(in: dirURL, keepingURL: fileURL)
        return fileURL
    }

    /// Main-thread desktop wallpaper application across all connected `NSScreen` instances.
    @discardableResult
    static func applyDesktopImage(at url: URL) -> Bool {
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

    /// Compatibility overload forwarding to `applyDesktopImage(at:)`.
    @discardableResult
    static func applyDesktopImage(url: URL) -> Bool {
        applyDesktopImage(at: url)
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
        let todayKey = AppDate.dayKey(date)
        guard let fileURL = renderBlueprintPNG(
            days: yearDays,
            year: year,
            style: style,
            dateKey: todayKey,
            home: home
        ) else {
            return nil
        }
        return applyDesktopImage(at: fileURL) ? fileURL : nil
    }

    private static func dayOfYear(for dateKey: String) -> Int {
        let parts = dateKey.split(separator: "-")
        if parts.count == 3,
           let y = Int(parts[0]),
           let m = Int(parts[1]),
           let d = Int(parts[2]) {
            var comps = DateComponents()
            comps.year = y
            comps.month = m
            comps.day = d
            if let parsed = AppDate.gregorian.date(from: comps),
               let ord = AppDate.gregorian.ordinality(of: .day, in: .year, for: parsed) {
                return ord
            }
        }
        return AppDate.gregorian.ordinality(of: .day, in: .year, for: Date()) ?? 1
    }

    private static func encodePNGData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private static func pruneOldWallpapers(in dirURL: URL, keepingURL: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let dirPath = dirURL.standardizedFileURL.path
        let managed = items.filter {
            BlueprintWallpaperPath.isManagedPath($0.standardizedFileURL.path, directoryPath: dirPath)
                && $0.pathExtension.lowercased() == "png"
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

    // MARK: - CoreGraphics Swiss Architectural Renderer (100% Thread-Safe)

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
        let stampPrimary: CGColor
        let stampMuted: CGColor
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
                stampPrimary: rgba(0.92, 0.94, 0.98, 0.56),
                stampMuted: rgba(0.58, 0.63, 0.74, 0.42),
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
                stampPrimary: rgba(0.09, 0.10, 0.13, 0.56),
                stampMuted: rgba(0.34, 0.37, 0.44, 0.45),
                isDark: false
            )
        }
    }

    private static func agyLogoCGPath(in rect: CGRect) -> CGPath {
        let box = AGYLogo.normalizedBox
        guard box.width > 0, box.height > 0, rect.width > 0, rect.height > 0 else {
            return CGMutablePath()
        }
        let scale = min(rect.width / box.width, rect.height / box.height)
        let ox = rect.minX + (rect.width - box.width * scale) / 2.0
        let oy = rect.minY + (rect.height - box.height * scale) / 2.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: ox + (x - box.minX) * scale,
                y: oy + (box.maxY - y) * scale
            )
        }
        let path = CGMutablePath()
        for cmd in AGYLogo.commands {
            switch cmd {
            case let .move(x, y):
                path.move(to: pt(x, y))
            case let .line(x, y):
                path.addLine(to: pt(x, y))
            case let .curve(x, y, c1x, c1y, c2x, c2y):
                path.addCurve(
                    to: pt(x, y),
                    control1: pt(c1x, c1y),
                    control2: pt(c2x, c2y)
                )
            case .close:
                path.closeSubpath()
            }
        }
        return path
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
        let majorStep = max(16.0, (128.0 * scale).rounded())
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
            let step = max(4.0, 16.0 * scale)
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

        // 6. Quiet bottom-right archival stamp + AGY vector mark (pure CoreText + CoreGraphics)
        let stampText = String(format: "AGY // %04d TOPOGRAPHY · DAY %03d · %d HRS", year, dayOfYear, totalHours)
        let fontSize = max(12.0, 14.5 * scale)
        let ctFont = CTFontCreateUIFontForLanguage(.userFixedPitch, fontSize, nil)
            ?? CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let ctAttrs: [CFString: Any] = [
            kCTFontAttributeName: ctFont,
            kCTForegroundColorAttributeName: pal.stampPrimary,
            kCTKernAttributeName: NSNumber(value: Double(1.6 * scale)),
        ]
        let cfStr = CFAttributedStringCreate(kCFAllocatorDefault, stampText as CFString, ctAttrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(cfStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textHeight = ascent + descent

        let marginRight = 72.0 * scale
        let marginBottom = 92.0 * scale
        let textOriginX = w - marginRight - textWidth
        let baselineY = marginBottom + descent

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: textOriginX, y: baselineY)
        CTLineDraw(line, ctx)

        // Small AGY logo mark directly left of the stamp text
        let logoSize = fontSize * 1.15
        let logoRect = CGRect(
            x: textOriginX - logoSize - 10.0 * scale,
            y: marginBottom + (textHeight - logoSize) * 0.5,
            width: logoSize,
            height: logoSize
        )
        let logoPath = agyLogoCGPath(in: logoRect)
        ctx.setFillColor(CGColor(
            colorSpace: colorSpace,
            components: [pal.contourPeak.r, pal.contourPeak.g, pal.contourPeak.b, pal.isDark ? 0.72 : 0.68]
        )!)
        ctx.addPath(logoPath)
        ctx.fillPath()

        // Delicate hairline rule under the stamp
        let ruleY = marginBottom - 7.0 * scale
        ctx.setStrokeColor(pal.stampMuted)
        ctx.setLineWidth(max(1.0, 1.0 * scale))
        ctx.move(to: CGPoint(x: logoRect.minX, y: ruleY))
        ctx.addLine(to: CGPoint(x: w - marginRight, y: ruleY))
        ctx.strokePath()
        ctx.restoreGState()

        return ctx.makeImage()
    }
}
