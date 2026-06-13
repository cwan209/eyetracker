import Foundation

/// The lifecycle snapshot the reducer transforms. `requireFreshGaze` gates the
/// commit policy after a resume; `resumeState` remembers where to return after
/// a suspend.
public struct LifecycleSnapshot: Sendable, Equatable {
    public var state: LifecycleState
    public var requireFreshGaze: Bool
    public var resumeState: LifecycleState?
    public init(state: LifecycleState = .idle,
                requireFreshGaze: Bool = false,
                resumeState: LifecycleState? = nil) {
        self.state = state; self.requireFreshGaze = requireFreshGaze; self.resumeState = resumeState
    }
}

/// Everything that can drive the lifecycle: system events, learning events, and
/// user controls.
public enum LifecycleEvent: Sendable, Equatable {
    case system(SystemEvent)
    case learning(LearningEvent)
    case startCollecting
    case pause
    case resume
}

/// The single, serialized lifecycle state machine (U14). It is the sole sink for
/// both system events and learning graduation, so they cannot race two separate
/// owners. The transition function is total — every (state, event) pair is
/// defined; undefined combinations are identity (no-op), which is what keeps
/// `Active`-while-locked unreachable.
public struct LifecycleReducer: Sendable {
    public init() {}

    /// States in which the camera is on and a suspend event must tear down.
    private static let suspendable: Set<LifecycleState> = [.collecting, .ready, .calibrating, .active]

    public func reduce(_ snap: LifecycleSnapshot, _ event: LifecycleEvent) -> LifecycleSnapshot {
        switch event {
        case .startCollecting:
            return snap.state == .idle
                ? LifecycleSnapshot(state: .collecting) : snap

        case .pause:
            return snap.state == .active
                ? LifecycleSnapshot(state: .paused) : snap

        case .resume:
            // The camera is off while paused, so the gaze estimate is as stale as
            // after a wake — require a fresh confident gaze before any switch.
            return snap.state == .paused
                ? LifecycleSnapshot(state: .active, requireFreshGaze: true) : snap

        case .learning(let e):
            return reduceLearning(snap, e)

        case .system(let e):
            return reduceSystem(snap, e)
        }
    }

    private func reduceLearning(_ snap: LifecycleSnapshot, _ e: LearningEvent) -> LifecycleSnapshot {
        switch e {
        case .graduated:
            return snap.state == .collecting ? LifecycleSnapshot(state: .ready) : snap
        case .enabled:
            return snap.state == .ready ? LifecycleSnapshot(state: .calibrating) : snap
        case .calibrated:
            return snap.state == .calibrating ? LifecycleSnapshot(state: .active) : snap
        case .freshGazeSeen:
            // Only meaningful in active; clears the post-wake gate.
            guard snap.state == .active, snap.requireFreshGaze else { return snap }
            return LifecycleSnapshot(state: .active, requireFreshGaze: false, resumeState: snap.resumeState)
        }
    }

    private func reduceSystem(_ snap: LifecycleSnapshot, _ e: SystemEvent) -> LifecycleSnapshot {
        switch e {
        case .sleep, .lock, .logout, .spaceChanged:
            guard Self.suspendable.contains(snap.state) else { return snap }
            return LifecycleSnapshot(state: .suspended, requireFreshGaze: false, resumeState: snap.state)

        case .wake, .unlock:
            guard snap.state == .suspended else { return snap }
            let target = snap.resumeState ?? .idle
            // Returning to active requires a fresh confident gaze before any switch.
            return LifecycleSnapshot(state: target, requireFreshGaze: target == .active, resumeState: nil)

        case .displayChanged:
            // Targeting reconfigures (shell confines to primary); no state change.
            return snap
        }
    }
}
