#!/bin/sh
# Enable per-packet usbmuxd logging (seq/ack/win) for OpenDisplay diagnostics.
# Requires sudo — restarts Apple's usbmuxd daemon.
#
# Both prefs are required:
#   DebugLevel 7 — lowers the daemon log filter so lines reach unified log
#   LogPackets   — emits per-packet seq/ack/win lines (very verbose)
set -e
PLIST=/Library/Preferences/com.apple.usbmuxd.plist
sudo defaults write "$PLIST" DebugLevel -int 7
sudo defaults write "$PLIST" LogPackets -bool true
echo "Wrote DebugLevel=7 and LogPackets=true to $PLIST"
echo "Restarting usbmuxd…"
sudo launchctl kickstart -k system/com.apple.usbmuxd 2>/dev/null \
  || sudo killall usbmuxd 2>/dev/null \
  || true
sleep 1
echo ""
echo "Verify (connect iPad via USB, then use OpenDisplay — expect a flood of lines):"
echo '  log stream --predicate '"'"'process == "usbmuxd"'"'"' --info --debug --style compact'
echo ""
echo "Look for: seq= ack= win=  and  send window"
echo ""
echo "You should also see shortly after restart:"
echo '  usbmuxd … log filter changed from … to 7'
echo ""
echo "To disable later:"
echo "  sudo rm $PLIST && sudo launchctl kickstart -k system/com.apple.usbmuxd"
