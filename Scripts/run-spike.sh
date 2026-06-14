#!/usr/bin/env bash
# Run gaze-spike from a minimal, ad-hoc-signed .app bundle.
#
# Why: a bare `swift run gaze-spike` CLI does NOT get a Camera permission prompt
# on macOS Sequoia — TCC needs a code-signed .app bundle to attribute the camera
# usage string, so the bare binary just hangs on the access request. This wraps
# the built executable in a tiny signed bundle so the prompt appears.
#
# Run this from YOUR OWN terminal (so you can see the live readout and Ctrl-C):
#     Scripts/run-spike.sh            # dry-run (logs only)
#     Scripts/run-spike.sh --live     # actually switch focus (needs Accessibility)
#
# On the FIRST run, macOS prompts for Camera access — click Allow, then re-run if
# it had already exited. If no prompt ever appears, open
#   System Settings ▸ Privacy & Security ▸ Camera
# and enable "gaze-spike" (or your terminal) there.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
BIN="$(swift build --show-bin-path)/gaze-spike"
APP=".build/gaze-spike.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/gaze-spike"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.gazefocus.spike</string>
  <key>CFBundleName</key><string>gaze-spike</string>
  <key>CFBundleExecutable</key><string>gaze-spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key>
  <string>gaze-spike estimates where you are looking on screen to test gaze-zone separation. Frames are processed on-device and never stored or sent anywhere.</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Launching $APP/Contents/MacOS/gaze-spike  (Ctrl-C to stop)"
exec "$APP/Contents/MacOS/gaze-spike" "$@"
