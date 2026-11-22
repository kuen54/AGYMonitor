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
                "CraftEngine.swift",
                "Formatters.swift",
                "GlobalHotKey.swift",
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
                "SpecimenExporter.swift",
                "Theme.swift",
                "UpdateService.swift",
                "UsageArchive.swift",
                "UsageScriptClient.swift",
                "UsageStore.swift",
                "Views.swift",
                "Views_Cards.swift",
                "Views_Common.swift",
                "Views_InstrumentCost.swift",
                "Views_InstrumentPlan.swift",
                "Views_InstrumentSession.swift",
                "Views_InstrumentTime.swift",
                "Views_InstrumentTokens.swift",
                "Views_Menus.swift",
                "Views_Plan.swift",
                "Views_Session.swift",
                "Views_Specimen.swift",
                "Views_Time.swift",
                "WallpaperGenerator.swift",
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
                "Core_NotchState.swift",
                "Core_UsageState.swift",
                "Core_QuotaState.swift",
                "Core_MonitorState.swift",
                "Core_AppState.swift",
                "Core_UIState.swift",
                "Core_UpdateState.swift",
                "Core_Telemetry.swift",
                "Core_Instruments.swift",
                "Core_LiveTelemetry.swift",
                "Core_CraftState.swift",
            ]
        ),
        .testTarget(
            name: "AGYCoreTests",
            dependencies: ["AGYCore"],
            path: "Tests/AGYCoreTests"
        ),
    ]
)
