#!/bin/zsh
# Cold start (process start → Today's first frame), measured inside the app
# (UI-test automation adds ~2.5 s of its own). Budget: median < 1000 ms on the simulator, debug build.
# Usage: ios/Eval/cold-start.sh [path/to/One.app]
set -e
cd "$(dirname "$0")/.."
SIM=$(xcrun simctl list devices booted | grep -m1 -oE "[0-9A-F-]{36}")
APP=${1:-$(ls -d .build/xcode-test/Build/Products/Debug-iphonesimulator/One.app 2>/dev/null || true)}
[[ -n "$APP" ]] && xcrun simctl install "$SIM" "$APP"
TMP=$(mktemp -d)
for i in 1 2 3 4; do
  xcrun simctl terminate "$SIM" com.luworks.today 2>/dev/null || true
  xcrun simctl launch --console-pty "$SIM" com.luworks.today -uiTesting > "$TMP/$i.txt" 2>&1 &
  sleep 5
  kill $! 2>/dev/null || true
done
# Drop the first (install) run; median of the rest.
MS=($(for i in 2 3 4; do grep -oE "first frame: [0-9]+" "$TMP/$i.txt" | grep -oE "[0-9]+"; done | sort -n))
echo "COLD START ms: ${MS[*]}  median ${MS[2]}  (budget 1000)"
[[ ${MS[2]} -lt 1000 ]]
