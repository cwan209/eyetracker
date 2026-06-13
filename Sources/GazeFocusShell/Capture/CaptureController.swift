import AVFoundation
import Vision
import CoreGraphics
import Foundation
import GazeFocusCore

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
    private let onSample: @Sendable (GazeSample) -> Void

    /// Process every Nth frame (~10Hz from a 30fps camera) to bound CPU.
    private let decimation: Int
    private var frameCounter = 0
    private var landmarksRequest = VNDetectFaceLandmarksRequest()

    public init(estimator: any GazeEstimator,
                screenSize: CGSize,
                decimation: Int = 3,
                onSample: @escaping @Sendable (GazeSample) -> Void) {
        self.estimator = estimator
        self.screenSize = screenSize
        self.decimation = max(1, decimation)
        self.onSample = onSample
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
        do {
            try handler.perform([landmarksRequest])
        } catch {
            return
        }
        guard let face = (landmarksRequest.results)?.first else { return }
        guard let (point, confidence) = estimator.estimate(face: face, screenSize: screenSize) else { return }
        onSample(GazeSample(t: t, point: point, confidence: confidence))
    }
}
