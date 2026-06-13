import ApplicationServices

/// Accessibility (AX) permission helpers (U8, R23/R29). There is no revocation
/// notification, so the shell polls `isTrusted` and treats AX-call failures as
/// de-facto revocation (drives the "untrusted / switching paused" menu state).
public enum AccessibilityPermission {

    /// Current trust state without prompting (for silent re-checks).
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts the user and deep-links System Settings ▸ Privacy & Security ▸
    /// Accessibility. Call once during onboarding.
    @discardableResult
    public static func prompt() -> Bool {
        // Literal value of `kAXTrustedCheckOptionPrompt` — referencing the global
        // CFStringRef directly is rejected under Swift 6 strict concurrency.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
