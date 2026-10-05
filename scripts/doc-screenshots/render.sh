#!/bin/bash
# Regenerates the user-guide screenshots in docs/images from the app's own
# SwiftUI views, rendered offscreen with fresh state (nothing from your own
# recordings or windows appears). Usage:
#   scripts/doc-screenshots/render.sh [path/to/demo.transcript.json]
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

# One module: RecCore + the app's views + the harness. Drop the app's @main
# and the RecCore imports (same module here).
for f in Sources/RecCore/*.swift Sources/RecBar/*.swift; do
  sed -e 's/^@main$//' -e '/^import RecCore$/d' "$f" > "$BUILD/$(basename "$f")"
done
cp scripts/doc-screenshots/Harness.swift "$BUILD/"
# The screenshot app has no Screen Recording permission (and shouldn't need
# it); show the panel as it looks once permission is granted.
sed -i '' -e 's/if !CGPreflightScreenCaptureAccess() {/if false {/' \
          -e 's/windows = try await Recorder.availableWindows()/windows = []/' \
          -e 's/windowsHint = windows.isEmpty ? "No app windows on screen right now." : nil/windowsHint = nil/' \
          "$BUILD/RecController.swift"
swiftc -O -parse-as-library -target arm64-apple-macos15.2 -o "$BUILD/doc-screenshots" "$BUILD"/*.swift \
  -framework ScreenCaptureKit -framework AVFoundation -framework UserNotifications 2>&1 | grep -E "error" || true

# Notifications etc. need a real bundle: wrap the binary in a throwaway app
# (its own bundle id, so it can't touch Recall Bar's settings or permissions).
APPDIR="$BUILD/DocScreenshots.app/Contents"
mkdir -p "$APPDIR/MacOS"
mv "$BUILD/doc-screenshots" "$APPDIR/MacOS/doc-screenshots"
cp Sources/RecBar/Info.plist "$APPDIR/Info.plist"
plutil -replace CFBundleIdentifier -string "sg.com.apptechsystem.recbar.docscreenshots" "$APPDIR/Info.plist"
plutil -replace CFBundleExecutable -string "doc-screenshots" "$APPDIR/Info.plist"
plutil -insert RecBarCommit -string "$(git rev-parse HEAD)" "$APPDIR/Info.plist"
plutil -insert RecBarBuildDate -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APPDIR/Info.plist"
codesign --force -s - "$BUILD/DocScreenshots.app" 2>/dev/null

mkdir -p docs/images
open -W -n "$BUILD/DocScreenshots.app" --args "$PWD/docs/images" "${1:-}"
ls -la docs/images
