import AppKit
import AVFoundation
import Foundation
import GazeFocusCore
import GazeFocusShell

// gaze-spike — dry-run harness for the gaze-driven *iTerm2 split-pane* switcher.
// Targets are the left/right halves of the frontmost iTerm2 window (synthetic
// pane regions, non-overlapping by construction), so it tests the real question:
//   1. Can a webcam pick the left vs right split pane you look at? (`pane=L/R`)
//   2. Does it false-select while you *read* the other pane? (`[WOULD SELECT]`)
// Dry-run by default (logs only). `--live` selects the pane via iTerm2 AppleScript.
// `--panes N` splits into N columns (default 2).

let args = CommandLine.arguments
let live = args.contains("--live")
let paneColumns: Int = {
    guard let i = args.firstIndex(of: "--panes"), i + 1 < args.count, let n = Int(args[i + 1]) else { return 2 }
    return max(2, n)
}()
let screenSize = CGDisplayBounds(CGMainDisplayID()).size

let sem = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
sem.wait()
guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
    FileHandle.standardError.write(Data("Camera access denied. Grant it in System Settings ▸ Privacy & Security ▸ Camera, then re-run.\n".utf8))
    exit(1)
}

func selectITermPane(index: Int) {
    // iTerm2 sessions in a tab, selected by order (assumed left-to-right for a
    // horizontal split). Uses the scripting `select`, not synthetic key events.
    let script = """
    tell application "iTerm2"
      tell current window
        tell current tab
          set ss to sessions
          if (count of ss) > \(index) then tell item (\(index) + 1) of ss to select
        end tell
      end tell
    end tell
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
}

/// State runs on the capture serial queue (via `onSample`).
final class SpikeProcessor: @unchecked Sendable {
    private var detector = FixationDetector(config: .init(dispersionThreshold: 150, minDuration: 0.1, minConfidence: 0.4))
    private let mapper = ZoneMapper(config: .init(borderDeadband: 24, maxWindows: 8, minWindowSize: 80))
    private var policy = CommitPolicy()
    private let live: Bool
    private let paneColumns: Int
    private let labels = ["L", "R", "3", "4", "5", "6"]
    private var currentPane: WindowID?
    private var lastLog: Instant = 0
    private var dumped = false

    init(live: Bool, paneColumns: Int) { self.live = live; self.paneColumns = paneColumns }

    /// Synthetic pane targets: the frontmost iTerm2 window split into N columns.
    private func panes() -> [WindowSnapshot] {
        guard let term = CGWindowEnumerator.windows().first(where: { $0.ownerName.localizedCaseInsensitiveContains("iTerm") }) else {
            return []
        }
        let b = term.bounds
        let colW = b.width / Double(paneColumns)
        return (0..<paneColumns).map { i in
            WindowSnapshot(id: i, ownerPID: term.ownerPID, ownerName: "pane\(i)",
                           bounds: Rect(x: b.x + Double(i) * colW, y: b.y, width: colW, height: b.height))
        }
    }

    func process(_ sample: GazeSample) {
        let panes = self.panes()

        if !dumped {
            dumped = true
            var dump = "frontmost iTerm2 split into \(panes.count) pane region(s):\n"
            for (i, p) in panes.enumerated() {
                dump += "  pane \(labels[i]) x=\(Int(p.bounds.x))..\(Int(p.bounds.maxX))\n"
            }
            if panes.isEmpty { dump += "  (no iTerm2 window found in front)\n" }
            FileHandle.standardError.write(Data(dump.utf8))
        }

        let fixation = detector.add(sample)
        var target: WindowID? = nil
        if case let .fixation(point, _) = fixation,
           case let .window(id) = mapper.resolve(point: point, windows: panes) {
            target = id
        }

        let input = CommitPolicy.Input(
            now: sample.t, fixation: fixation, confidence: sample.confidence,
            target: target, liveTargetCount: panes.count, typingSuppressed: false,
            dwellThreshold: 0.6, requireFreshGaze: false,
            currentFocused: currentPane, targetStillLive: target != nil)
        let result = policy.evaluate(input)

        if sample.t - lastLog > 0.2 {
            lastLog = sample.t
            let pane = target.flatMap { $0 < labels.count ? labels[$0] : "\($0)" } ?? "—"
            FileHandle.standardError.write(Data(
                "gaze.x=\(Int(sample.point.x)) conf=\(String(format: "%.2f", sample.confidence)) panes=\(panes.count) look=\(pane)\n".utf8))
        }

        if case let .switchTo(id) = result.decision {
            print("[\(live ? "SELECT" : "WOULD SELECT")] pane \(id < labels.count ? labels[id] : "\(id)")")
            if live { selectITermPane(index: id) }
            currentPane = id
        }
    }
}

let processor = SpikeProcessor(live: live, paneColumns: paneColumns)
let capture = CaptureController(estimator: LandmarkGazeEstimator(), screenSize: screenSize) { sample in
    processor.process(sample)
}
capture.start()
print("gaze-spike running (\(live ? "LIVE — selects iTerm2 panes" : "dry-run — logging only")), \(paneColumns) panes. Ctrl-C to stop.")
RunLoop.main.run()
