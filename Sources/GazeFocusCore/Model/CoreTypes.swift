import Foundation

/// Stable identifier for an on-screen window (maps to `kCGWindowNumber` in the shell).
public typealias WindowID = Int

/// One gaze estimate: a screen-space point with a confidence in `0...1` at instant `t`.
public struct GazeSample: Sendable, Equatable {
    public var t: Instant
    public var point: Point2D
    public var confidence: Double
    public init(t: Instant, point: Point2D, confidence: Double) {
        self.t = t; self.point = point; self.confidence = confidence
    }
}

/// A snapshot of one on-screen window's geometry + owning process. Read from
/// `CGWindowListCopyWindowInfo` in the shell (geometry + owner only — never titles,
/// so no Screen Recording permission is needed).
public struct WindowSnapshot: Sendable, Equatable {
    public var id: WindowID
    public var ownerPID: Int32
    public var ownerName: String
    public var bounds: Rect
    public init(id: WindowID, ownerPID: Int32, ownerName: String, bounds: Rect) {
        self.id = id; self.ownerPID = ownerPID; self.ownerName = ownerName; self.bounds = bounds
    }
}

/// The resolved target of a fixation, or `.none` when targeting is uncertain
/// (ambiguous zone, too many windows, windows too small) — the fail-safe stance.
public enum Target: Sendable, Equatable {
    case none
    case window(WindowID)
}

/// The commit policy's verdict: hold current focus, or switch to a window.
public enum FocusDecision: Sendable, Equatable {
    case hold
    case switchTo(WindowID)
}

/// The lifecycle states. Switching is live only in `.active`; any uncertainty
/// resolves back to holding focus.
public enum LifecycleState: String, Sendable, Equatable, CaseIterable {
    case idle          // launched, permissions granted, camera not yet started
    case collecting    // observing only, switching nothing (camera on)
    case ready         // enough data; menu offers "Enable gaze mode"
    case calibrating   // running the 4-point calibration
    case active         // gaze-switching live
    case paused        // user-paused; camera off
    case suspended     // sleep / lock / fullscreen / Space change; camera off
}

/// System-originated events the lifecycle reducer consumes.
public enum SystemEvent: Sendable, Equatable {
    case sleep
    case wake
    case lock
    case unlock
    case logout
    case spaceChanged
    case displayChanged
}

/// Learning- and control-originated events the lifecycle reducer consumes.
/// `freshGazeSeen` is emitted by the commit policy on the first confident
/// fixation after a resume; it is the only thing that clears `requireFreshGaze`.
public enum LearningEvent: Sendable, Equatable {
    case graduated
    case enabled
    case calibrated
    case freshGazeSeen
}
