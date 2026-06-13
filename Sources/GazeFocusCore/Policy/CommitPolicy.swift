import Foundation

/// The armed wrong-switch recovery window (U4, R10). After a switch, a recovery
/// action within `until` restores the previous focus.
public struct ArmedUndo: Sendable, Equatable {
    public var previous: WindowID?
    public var until: Instant
    public init(previous: WindowID?, until: Instant) {
        self.previous = previous; self.until = until
    }
}

/// The fail-safe commit gate chain (U4). Turns a fixation into a switch — or
/// holds focus. Every uncertain condition resolves to `.hold`. The gate order
/// is load-bearing: post-wake gate and typing-guard precede the dwell check.
public struct CommitPolicy: Sendable {
    public struct Config: Sendable {
        public var minConfidence: Double
        public var minTargets: Int
        public var recoveryWindow: Double
        public init(minConfidence: Double = 0.5,
                    minTargets: Int = 2,
                    recoveryWindow: Double = 3.0) {
            self.minConfidence = minConfidence
            self.minTargets = minTargets
            self.recoveryWindow = recoveryWindow
        }
    }

    /// Everything the gate chain needs for one evaluation. `fixation` is the
    /// current stable fixation (with the instant it began); `target` is the
    /// window `ZoneMapper` resolved it to (nil = uncertain).
    public struct Input: Sendable {
        public var now: Instant
        public var fixation: FixationDetector.Output
        public var confidence: Double
        public var target: WindowID?
        public var liveTargetCount: Int
        public var typingSuppressed: Bool
        public var dwellThreshold: Double
        public var requireFreshGaze: Bool
        public var currentFocused: WindowID?
        public var targetStillLive: Bool
        public init(now: Instant,
                    fixation: FixationDetector.Output,
                    confidence: Double,
                    target: WindowID?,
                    liveTargetCount: Int,
                    typingSuppressed: Bool,
                    dwellThreshold: Double,
                    requireFreshGaze: Bool,
                    currentFocused: WindowID?,
                    targetStillLive: Bool) {
            self.now = now; self.fixation = fixation; self.confidence = confidence
            self.target = target; self.liveTargetCount = liveTargetCount
            self.typingSuppressed = typingSuppressed; self.dwellThreshold = dwellThreshold
            self.requireFreshGaze = requireFreshGaze; self.currentFocused = currentFocused
            self.targetStillLive = targetStillLive
        }
    }

    public enum Effect: Sendable, Equatable {
        /// A confident fixation was seen — clears the post-wake `requireFreshGaze`
        /// flag in the lifecycle reducer.
        case freshGazeSeen
    }

    public struct Result: Sendable, Equatable {
        public var decision: FocusDecision
        public var effects: [Effect]
    }

    private let config: Config
    private(set) public var armedUndo: ArmedUndo?

    public init(config: Config = .init()) { self.config = config }

    public mutating func evaluate(_ input: Input) -> Result {
        // Gate 0: a confident, stable fixation must exist. No confident fixation
        // → hold (fail-safe). A stable fixation carries its start instant.
        guard case let .fixation(_, since) = input.fixation,
              input.confidence >= config.minConfidence else {
            return Result(decision: .hold, effects: [])
        }

        // Gate 1 (post-wake): a confident fixation clears `requireFreshGaze` but
        // does not itself switch — the next evaluation (flag cleared) may switch.
        if input.requireFreshGaze {
            return Result(decision: .hold, effects: [.freshGazeSeen])
        }

        // Gate 2: at least two live targets to disambiguate.
        guard input.liveTargetCount >= config.minTargets else {
            return Result(decision: .hold, effects: [])
        }

        // Gate 3: not actively typing in the current window.
        guard !input.typingSuppressed else {
            return Result(decision: .hold, effects: [])
        }

        // A resolved, different window is required; a dwell on the already-focused
        // window is a no-op (sticky focus).
        guard let target = input.target, target != input.currentFocused else {
            return Result(decision: .hold, effects: [])
        }

        // Gate 4: dwell held past the personal threshold.
        guard (input.now - since) >= input.dwellThreshold else {
            return Result(decision: .hold, effects: [])
        }

        // Gate 5: target still live and visible at commit time.
        guard input.targetStillLive else {
            return Result(decision: .hold, effects: [])
        }

        // Commit: arm the undo window with the window we are leaving.
        armedUndo = ArmedUndo(previous: input.currentFocused,
                              until: input.now + config.recoveryWindow)
        return Result(decision: .switchTo(target), effects: [])
    }

    /// Wrong-switch recovery (R10): if invoked within the armed window, restores
    /// the previous focus; otherwise a no-op hold.
    public mutating func recover(now: Instant) -> FocusDecision {
        guard let a = armedUndo, now <= a.until, let prev = a.previous else {
            return .hold
        }
        armedUndo = nil
        return .switchTo(prev)
    }
}
