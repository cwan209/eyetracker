# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Communication

**Always reply to the user in Chinese (中文) in this repository — this is a firm preference, not a soft default.** All prose written back to the user, including explanations, status updates, and questions, must be in Chinese. The only things that stay in English: code, identifiers, file paths, commit messages, and the canonical `.md` design docs. Technical terms with no natural Chinese equivalent may stay in English inline, but the surrounding sentence is Chinese.

## What this is

A macOS menu-bar utility (work in progress) that switches keyboard focus to whichever side-by-side terminal window you look at — webcam gaze → a short personalized dwell → focus switch, no key or mouse. Native Swift 6, macOS 15 Sequoia, Apple Silicon.

**The design source of truth is `docs/`, not the code.** Read these before changing behavior:
- `docs/plans/2026-06-13-001-feat-gaze-focus-switcher-plan.md` — implementation plan with stable **U-IDs** (units), **KTDs** (technical decisions), Risks, and Open Questions. Cite these IDs in commits/PRs.
- `docs/brainstorms/2026-06-13-gaze-terminal-focus-requirements.md` — product requirements with **R-IDs / F-IDs / AE-IDs**.

The `.html` files next to them are human-reading twins (Chinese); the `.md` files are canonical (English). When producing new design docs for this project, keep that split: English markdown is the source, a Chinese HTML twin is for reading.

## Commands

```bash
swift build                                   # build all targets (Swift 6 strict concurrency)
swift test                                    # run all unit tests
swift test --filter CommitPolicyTests         # one test class
swift test --filter LifecycleTests/testRaceSafetyNeverActiveWhileLocked   # one test
swift run gaze-spike                           # dry-run gaze harness (logs only, never steals focus)
swift run gaze-spike --live                    # actually switch focus (needs Accessibility permission)
```

`Scripts/convert_gaze_model.py` (L2CS-Net → CoreML) is **offline tooling**, not part of `swift build` — it needs Python + PyTorch + coremltools and is run by hand. The `.mlpackage` it produces is not in the repo; until then the gaze pipeline uses a model-free landmark proxy.

## Architecture

Two layers, with a hard boundary between them:

- **`GazeFocusCore`** (`Sources/GazeFocusCore/`) — all perception, decision, learning, and lifecycle logic as **pure value types over injected data**. It **must not import AppKit / AVFoundation / Vision / CoreML** — that purity is what makes the safety-critical logic headlessly testable with synthetic streams (`swift test` runs entirely here). OS dependencies are abstracted behind protocols in `Ports/Ports.swift` (`WindowControl`, `GazeSource`, `KeystrokeActivity`, `Clock`, `ModelStore`).
- **`GazeFocusShell`** (`Sources/GazeFocusShell/`) — the OS-bound implementations of those ports: `Capture/` (AVCaptureSession + Vision + the gaze estimator), `WindowControl/` (CGWindowList + AXUIElement), `Storage/` (CryptoKit + Keychain), `SystemEvents/`, `LoginItem/`. Depends on the core; never the reverse.
- **`gaze-spike`** (`Sources/gaze-spike/`) — a CLI that wires camera → core to run the two on-device validation gates (below) before the real app exists.

Data flow: shell emits Sendable `GazeSample`s into the core (`FixationDetector` → `ZoneMapper` → `CommitPolicy`); the core returns a `FocusDecision` the shell acts on. A single `LifecycleReducer` is the **sole sink** for both system events and learning events, so they cannot race two owners.

### Load-bearing invariants — do not break these

- **"Never switch focus at the wrong moment."** Every uncertain condition resolves to *hold focus*, never a guess. The `CommitPolicy` gate chain ordering (post-wake gate → confidence/targets → typing-guard → dwell threshold → target-still-live) is load-bearing; a guard that lets a switch through when it shouldn't is the dangerous failure direction. Changes here need adversarial test coverage in both directions.
- **`requireFreshGaze`** (post-wake/post-pause staleness gate) is set by the lifecycle reducer and cleared **only** by a `freshGazeSeen` event the policy emits on the first confident fixation. Don't add a second clear path.
- **`LifecycleReducer.reduce` is a total function** — every (state, event) pair is defined; undefined ones are identity. This is what keeps `Active`-while-locked unreachable. Preserve totality.
- **`FixationDetector` assumes a monotonic time base** and evicts on both spatial dispersion and inter-sample time gap — the gap eviction prevents a silent stream pause from inflating dwell into a wrong switch. Keep both.

### Concurrency (KTD9)

The capture path (`CaptureController`) is the project's top risk and uses the **simplest serial-queue-confined structure**, not a custom-executor actor: a `final class` marked `@unchecked Sendable` with all mutable state confined to one private serial `DispatchQueue` (the sample-buffer delegate is invoked on it). The `nonisolated` delegate extracts the Sendable `CVPixelBuffer` from the non-Sendable `CMSampleBuffer` before any boundary crossing. This compiling clean under Swift 6 complete checking is the validation. Don't reach for an actor + custom executor unless a concrete need appears, and never hand a `CMSampleBuffer`/`AVCaptureSession` across an isolation boundary.

## Platform constraints baked into the design

- **Two TCC permissions only: Accessibility + Camera.** The typing-guard rides the Accessibility grant via `NSEvent` (timing only — never `event.characters`). Window targeting reads geometry + owner PID/name only, **never window titles**, which is what avoids needing Screen Recording permission. Don't introduce a third permission.
- **Not sandboxable / not Mac App Store.** Accessibility (`AXIsProcessTrusted`) returns false under the App Sandbox, so this ships as a Developer-ID-signed, notarized app outside the MAS. `AXWindowControl` uses the private-but-standard `_AXUIElementGetWindow` bridge (declared via `@_silgen_name`) to map AX windows to CG window IDs.
- **`gaze-spike` embeds an `Info.plist`** into its binary via a linker `-sectcreate` flag (see `Package.swift`) so a plain CLI can request Camera access. If camera TCC won't prompt from the CLI on a given machine, the fallback is dropping the sources into a tiny Xcode app target.

## Build status and what's gated

Built + tested today: core (U1–U5, U14) and shell ports U7 (capture), U8 (window control), U12 (system events), U13 (storage), U15 (login). The full menu-bar app (**U10**) needs a real Xcode app bundle (LSUIElement / Info.plist / entitlements) that `swift build` does not produce. **U11 (4-point calibration) is intentionally not built** — the plan gates it on two human-run, on-device measurements (`gaze-spike`): whether a webcam can separate left/center/right zones, and whether pure dwell avoids false switches during a *silent reading pause*. If those fail, the plan's look-then-press fallback reshapes the remaining work. Run the spike before building U10/U11 or wiring the CoreML estimator.
