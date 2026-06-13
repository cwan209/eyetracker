import AppKit
import Foundation
import GazeFocusCore

/// Registers for sleep/wake/lock/unlock/display/Space notifications and forwards
/// each, via `SystemEventMapping`, into a sink that drives the single
/// `LifecycleReducer` (U12). The reducer owns the transition logic; this is pure
/// glue. Lock/unlock come from `DistributedNotificationCenter`; the rest from
/// `NSWorkspace` / `NSApplication`.
public final class SystemEventObserver: @unchecked Sendable {
    private let sink: @Sendable (LifecycleEvent) -> Void
    private var tokens: [NSObjectProtocol] = []

    public init(sink: @escaping @Sendable (LifecycleEvent) -> Void) {
        self.sink = sink
    }

    public func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification)
        observe(workspace, NSWorkspace.didWakeNotification)
        observe(workspace, NSWorkspace.screensDidSleepNotification)
        observe(workspace, NSWorkspace.screensDidWakeNotification)
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification)

        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"))
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"))
    }

    public func stop() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let sink = self.sink
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            if let event = SystemEventMapping.event(forNotificationNamed: name.rawValue) {
                sink(event)
            }
        }
        tokens.append(token)
    }

    private func observe(_ center: DistributedNotificationCenter, _ name: Notification.Name) {
        let sink = self.sink
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            if let event = SystemEventMapping.event(forNotificationNamed: name.rawValue) {
                sink(event)
            }
        }
        tokens.append(token)
    }
}
