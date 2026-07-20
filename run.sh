#!/bin/zsh
# Start the Mac sender app. The phone app must be running (it listens on
# :9000); USB connectivity goes through macOS's built-in usbmuxd — no tunnel
# tool needed. The Mac app retries until the device shows up.
set -e
cd "$(dirname "$0")"

APP=build/Build/Products/Debug/OpenDisplay.app
if [[ ! -d $APP ]]; then
  echo "Mac app not built — run: xcodegen generate && xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac -configuration Debug -derivedDataPath build build"
  exit 1
fi

# Must kill by process name — the binary is OpenDisplay, not OpenSidecarMac.
# Also quit the /Applications install if it's running (same process name,
# different bundle id) so the iPad doesn't connect to a stale release build.
if pgrep -xq OpenDisplay; then
  echo "Stopping existing OpenDisplay instance(s)…"
  killall OpenDisplay 2>/dev/null || true
  sleep 2
fi

open "$APP"
sleep 1
echo "OpenDisplay running from: $APP"
echo "Started: $(date)"
echo "PID: $(pgrep OpenDisplay)"
echo "Bundle: $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
echo "Logs at /tmp/opensidecar-mac.log."
