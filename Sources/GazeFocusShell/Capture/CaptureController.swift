import AVFoundation
import Vision
import CoreGraphics
import Foundation
import GazeFocusCore

/// One processed frame: the gaze estimate (if any) plus face-framing info for the
/// camera-alignment feedback (is a face detected, where is it in the frame, how
/// big — a coarse distance proxy).
public struct GazeFrame: Sendable {
    public var t: Instant
    public var sample: GazeSample?
    public var faceDetected: Bool
    public var faceCenter: Point2D   // normalized 0..1 within the camera frame
    public var faceSize: Double      // normalized face-box height (small = far, large = close)
    public init(t: Instant, sample: GazeSample?, faceDetected: Bool, faceCenter: Point2D, faceSize: Double) {
        self.t = t; self.sample = sample; self.faceDetected = faceDetected
        self.faceCenter = faceCenter; self.faceSize = faceSize
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
        let noFace = GazeFrame(t: t, sample: nil, faceDetected: false, faceCenter: .zero, faceSize: 0)
        do {
            try handler.perform([landmarksRequest])
        } catch {
            onFrame(noFace); return
        }
        guard let face = (landmarksRequest.results)?.first else { onFrame(noFace); return }

        let bb = face.boundingBox   // normalized, Vision (bottom-left origin)
        let center = Point2D(x: Double(bb.midX), y: Double(bb.midY))
        let size = Double(bb.height)
        let sample = estimator.estimate(face: face, screenSize: screenSize)
            .map { GazeSample(t: t, point: $0.point, confidence: $0.confidence) }
        onFrame(GazeFrame(t: t, sample: sample, faceDetected: true, faceCenter: center, faceSize: size))
    }
}
