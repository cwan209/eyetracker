import Foundation

/// Suppresses gaze-switching while the user is actively typing in the current
/// window (U4, R7). Reads keystroke *timing* only. The "secure-entry silence
/// holds suppression" behavior lives in the shell's monitor (it keeps reporting
/// a recent `lastKeystroke` through a Secure Keyboard Entry gap); this gate
/// just measures recency.
public struct TypingGuard: Sendable {
    /// Keystrokes within this window of `now` suppress switching (seconds).
    public var recencyWindow: Double
    public init(recencyWindow: Double = 0.8) { self.recencyWindow = recencyWindow }

    public func isSuppressed(lastKeystroke: Instant?, now: Instant) -> Bool {
        guard let last = lastKeystroke else { return false }
        return (now - last) < recencyWindow
    }
}
