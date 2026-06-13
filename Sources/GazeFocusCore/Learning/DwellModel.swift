import Foundation

/// The persisted slice of the learned model (U13 stores this; raw samples are
/// kept only in the bounded in-memory buffer, never long-term).
public struct DwellModelState: Sendable, Equatable {
    public var threshold: Instant
    public var graduated: Bool
    public init(threshold: Instant, graduated: Bool) {
        self.threshold = threshold; self.graduated = graduated
    }
}

/// Graduation verdict (U5, R15/R16). Either personalize, fall back to the
/// default at the collection cap, or keep collecting.
public enum GraduationStatus: Sendable, Equatable {
    case collecting
    case graduateLearned(Instant)
    case graduateDefault(Instant)
}

/// Learns the user's minimum intentional dwell as a percentile of valid dwell
/// events (U5, KTD5). Not a mean (the distribution is right-skewed) and not
/// eye→action latency. Graduation requires both a sample count **and** a usable
/// (narrow/unimodal) distribution; otherwise it pins to the default.
public struct DwellModel: Sendable {
    public struct Config: Sendable {
        public var capacity: Int
        public var defaultThreshold: Instant
        public var floor: Instant
        public var ceiling: Instant
        public var percentile: Double
        public var minEvents: Int
        public var revertStep: Instant
        /// Max (p90 − p10) as a multiple of the median for the distribution to
        /// count as usable. Wider/bimodal → not usable → pin to default.
        public var maxSpreadRatio: Double
        /// Recent-outcome revert fraction above which the learner is judged
        /// net-negative and falls back to the default.
        public var netNegativeRevertRate: Double
        public init(capacity: Int = 100,
                    defaultThreshold: Instant = 0.6,
                    floor: Instant = 0.3,
                    ceiling: Instant = 1.0,
                    percentile: Double = 0.8,
                    minEvents: Int = 40,
                    revertStep: Instant = 0.1,
                    maxSpreadRatio: Double = 0.8,
                    netNegativeRevertRate: Double = 0.5) {
            self.capacity = capacity; self.defaultThreshold = defaultThreshold
            self.floor = floor; self.ceiling = ceiling; self.percentile = percentile
            self.minEvents = minEvents; self.revertStep = revertStep
            self.maxSpreadRatio = maxSpreadRatio; self.netNegativeRevertRate = netNegativeRevertRate
        }
    }

    private let config: Config
    private var buffer: [Instant] = []
    private var nudge: Instant = 0
    // Recent post-activation outcomes (true = reverted) for net-negative detection.
    private var outcomes: [Bool] = []

    public init(config: Config = .init()) { self.config = config }

    public var sampleCount: Int { buffer.count }

    /// Records one valid dwell event (Collecting: a stable fixation held past the
    /// active threshold with no typing; Active: a confirmed, not-reverted switch).
    public mutating func record(validDwell duration: Instant) {
        buffer.append(duration)
        if buffer.count > config.capacity { buffer.removeFirst(buffer.count - config.capacity) }
    }

    /// The current threshold: 80th percentile clamped to [floor, ceiling], plus
    /// any accumulated revert nudge. Falls back to the default (also plus the
    /// accumulated nudge — the conservative lengthening is deliberately retained)
    /// before any samples, or when the distribution is unusable or the learner is
    /// net-negative.
    public func threshold() -> Instant {
        guard distributionUsable(), !isNetNegative(), !buffer.isEmpty else {
            return clamp(config.defaultThreshold + nudge)
        }
        return clamp(Self.percentile(buffer, config.percentile) + nudge)
    }

    /// A reverted switch lengthens the threshold by a bounded step (R17).
    public mutating func recordOutcome(reverted: Bool) {
        outcomes.append(reverted)
        if outcomes.count > config.capacity { outcomes.removeFirst(outcomes.count - config.capacity) }
        if reverted { nudge = min(nudge + config.revertStep, config.ceiling) }
    }

    /// Whether the learned distribution is narrow/unimodal enough to trust a
    /// single threshold (origin R15's escape hatch).
    public func distributionUsable() -> Bool {
        guard buffer.count >= 2 else { return false }
        let median = Self.percentile(buffer, 0.5)
        guard median > 0 else { return false }
        let spread = Self.percentile(buffer, 0.9) - Self.percentile(buffer, 0.1)
        return spread <= config.maxSpreadRatio * median
    }

    /// True when recent post-activation reverts exceed the net-negative rate.
    public func isNetNegative() -> Bool {
        guard outcomes.count >= 4 else { return false }
        let reverts = outcomes.filter { $0 }.count
        return Double(reverts) / Double(outcomes.count) > config.netNegativeRevertRate
    }

    /// Graduation decision (R15): personalize when there are enough events and a
    /// usable distribution; fall back to the default at the cap; else keep collecting.
    public func graduationStatus(capReached: Bool) -> GraduationStatus {
        if buffer.count >= config.minEvents && distributionUsable() {
            return .graduateLearned(threshold())
        }
        if capReached {
            return .graduateDefault(clamp(config.defaultThreshold + nudge))
        }
        return .collecting
    }

    private func clamp(_ v: Instant) -> Instant { min(max(v, config.floor), config.ceiling) }

    /// Linear-interpolation percentile over a copy-sorted buffer.
    static func percentile(_ values: [Instant], _ q: Double) -> Instant {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = q * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}
