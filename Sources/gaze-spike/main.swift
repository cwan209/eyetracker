import AppKit
import AVFoundation
import Foundation
import GazeFocusCore
import GazeFocusShell

// gaze-spike — a dry-run harness for the plan's two on-device kill-criteria
// (docs/plans/...-plan.md, Risks):
//   1. Gaze accuracy: can a webcam separate left/center/right? Watch the live
//      `target=win N` readout while you look at each terminal.
//   2. Silent-reading-pause false switches: watch for `[WOULD SWITCH]` lines
//      while you *read* (not type in) an adjacent window. Frequent unwanted
//      lines mean pure dwell can't tell reading from intent and the plan's
//      look-then-press fallback is needed.
//
// Default is dry-run (logs only, never steals focus). Pass `--live` to actually
// switch focus via Accessibility (requires the AX permission). Uses the cheap
// LandmarkGazeEstimator proxy so it runs *before* the CoreML model exists; swap
// in the CoreML estimator (U6/U7) once converted.

let live = CommandLine.arguments.contains("--live")
let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)

// Request camera access synchronously before starting.
let sem = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
sem.wait()
guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
    FileHandle.standardError.write(Data(
        "Camera access denied. Grant it in System Settings ▸ Privacy & Security ▸ Camera, then re-run.\n".utf8))
    exit(1)
}
if live && !AccessibilityPermission.prompt() {
    FileHandle.standardError.write(Data(
        "--live needs Accessibility permission. Grant it and re-run, or omit --live for dry-run.\n".utf8))
    exit(1)
}

/// Holds the core pipeline state. Every entry point runs on the capture serial
/// queue (via the `onSample` callback), so the state is queue-confined.
final class SpikeProcessor: @unchecked Sendable {
    private var detector = FixationDetector(config: .init(dispersionThreshold: 60,
                                                          minDuration: 0.1,
                                                          minConfidence: 0.4))
    private let mapper = ZoneMapper()
    private var policy = CommitPolicy()
    private let windowControl: AXWindowControl?
    private let dwellThreshold: Instant = 0.6   // fixed default for the spike (KTD5)
    private var currentFocused: WindowID?
    private var lastLog: Instant = 0

    init(live: Bool) { windowControl = live ? AXWindowControl() : nil }

    func process(_ sample: GazeSample) {
        let fixation = detector.add(sample)
        let windows = CGWindowEnumerator.windows()

        var target: WindowID? = nil
        if case let .fixation(point, _) = fixation,
           case let .window(id) = mapper.resolve(point: point, windows: windows) {
            target = id
        }

        let input = CommitPolicy.Input(
            now: sample.t, fixation: fixation, confidence: sample.confidence,
            target: target, liveTargetCount: windows.count, typingSuppressed: false,
            dwellThreshold: dwellThreshold, requireFreshGaze: false,
            currentFocused: currentFocused, targetStillLive: target != nil)
        let result = policy.evaluate(input)

        if sample.t - lastLog > 0.2 {   // throttle the live readout to ~5Hz
            lastLog = sample.t
            let zone = target.map { "win \($0)" } ?? "—"
            FileHandle.standardError.write(Data(
                "gaze=(\(Int(sample.point.x)),\(Int(sample.point.y))) conf=\(String(format: "%.2f", sample.confidence)) windows=\(windows.count) target=\(zone)\n".utf8))
        }

        if case let .switchTo(id) = result.decision {
            print("[\(windowControl == nil ? "WOULD SWITCH" : "SWITCH")] -> window \(id)")
            if let wc = windowControl, let w = windows.first(where: { $0.id == id }) {
                _ = wc.focus(windowID: id, ownerPID: w.ownerPID)
            }
            currentFocused = id
        }
    }
}

let processor = SpikeProcessor(live: live)
let capture = CaptureController(estimator: LandmarkGazeEstimator(), screenSize: screenSize) { sample in
    processor.process(sample)
}
capture.start()
print("gaze-spike running (\(live ? "LIVE — will switch focus" : "dry-run — logging only")). Ctrl-C to stop.")
RunLoop.main.run()
