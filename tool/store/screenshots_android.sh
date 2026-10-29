#!/usr/bin/env bash
# Store screenshots from a running Android emulator (Pixel 6, 1080x2400):
#   ~/Library/Android/sdk/emulator/emulator -avd Pixel_6_API_33 &
#   tool/store/screenshots_android.sh emulator-5554 store/screenshots/android-phone
set -euo pipefail
device="$1"
out="$2"
app_id="id.co.jcdigital.landscape360.dev"
adb="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
cd "$(dirname "$0")/../.."
mkdir -p "$out"

"$adb" -s "$device" wait-for-device
# A tidy status bar (demo mode): 09:41, full battery and signal, no notifications
"$adb" -s "$device" shell settings put global sysui_demo_allowed 1
demo() { "$adb" -s "$device" shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null; }
demo enter
demo clock -e hhmm 0941
demo battery -e level 100 -e plugged false
demo network -e wifi show -e level 4 -e mobile show -e datatype none -e level 4
demo notifications -e visible false
# Standing near the top of Merbabu
"$adb" -s "$device" emu geo fix 110.4396 -7.4552 3100

log="$(mktemp)"
flutter test integration_test/store_screenshots_test.dart -d "$device" --flavor dev \
  --dart-define-from-file=config/dev.json >"$log" 2>&1 &
test_pid=$!

taken=0
granted=0
while kill -0 "$test_pid" 2>/dev/null; do
  if [ "$granted" = 0 ] && "$adb" -s "$device" shell pm path "$app_id" >/dev/null 2>&1; then
    "$adb" -s "$device" shell pm grant "$app_id" android.permission.ACCESS_FINE_LOCATION && granted=1
  fi
  shots=$(grep -o 'SHOT:[a-z0-9_]*' "$log" | sed 's/SHOT://' || true)
  count=$(printf '%s\n' "$shots" | grep -c . || true)
  if [ "$count" -gt "$taken" ]; then
    name=$(printf '%s\n' "$shots" | sed -n "${count}p")
    sleep 1
    "$adb" -s "$device" exec-out screencap -p >"$out/$name.png"
    echo "saved $out/$name.png"
    taken=$count
  fi
  sleep 0.5
done
wait "$test_pid" || { tail -40 "$log"; exit 1; }
demo exit
grep -E 'passed|failed' "$log" | tail -1
