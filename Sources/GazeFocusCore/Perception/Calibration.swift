import Foundation

/// A per-user gaze correction applied to raw screen-space estimates before zone
/// mapping. The full 4-point solver is U11 (Phase 3); the core owns the offset
/// type and `apply` so `ZoneMapper` consumes calibrated points. Defaults to identity.
public struct CalibrationOffset: Sendable, Equatable {
    /// Per-axis scale applied before translation.
    public var scale: Point2D
    /// Per-axis translation in screen points.
    public var translation: Point2D

    public init(scale: Point2D = Point2D(x: 1, y: 1), translation: Point2D = .zero) {
        self.scale = scale
        self.translation = translation
    }

    public static let identity = CalibrationOffset()

    public func apply(to p: Point2D) -> Point2D {
        Point2D(x: p.x * scale.x + translation.x,
                y: p.y * scale.y + translation.y)
    }
}
