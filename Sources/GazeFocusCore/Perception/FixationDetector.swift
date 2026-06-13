import Foundation

/// Streaming I-DT (dispersion-threshold) fixation detector (U3, KTD4).
///
/// A fixation is a run of recent samples whose spatial dispersion stays within
/// `dispersionThreshold` and that spans at least `minDuration`. This dispersion
/// gate — not duration alone — is what separates a casual glance from a stable
/// look (fixation durations are unimodal, so duration alone cannot). Samples
/// below `minConfidence` break the current fixation (fail-safe: no confident
/// fixation → no target downstream).
public struct FixationDetector: Sendable {
    public struct Config: Sendable {
        /// Dispersion budget in screen points: `(maxX-minX) + (maxY-minY)`.
        public var dispersionThreshold: Double
        /// Minimum stable duration before a run counts as a fixation (seconds).
        public var minDuration: Double
        /// Samples below this confidence break the fixation.
        public var minConfidence: Double
        public init(dispersionThreshold: Double = 40,
                    minDuration: Double = 0.1,
                    minConfidence: Double = 0.5) {
            self.dispersionThreshold = dispersionThreshold
            self.minDuration = minDuration
            self.minConfidence = minConfidence
        }
    }

    public enum Output: Sendable, Equatable {
        case none
        case fixation(point: Point2D, since: Instant)
    }

    private let config: Config
    private var window: [GazeSample] = []

    public init(config: Config = .init()) { self.config = config }

    /// Feed one sample; returns the current fixation (if the run is stable and
    /// long enough) or `.none`.
    public mutating func add(_ sample: GazeSample) -> Output {
        // Low-confidence sample breaks any in-progress fixation.
        guard sample.confidence >= config.minConfidence else {
            window.removeAll(keepingCapacity: true)
            return .none
        }

        window.append(sample)

        // I-DT: drop the oldest samples until the remaining run is dispersion-stable.
        while window.count > 1 && Self.dispersion(window) > config.dispersionThreshold {
            window.removeFirst()
        }

        guard let first = window.first, let last = window.last else { return .none }
        let duration = last.t - first.t
        if duration >= config.minDuration && Self.dispersion(window) <= config.dispersionThreshold {
            return .fixation(point: Self.centroid(window), since: first.t)
        }
        return .none
    }

    /// Clears in-progress state (e.g., on a tracking gap or pause).
    public mutating func reset() { window.removeAll(keepingCapacity: true) }

    static func dispersion(_ samples: [GazeSample]) -> Double {
        guard let first = samples.first else { return 0 }
        var minX = first.point.x, maxX = first.point.x
        var minY = first.point.y, maxY = first.point.y
        for s in samples.dropFirst() {
            minX = Swift.min(minX, s.point.x); maxX = Swift.max(maxX, s.point.x)
            minY = Swift.min(minY, s.point.y); maxY = Swift.max(maxY, s.point.y)
        }
        return (maxX - minX) + (maxY - minY)
    }

    static func centroid(_ samples: [GazeSample]) -> Point2D {
        guard !samples.isEmpty else { return .zero }
        let n = Double(samples.count)
        let sx = samples.reduce(0) { $0 + $1.point.x }
        let sy = samples.reduce(0) { $0 + $1.point.y }
        return Point2D(x: sx / n, y: sy / n)
    }
}
