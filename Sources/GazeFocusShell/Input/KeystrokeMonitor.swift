import AppKit
import Foundation
import GazeFocusCore

/// Global keystroke-activity monitor (U9). Records the *time* of the most recent
/// keystroke only — never content (KTD7 guarded invariant: the handler ignores
/// the event entirely and just timestamps it). Rides the Accessibility grant; if
/// untrusted, the handler never fires and the guard stays inert. Uses
/// `ProcessInfo.systemUptime` to match the capture pipeline's time base.
public final class KeystrokeMonitor: KeystrokeActivity, @unchecked Sendable {
    private let lock = NSLock()
    private var _last: Instant?
    private var monitor: Any?

    public init() {}

    public var lastKeystroke: Instant? {
        lock.lock(); defer { lock.unlock() }
        return _last
    }

    public func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lock.lock(); self._last = now; self.lock.unlock()
        }
    }

    public func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
