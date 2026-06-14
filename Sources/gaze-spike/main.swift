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
func doubleArg(_ name: String, _ fallback: Double) -> Double {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let d = Double(args[i + 1]) else { return fallback }
    return d
}
let dwell = max(0.1, doubleArg("--dwell", 0.45))
let smoothAlpha = min(1, max(0.05, doubleArg("--smooth", 0.35)))  // EMA weight on the newest sample
let cooldown = max(0, doubleArg("--cooldown", 0.4))               // min seconds between switches
let alignMode = args.contains("--align")                          // camera-framing setup, no switching
let screenSize = CGDisplayBounds(CGMainDisplayID()).size
// Refuse a headless/empty display: a zero width would make the estimator map every
// gaze to the left edge as a *confident* point — the opposite of "uncertain ⇒ hold".
guard screenSize.width > 0, screenSize.height > 0 else {
    FileHandle.standardError.write(Data("No usable display (screen size is empty). Connect a display and re-run.\n".utf8))
    exit(1)
}

let sem = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
sem.wait()
guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
    FileHandle.standardError.write(Data("Camera access denied. Grant it in System Settings ▸ Privacy & Security ▸ Camera, then re-run.\n".utf8))
    exit(1)
}

// The typing-guard's global key monitor rides the Accessibility grant; prompt
// non-fatally (if denied, the guard simply stays inert — gate 2 just won't show
// suppression). Records timing only, never key content.
let axTrusted = AccessibilityPermission.prompt()

// NSEvent global monitors only fire under a running NSApplication event loop —
// a bare RunLoop is not enough. Accessory policy = no Dock icon, no focus theft.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let typingMonitor = KeystrokeMonitor()
typingMonitor.start()

