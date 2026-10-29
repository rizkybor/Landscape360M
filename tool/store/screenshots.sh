#!/usr/bin/env bash
# Store screenshots from a simulator: runs integration_test/store_screenshots_test.dart and
# saves the screen at every scene.
#   tool/store/screenshots.sh <simulator udid> <output folder>
# e.g. iPhone 15 Pro Max (6.7", 1290x2796) and iPad Pro 12.9" (2048x2732).
set -euo pipefail
udid="$1"
out="$2"
app_id="id.co.jcdigital.landscape360.dev"
cd "$(dirname "$0")/../.."
mkdir -p "$out"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
# A tidy status bar, like Apple's own screenshots
xcrun simctl status_bar "$udid" override --time "09:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName ""
# Standing near the top of Merbabu
xcrun simctl location "$udid" set -7.4552,110.4396

log="$(mktemp)"
flutter test integration_test/store_screenshots_test.dart -d "$udid" \
  --dart-define-from-file=config/dev.json >"$log" 2>&1 &
test_pid=$!

taken=0
granted=0
while kill -0 "$test_pid" 2>/dev/null; do
  # Location allowed as soon as the app is on the simulator (no permission dialog in shot)
  if [ "$granted" = 0 ] && xcrun simctl get_app_container "$udid" "$app_id" >/dev/null 2>&1; then
    xcrun simctl privacy "$udid" grant location "$app_id" && granted=1
  fi
  shots=$(grep -o 'SHOT:[a-z0-9_]*' "$log" | sed 's/SHOT://' || true)
  count=$(printf '%s\n' "$shots" | grep -c . || true)
  if [ "$count" -gt "$taken" ]; then
    name=$(printf '%s\n' "$shots" | sed -n "${count}p")
    sleep 1
    xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null
    echo "saved $out/$name.png"
    taken=$count
  fi
  sleep 0.5
done
wait "$test_pid" || { tail -40 "$log"; exit 1; }
xcrun simctl status_bar "$udid" clear
grep -E 'passed|failed' "$log" | tail -1
