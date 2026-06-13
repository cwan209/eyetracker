import Foundation

// Protocol seams the OS-bound app shell implements (U2). The core depends only
// on these abstractions, never on AVFoundation / AppKit / Vision directly —
// which is what keeps the perception, policy, learning, and lifecycle logic
// headlessly testable with synthetic streams.

/// Supplies the current monotonic instant. The shell backs this with a
/// monotonic source; tests inject a deterministic clock.
public protocol Clock: Sendable {
    var now: Instant { get }
}

/// Enumerates on-screen windows and changes focus. Implemented in the shell
/// over `CGWindowListCopyWindowInfo` (geometry) + Accessibility (`AXUIElement`).
public protocol WindowControl: Sendable {
    func windows() -> [WindowSnapshot]
    func frontmostWindow() -> WindowID?
    /// Returns true on a successful raise + focus. A no-op/false when untrusted.
    func focus(windowID: WindowID, ownerPID: Int32) -> Bool
    var isTrusted: Bool { get }
}

/// A stream source of gaze samples (the shell's camera + Vision + CoreML pipeline).
public protocol GazeSource: Sendable {
    func start()
    func stop()
}

/// Reports keystroke activity as timing only — never content (KTD7 guarded
/// invariant). The shell converts `NSEvent.timestamp` into the core `Clock`
/// time base before reporting.
public protocol KeystrokeActivity: Sendable {
    /// The instant of the most recent keystroke in the current window, if any.
    var lastKeystroke: Instant? { get }
}

/// Persists the learned model. Implemented in the shell over CryptoKit + Keychain.
public protocol ModelStore: Sendable {
    func load() -> DwellModelState?
    func save(_ state: DwellModelState)
    func erase()
}