func selectITermPane(index: Int) {
    // iTerm2 sessions in a tab, selected by order (assumed left-to-right for a
    // horizontal split). Uses the scripting `select`, not synthetic key events.
    // In-process NSAppleScript (on the main thread, as it requires) is faster
    // than spawning an `osascript` subprocess per switch.
    let source = """
    tell application "iTerm2"
      tell current window
        tell current tab
          set ss to sessions
          if (count of ss) > \(index) then tell item (\(index) + 1) of ss to select
        end tell
      end tell
    end tell
    """
    DispatchQueue.main.async {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
    }
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
    private var smoothed: Point2D?
    private var lastSwitch: Instant = -100
    private let typing: KeystrokeMonitor
    private let typingGuard = TypingGuard()
    private let dwell: Instant
    private let smoothAlpha: Double
    private let cooldown: Instant
    private let alignMode: Bool
    private let screenW: Double
    private var goodSince: Instant?          // align-mode: when the current OK streak began
    private var lastFrameT: Instant?         // align-mode: previous frame time, for stream-gap detection
    private let holdSeconds: Instant = 1.0   // sustained OK required before "LOCKED" (strict, one-time setup)
    private let maxAlignGap: Instant = 0.3   // a longer stream pause restarts the OK streak (no credit across stalls)
    private let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    // Eye-framing thresholds, all FRAME-NORMALIZED 0..1. Starting seeds — the
    // readout prints raw eyeX / span so the user self-calibrates. x-centering is
    // strict (0.5 is well-defined and mirror-invariant); y stays loose because a
    // laptop webcam sits below the eye line, so the resting pupil-y is hardware-
    // dependent (~0.55-0.62), not 0.5 — we only catch gross top/bottom misframing.
    private let spanFar = 0.045, spanNear = 0.14      // inter-pupillary distance band
    private let xDeadband = 0.08                      // |eyeCenter.x - 0.5| tolerance (strict)
    private let yLo = 0.20, yHi = 0.85                // eyes-near-frame-edge gate (loose)
    private let faceFarSize = 0.18                    // coarse "face too small" when pupils drop out

    init(live: Bool, paneColumns: Int, typing: KeystrokeMonitor, dwell: Instant,
         smoothAlpha: Double, cooldown: Instant, alignMode: Bool, screenW: Double) {
        self.live = live; self.paneColumns = paneColumns; self.typing = typing
        self.dwell = dwell; self.smoothAlpha = smoothAlpha; self.cooldown = cooldown
        self.alignMode = alignMode; self.screenW = screenW
    }

    private func f1(_ v: Double) -> String { String(format: "%.1f", v) }
    private func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    /// Eye-tracking + framing assessment. Tracks the **eyeballs (pupils)**, not the
    /// face box: a face can be framed while the pupils are unresolved (blink, glare,
    /// looking down) — `eyesDetected` is that signal, and gaze can't work without it.
    /// Eye-first order; only the no-eyes branch falls back to face-box distance.
    private func alignment(_ frame: GazeFrame) -> (ok: Bool, hint: String) {
        if !frame.faceDetected { return (false, "no face — face the camera") }
        if !frame.eyesDetected {
            return frame.faceSize < faceFarSize
                ? (false, "eyes not found — move closer")
                : (false, "eyes not tracked — look at the camera, open eyes, cut glare")
        }
        if frame.eyeSpan < spanFar { return (false, "too far — move closer") }
        if frame.eyeSpan > spanNear { return (false, "too close — move back") }
        if abs(frame.eyeCenter.x - 0.5) > xDeadband { return (false, "off-center — recenter (watch eye.x → 0.5)") }
        if frame.eyeCenter.y < yLo || frame.eyeCenter.y > yHi { return (false, "tilt camera — eyes near frame edge") }
        // Lock only when the gaze pipeline actually produced an estimate — the same
        // condition the switch path needs. Eyes can be framed (both pupils) while
        // estimate() still returns nil (degenerate eye contour), so framing alone
        // must not certify LOCKED, or the readout says LOCKED while look=—.
        if frame.sample == nil { return (false, "eyes framed but no gaze — look right at the camera") }
        return (true, "eyes locked")
    }

    /// Where the eyes are looking, as a coarse left/center/right + the gaze x as a
    /// fraction of screen width — the "computed approximate gaze position" readout.
    private func look(_ sample: GazeSample?) -> (label: String, fx: Double) {
        guard let s = sample, screenW > 0 else { return ("—", .nan) }
        let fx = s.point.x / screenW
        let label = fx < 0.4 ? "L" : (fx > 0.6 ? "R" : "C")
        return (label, fx)
    }

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

    func process(_ frame: GazeFrame) {
        let (alignOK, alignHint) = alignment(frame)

        // Alignment mode: only show eye framing, never switch. Strict, one-time
        // setup — require a *sustained* OK streak (holdSeconds) before declaring
        // LOCKED, so a momentary flick through center doesn't read as aligned.
        if alignMode {
            // A stream stall (no frames delivered) must not let `held` span the gap
            // and lock on a single post-stall frame — restart the streak from now.
            // Mirrors the core FixationDetector's inter-sample gap eviction.
            let continuous = lastFrameT.map { frame.t - $0 <= maxAlignGap } ?? false
            lastFrameT = frame.t
            if alignOK { if goodSince == nil || !continuous { goodSince = frame.t } } else { goodSince = nil }
            let held = goodSince.map { frame.t - $0 } ?? 0
            let locked = held >= holdSeconds
            if frame.t - lastLog > 0.25 {
                lastLog = frame.t
                let status = locked ? "OK ✓ LOCKED"
                    : alignOK ? "OK — hold \(f1(max(0, holdSeconds - held)))s"
                    : "✗ \(alignHint)"
                let (lk, fx) = look(frame.sample)
                let gaze = fx.isNaN ? "look=—" : "look=\(lk) gaze.x=\(f2(fx))"
                FileHandle.standardError.write(Data(
                    "\(timeFmt.string(from: Date())) ALIGN \(status) · eye=(\(f2(clamp01(frame.eyeCenter.x))),\(f2(clamp01(frame.eyeCenter.y)))) span=\(f1(frame.eyeSpan * 100))% · \(gaze)\n".utf8))
            }
            return
        }

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

        // No usable gaze this frame (eyes lost / low quality) — surface framing and stop.
        guard let sample = frame.sample else {
            if frame.t - lastLog > 0.3 {
                lastLog = frame.t
                FileHandle.standardError.write(Data(
                    "\(timeFmt.string(from: Date())) eye✗ \(alignHint) look=—\n".utf8))
            }
            return
        }

        // EMA-smooth the noisy proxy gaze before fixation detection.
        let raw = sample.point
        let sm: Point2D
        if let prev = smoothed {
            sm = Point2D(x: smoothAlpha * raw.x + (1 - smoothAlpha) * prev.x,
                         y: smoothAlpha * raw.y + (1 - smoothAlpha) * prev.y)
        } else {
            sm = raw
        }
        smoothed = sm
        let smSample = GazeSample(t: sample.t, point: sm, confidence: sample.confidence)

        let fixation = detector.add(smSample)
        var target: WindowID? = nil
        if case let .fixation(point, _) = fixation,
           case let .window(id) = mapper.resolve(point: point, windows: panes) {
            target = id
        }

        let suppressed = typingGuard.isSuppressed(lastKeystroke: typing.lastKeystroke, now: sample.t)
        let input = CommitPolicy.Input(
            now: sample.t, fixation: fixation, confidence: sample.confidence,
            target: target, liveTargetCount: panes.count, typingSuppressed: suppressed,
            dwellThreshold: dwell, requireFreshGaze: false,
            currentFocused: currentPane, targetStillLive: target != nil)
        let result = policy.evaluate(input)

        if sample.t - lastLog > 0.2 {
            lastLog = sample.t
            let pane = target.flatMap { $0 < labels.count ? labels[$0] : "\($0)" } ?? "—"
            let typingFlag = suppressed ? " typing" : ""
            let eye = alignOK ? "eye✓" : "eye⚠︎(\(alignHint))"
            let gx = screenW > 0 ? f2(sm.x / screenW) : "?"   // 0..1 fraction, same unit as align mode
            FileHandle.standardError.write(Data(
                "\(timeFmt.string(from: Date())) \(eye) gaze.x=\(gx) conf=\(String(format: "%.2f", sample.confidence)) look=\(pane)\(typingFlag)\n".utf8))
        }

        // Commit, rate-limited by the cooldown to stop rapid flicker.
        if case let .switchTo(id) = result.decision, sample.t - lastSwitch >= cooldown {
            lastSwitch = sample.t
            print("\(timeFmt.string(from: Date())) [\(live ? "SELECT" : "WOULD SELECT")] pane \(id < labels.count ? labels[id] : "\(id)")")
            if live { selectITermPane(index: id) }
            currentPane = id
        }
    }
}

let processor = SpikeProcessor(live: live, paneColumns: paneColumns, typing: typingMonitor,
                               dwell: dwell, smoothAlpha: smoothAlpha, cooldown: cooldown,
                               alignMode: alignMode, screenW: Double(screenSize.width))
let capture = CaptureController(estimator: LandmarkGazeEstimator(), screenSize: screenSize, decimation: 2) { frame in
    processor.process(frame)
}
capture.start()
if alignMode {
    print("gaze-spike ALIGN mode — tracks your eyes (pupils). Adjust camera/seat until it holds \"OK ✓ LOCKED\" (~1s steady), then re-run without --align. Ctrl-C to stop.")
} else {
    print("gaze-spike running (\(live ? "LIVE — selects iTerm2 panes" : "dry-run — logging only")), \(paneColumns) panes, dwell \(dwell)s, smooth \(smoothAlpha), cooldown \(cooldown)s, typing-guard \(axTrusted ? "ON" : "OFF"). Ctrl-C to stop.")
}
app.run()
