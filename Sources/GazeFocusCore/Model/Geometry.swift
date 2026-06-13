import Foundation

/// A monotonic instant in seconds. The core never reads wall-clock time itself;
/// callers stamp samples/events and pass `now` explicitly (see `Clock`), so all
/// timing logic is deterministic under test. (KTD: `NSEvent.timestamp` is
/// mach-uptime, not `Date` — the shell converts at the boundary.)
public typealias Instant = Double

/// A point in screen space (points). The core works in a single screen
/// coordinate space; the gaze→screen mapping and calibration happen upstream
/// (calibration offset is applied by `ZoneMapper`).
public struct Point2D: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public static let zero = Point2D(x: 0, y: 0)
}

/// An axis-aligned rectangle in screen space (points).
public struct Rect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: Point2D { Point2D(x: x + width / 2, y: y + height / 2) }

    public func contains(_ p: Point2D) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    /// Shrinks the rect inward by `inset` on every edge (the border dead-band).
    /// Returns a zero-area rect when the inset exceeds half the smaller side.
    public func insetBy(_ inset: Double) -> Rect {
        let w = max(0, width - 2 * inset)
        let h = max(0, height - 2 * inset)
        return Rect(x: x + inset, y: y + inset, width: w, height: h)
    }
}
