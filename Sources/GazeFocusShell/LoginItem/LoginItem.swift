import ServiceManagement

/// Launch-at-login via `SMAppService` (U15). Read `.status` live (it can change
/// in System Settings ▸ Login Items) rather than caching a bool.
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public static func enable() throws {
        try SMAppService.mainApp.register()
    }

    public static func disable() throws {
        try SMAppService.mainApp.unregister()
    }
}
