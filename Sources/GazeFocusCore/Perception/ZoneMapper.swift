import Foundation

/// Maps a calibrated fixation point to the window that contains it, or `.none`
/// when targeting is uncertain (U3, R2/R3). Uncertainty — an ambiguous point
/// near a shared border or in an overlap, more windows than gaze can reliably
/// separate, or windows too small — resolves to `.none` rather than a guess.
public struct ZoneMapper: Sendable {
    public struct Config: Sendable {
        /// Inward dead-band on each window edge (points); a point inside the
        /// band is treated as too-close-to-the-border to commit.
        public var borderDeadband: Double
        /// Above this window count, gaze cannot reliably distinguish targets.
        public var maxWindows: Int
        /// Windows narrower/shorter than this are not selectable.
        public var minWindowSize: Double
        public init(borderDeadband: Double = 12,
                    maxWindows: Int = 4,
                    minWindowSize: Double = 150) {
            self.borderDeadband = borderDeadband
            self.maxWindows = maxWindows
            self.minWindowSize = minWindowSize
        }
    }

    private let config: Config
    public init(config: Config = .init()) { self.config = config }

    public func resolve(point rawPoint: Point2D,
                        windows: [WindowSnapshot],
                        calibration: CalibrationOffset = .identity) -> Target {
        // More windows than gaze can reliably separate → no target.
        guard windows.count <= config.maxWindows else { return .none }

        let p = calibration.apply(to: rawPoint)

        let hits = windows.filter { w in
            w.bounds.width >= config.minWindowSize &&
            w.bounds.height >= config.minWindowSize &&
            w.bounds.insetBy(config.borderDeadband).contains(p)
        }

        // Exactly one selectable window contains the point (clear of its border).
        guard hits.count == 1 else { return .none }
        return .window(hits[0].id)
    }
}
