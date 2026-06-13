// swift-tools-version: 6.0
import PackageDescription

// GazeFocusCore — platform-independent, headlessly-testable core for the
// Adaptive Gaze Focus Switcher (MVP). All perception, decision, learning, and
// lifecycle logic lives here over injected data; the OS-bound app shell
// (camera, Vision/CoreML, Accessibility, menu-bar UI) consumes this package.
// Plan: docs/plans/2026-06-13-001-feat-gaze-focus-switcher-plan.md (U1–U5, U14).
let package = Package(
    name: "GazeFocusCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GazeFocusCore", targets: ["GazeFocusCore"]),
    ],
    targets: [
        .target(name: "GazeFocusCore"),
        .testTarget(
            name: "GazeFocusCoreTests",
            dependencies: ["GazeFocusCore"]
        ),
    ]
)
