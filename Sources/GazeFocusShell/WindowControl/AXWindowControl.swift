import AppKit
import ApplicationServices
import GazeFocusCore

/// Window control over the Accessibility API (U8). Conforms to the core
/// `WindowControl` port. Focus = activate the owning process **then** raise +
/// focus the window (raising alone does not move keyboard focus, KTD6). Never
/// injects synthetic events (R29). Requires the Accessibility TCC permission;
/// degrades to a no-op (returns false) when untrusted.
public final class AXWindowControl: WindowControl, @unchecked Sendable {
    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func windows() -> [WindowSnapshot] { CGWindowEnumerator.windows() }

    public func frontmostWindow() -> WindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        // Match the frontmost app's first on-screen window by PID.
        return CGWindowEnumerator.windows().first { $0.ownerPID == pid }?.id
    }

    /// Activate the owning process, then raise + focus its window matching `windowID`.
    /// Returns false when untrusted or the window can't be located.
    @discardableResult
    public func focus(windowID: WindowID, ownerPID: Int32) -> Bool {
        guard isTrusted else { return false }

        // 1. Bring the owning process forward (raising the window alone does not
        //    transfer keyboard focus).
        if let app = NSRunningApplication(processIdentifier: ownerPID) {
            app.activate()
        }

        // 2. Find the matching AX window for this PID and raise + focus it.
        let appElement = AXUIElementCreateApplication(ownerPID)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return false }

        for axWindow in axWindows {
            guard windowNumber(of: axWindow) == windowID else { continue }
            AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, axWindow)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            return true
        }
        return false
    }

    /// Resolve an AX window's CG window number via the private-but-stable
    /// `_AXUIElementGetWindow` (the only bridge between AX windows and CG window
    /// IDs). Returns nil if unavailable.
    private func windowNumber(of element: AXUIElement) -> WindowID? {
        var wid: CGWindowID = 0
        let result = _AXUIElementGetWindow(element, &wid)
        return result == .success ? WindowID(wid) : nil
    }
}

// `_AXUIElementGetWindow` is not in the public headers but is the standard bridge
// from an AXUIElement to its CGWindowID (used by yabai, AutoRaise, etc.). Declared
// here so the shell can map AX windows to the IDs `CGWindowEnumerator` returns.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
