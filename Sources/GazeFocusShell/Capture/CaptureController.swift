import AVFoundation
import Vision
import CoreGraphics
import Foundation
import GazeFocusCore

/// One processed frame: the gaze estimate (if any) plus **eye-framing** info for
/// the camera-alignment feedback. We track the *eyeballs* (pupils), not the face
/// box — the gaze pipeline consumes pupils, and a face can be perfectly framed
/// while the pupils are unresolved (looking down, glasses glare, eyes closed),
/// which silently degrades gaze. `eyesDetected` is that distinct signal.
///
/// `eyeCenter`/`eyeSpan` are mapped into **frame-normalized 0..1** coordinates
/// (Vision lower-left origin) once, here at the capture boundary — Vision's pupil
/// `normalizedPoints` are box-relative, so each is remapped through `boundingBox`.
/// Under `.leftMirrored` the 0.5 centering target still holds (mirror fixed point)
/// and `eyeSpan`/`eyeCenter.y` are mirror-invariant. `faceSize` is kept as a
/// coarse distance proxy that survives when the pupils drop out.
public struct GazeFrame: Sendable {
    public var t: Instant
    public var sample: GazeSample?
    public var faceDetected: Bool
    public var eyesDetected: Bool    // both pupils resolved with >0 points — the validity flag for eyeCenter/eyeSpan
    public var eyeCenter: Point2D    // midpoint of the two pupils, frame-normalized 0..1; valid ONLY when eyesDetected (.zero otherwise)
    public var eyeSpan: Double        // inter-pupillary distance, frame-normalized; 0 when <2 pupils (distance proxy)
    public var faceSize: Double       // normalized face-box height (coarse far/near, survives pupil dropout)
    public init(t: Instant, sample: GazeSample?, faceDetected: Bool,
                eyesDetected: Bool, eyeCenter: Point2D, eyeSpan: Double, faceSize: Double) {
        self.t = t; self.sample = sample; self.faceDetected = faceDetected
        self.eyesDetected = eyesDetected; self.eyeCenter = eyeCenter
        self.eyeSpan = eyeSpan; self.faceSize = faceSize
    }
}

/// Webcam capture + Vision gaze pipeline (U7).
///
/// KTD9 concurrency decision: the simplest serial-confined structure, not a
/// custom-executor actor. All `AVCaptureSession` mutation and all per-frame work
/// run on one private serial `DispatchQueue`; the sample-buffer delegate is
/// invoked on that same queue, extracts the Sendable `CVPixelBuffer` from the
/// non-Sendable `CMSampleBuffer`, and never hands the sample buffer across a
/// boundary. The class is `@unchecked Sendable` because every mutable field is
/// confined to `queue` — this compiling clean under Swift 6 strict concurrency
/// is the KTD9 spike. Escalate to an actor + custom executor only if a real need
/// appears.
public final class CaptureController: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gazefocus.capture")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let estimator: any GazeEstimator
    private let screenSize: CGSize
    private let onFrame: @Sendable (GazeFrame) -> Void

    /// Process every Nth frame (~10Hz from a 30fps camera) to bound CPU.
    private let decimation: Int
    private var frameCounter = 0
    private var landmarksRequest = VNDetectFaceLandmarksRequest()

    public init(estimator: any GazeEstimator,
                screenSize: CGSize,
                decimation: Int = 3,
                onFrame: @escaping @Sendable (GazeFrame) -> Void) {
        self.estimator = estimator
        self.screenSize = screenSize
        self.decimation = max(1, decimation)
        self.onFrame = onFrame
        super.init()
    }

    /// Configure and start capture. Powers the camera on (LED lights).
    public func start() {
        queue.async { [self] in
            if session.inputs.isEmpty { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Stop capture. `stopRunning()` powers the sensor down so the LED goes off —
    /// there is no software-only mute (KTD11).
    public func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .medium
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }
}

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // Invoked on `queue` — all state below is serial-confined.
        frameCounter += 1
        guard frameCounter % decimation == 0 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let t = ProcessInfo.processInfo.systemUptime   // monotonic seconds
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored)
        let noFace = GazeFrame(t: t, sample: nil, faceDetected: false,
                               eyesDetected: false, eyeCenter: .zero, eyeSpan: 0, faceSize: 0)
        do {
            try handler.perform([landmarksRequest])
        } catch {
            onFrame(noFace); return
        }
        guard let face = (landmarksRequest.results)?.first else { onFrame(noFace); return }

        let bb = face.boundingBox   // normalized to the frame, Vision lower-left origin
        let faceSize = Double(bb.height)

        // Map a pupil region (normalizedPoints are box-relative) to a single
        // frame-normalized point. `pointCount > 0` is mandatory: Vision can hand
        // back a non-nil region with an empty array, which would divide by zero
        // and feed NaN into the gates (NaN compares false to every bound, silently
        // disabling them). isFinite guards the bbox-edge / degenerate cases.
        func framePupil(_ r: VNFaceLandmarkRegion2D?) -> Point2D? {
            guard let r, r.pointCount > 0 else { return nil }
            let pts = r.normalizedPoints
            let n = Double(pts.count)
            let ax = pts.reduce(0.0) { $0 + Double($1.x) } / n
            let ay = pts.reduce(0.0) { $0 + Double($1.y) } / n
            let fx = Double(bb.minX) + ax * Double(bb.width)
            let fy = Double(bb.minY) + ay * Double(bb.height)
            guard fx.isFinite, fy.isFinite else { return nil }
            return Point2D(x: fx, y: fy)
        }

        let lp = framePupil(face.landmarks?.leftPupil)
        let rp = framePupil(face.landmarks?.rightPupil)
        let eyesDetected = (lp != nil && rp != nil)
        // eyeCenter is only meaningful with BOTH pupils. A single-pupil midpoint
        // would be biased ~half an IPD off-axis and could mislead a future reader
        // that forgets to gate on eyesDetected — so it is .zero (clearly invalid)
        // unless both resolve. eyesDetected is the validity flag for this field.
        let eyeCenter: Point2D
        if let l = lp, let r = rp {
            eyeCenter = Point2D(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
        } else {
            eyeCenter = .zero
        }
        let eyeSpan: Double = {
            guard let l = lp, let r = rp else { return 0 }   // distance proxy needs both pupils
            let d = hypot(l.x - r.x, l.y - r.y)              // keep dy term so head-roll doesn't shrink it
            return d.isFinite ? d : 0
        }()

        let sample = estimator.estimate(face: face, screenSize: screenSize)
            .map { GazeSample(t: t, point: $0.point, confidence: $0.confidence) }
        onFrame(GazeFrame(t: t, sample: sample, faceDetected: true,
                          eyesDetected: eyesDetected, eyeCenter: eyeCenter,
                          eyeSpan: eyeSpan, faceSize: faceSize))
    }
}
