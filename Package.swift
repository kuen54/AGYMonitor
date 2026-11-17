// swift-tools-version:5.9
//
// SPM manifest for the TEST HARNESS ONLY (`swift test`).
//
// The app itself is deliberately NOT built with SPM — build.sh compiles
// Sources/*.swift directly with swiftc (universal binary). This package
// exposes just the pure-logic Core_*.swift files (Foundation-only, no
// AppKit/SwiftUI, no Process/SQLite/file I/O) as a library so unit tests can
// run against them. `sources:` is an explicit allowlist — app files must never
// enter the package.
import PackageDescription

let package = Package(
    name: "AGYCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AGYCore", targets: ["AGYCore"]),
    ],
    targets: [
        .target(
            name: "AGYCore",
            path: "Sources",
            exclude: [
                "AGYLogo.swift",
                "AITitleReader.swift",
                "AppDelegate.swift",
                "Formatters.swift",
                "Localization.swift",
                "Models.swift",
                "NotchController.swift",
                "NotchFullscreen.swift",
                "NotchView.swift",
                "ProcessRunner.swift",
                "QuotaService.swift",
                "SessionJumper.swift",
                "SessionMonitor.swift",
                "SessionStore.swift",
                "Theme.swift",
                "UsageArchive.swift",
                "UsageScriptClient.swift",
                "UsageStore.swift",
                "Views.swift",
                "Views_Cards.swift",
                "Views_Common.swift",
                "Views_Menus.swift",
                "Views_Plan.swift",
                "Views_Session.swift",
                "Views_Time.swift",
                "main.swift",
            ],
            sources: [
                "Core_Models.swift",
                "Core_ModelClass.swift",
                "Core_UsageParser.swift",
                "Core_DateLogic.swift",
                "Core_TimeLogic.swift",
                "Core_UsageArchive.swift",
                "Core_Sessions.swift",
                "Core_Transcript.swift",
                "Core_QuotaParser.swift",
                "Core_AGYLocator.swift",
            ]
        ),
        .testTarget(
            name: "AGYCoreTests",
            dependencies: ["AGYCore"],
            path: "Tests/AGYCoreTests"
        ),
    ]
)
