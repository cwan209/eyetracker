import Vision
import CoreGraphics
import GazeFocusCore

/// Turns a detected face into an estimated on-screen gaze point in screen
/// coordinates (U7). The CoreML L2CS-Net estimator (KTD2) slots in here once the
/// model is converted (U6); `LandmarkGazeEstimator` is the cheap proxy that lets
/// the accuracy spike run *first* and decide whether the webcam can separate
/// zones at all — before investing in the model.
public protocol GazeEstimator: Sendable {
    /// Returns a screen-space gaze point and a confidence in `0...1`, or nil.
    func estimate(face: VNFaceObservation, screenSize: CGSize) -> (point: Point2D, confidence: Double)?
}

/// Cheap, model-free gaze proxy from Vision landmarks + head yaw. Combines the
/// horizontal pupil offset within each eye with the head yaw to produce a coarse
/// left/center/right signal — enough to test zone separability. Vertical is a
/// weak head-pitch proxy. This is intentionally approximate (it is the spike's
/// stand-in, not the shipping estimator).
public struct LandmarkGazeEstimator: GazeEstimator {
    public init() {}

    public func estimate(face: VNFaceObservation, screenSize: CGSize) -> (point: Point2D, confidence: Double)? {
        guard let landmarks = face.landmarks else { return nil }

        // Horizontal eye-in-socket offset for one eye: pupil x relative to the
        // eye region's x-extent, mapped to [-1, 1] (negative = looking left).
        func horizontalOffset(pupil: VNFaceLandmarkRegion2D?, eye: VNFaceLandmarkRegion2D?) -> Double? {
            guard let pupil, let eye, pupil.pointCount > 0, eye.pointCount > 1 else { return nil }
            let px = Double(pupil.normalizedPoints.reduce(0) { $0 + $1.x }) / Double(pupil.pointCount)
            let xs = eye.normalizedPoints.map { Double($0.x) }
            guard let lo = xs.min(), let hi = xs.max(), hi > lo else { return nil }
            return ((px - lo) / (hi - lo)) * 2 - 1
        }

        let leftOffset = horizontalOffset(pupil: landmarks.leftPupil, eye: landmarks.leftEye)
        let rightOffset = horizontalOffset(pupil: landmarks.rightPupil, eye: landmarks.rightEye)
        let offsets = [leftOffset, rightOffset].compactMap { $0 }
        guard !offsets.isEmpty else { return nil }
        let eyeSignal = offsets.reduce(0, +) / Double(offsets.count)   // [-1, 1]

        // Head yaw (radians) augments the eye signal. Available on macOS 12+.
        let yaw = (face.yaw?.doubleValue ?? 0)                          // ~[-0.7, 0.7]
        let horizontal = clamp((eyeSignal * 0.6) + (yaw / 0.7) * 0.4, -1, 1)

        // Weak vertical proxy from head pitch.
        let pitch = (face.pitch?.doubleValue ?? 0)
        let vertical = clamp((pitch / 0.7), -1, 1)

        // Map normalized [-1, 1] gaze direction to a screen point.
        let nx = (horizontal + 1) / 2
        let ny = (vertical + 1) / 2
        let point = Point2D(x: nx * Double(screenSize.width),
                            y: ny * Double(screenSize.height))

        let confidence = Double(face.confidence)
        return (point, confidence)
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}
