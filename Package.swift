// swift-tools-version: 6.0
import PackageDescription

// GazeFocusCore — platform-independent, headlessly-testable core (U1–U5, U14).
// GazeFocusShell — OS-bound implementations of the core's ports: webcam capture
//   + Vision gaze pipeline (U7) and CGWindowList/AXUIElement window control (U8).
// gaze-spike — a dry-run harness to run the two on-device kill-criteria
//   (gaze-accuracy separation; silent-reading-pause false switches) before
//   building the full app shell.
// Plan: docs/plans/2026-06-13-001-feat-gaze-focus-switcher-plan.md
let package = Package(
    name: "GazeFocus",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GazeFocusCore", targets: ["GazeFocusCore"]),
        .library(name: "GazeFocusShell", targets: ["GazeFocusShell"]),
        .executable(name: "gaze-spike", targets: ["gaze-spike"]),
    ],
    targets: [
        .target(name: "GazeFocusCore"),
        .testTarget(
            name: "GazeFocusCoreTests",
            dependencies: ["GazeFocusCore"]
        ),
        .target(
            name: "GazeFocusShell",
            dependencies: ["GazeFocusCore"]
        ),
        .executableTarget(
            name: "gaze-spike",
            dependencies: ["GazeFocusShell", "GazeFocusCore"],
            exclude: ["Info.plist"],   // linker-embedded via -sectcreate, not a bundled resource
            // Embed an Info.plist into the binary's __TEXT,__info_plist section so a
            // plain SwiftPM CLI can request Camera access (TCC needs the usage string).
            // unsafeFlags is fine for a local executable; it only blocks use as a
            // versioned dependency. If camera access still fails from the CLI on your
            // machine, drop these Sources into a tiny Xcode app target instead.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/gaze-spike/Info.plist",
                ])
            ]
        ),
    ]
)
