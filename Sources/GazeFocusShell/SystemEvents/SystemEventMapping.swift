import GazeFocusCore

/// Pure mapping from a system notification name to the lifecycle event it drives
/// (U12). Kept separate from the observer glue so it is unit-testable without a
/// running app. The observer registers for these names and forwards the mapped
/// `LifecycleEvent` into the single `LifecycleReducer`.
public enum SystemEventMapping {
    /// Canonical notification-name → lifecycle-event table.
    public static let table: [String: LifecycleEvent] = [
        "NSWorkspaceWillSleepNotification":        .system(.sleep),
        "NSWorkspaceScreensDidSleepNotification":  .system(.sleep),
        "NSWorkspaceDidWakeNotification":          .system(.wake),
        "NSWorkspaceScreensDidWakeNotification":   .system(.wake),
        "com.apple.screenIsLocked":                .system(.lock),
        "com.apple.screenIsUnlocked":              .system(.unlock),
        "NSApplicationDidChangeScreenParametersNotification": .system(.displayChanged),
        "NSWorkspaceActiveSpaceDidChangeNotification": .system(.spaceChanged),
    ]

    public static func event(forNotificationNamed name: String) -> LifecycleEvent? {
        table[name]
    }
}
