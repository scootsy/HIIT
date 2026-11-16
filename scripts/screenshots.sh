#!/bin/bash
# Photographs every screen of the app on simulators, using the Debug build's
# demo mode (HIIT/Support/DemoMode.swift) to open each one with sample data.
#
#   ./scripts/screenshots.sh [output-directory]
#
# Run by the "Simulator screenshots" job of the Build & Release workflow
# (Actions → Build & Release IPA → Run workflow → tick the box), or on any
# Mac with Xcode 27.1 or later. Pictures land in the output directory as
# JPEGs small enough to page through.
#
# What gets photographed:
#   1. iPhone Duo in the pose the simulator boots in: every screen
#   2. iPhone Duo opened, closed, turned on its side and half folded: the
#      screens whose layout depends on the pose. `simctl` has no command for
#      the hinge, so this step borrows a small open-source tool that talks
#      to the simulator the way Xcode does. If that stops working, the live
#      workout is drawn at those poses' sizes instead ("canvas" shots —
#      exact for the app's own layout, without the system's bars).
#   3. an ordinary iPhone, upright and on its side: the main screens
set -uo pipefail

OUT="${1:-screenshots}"
BUNDLE="com.scootsy.HIIT"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build-sim"
RAW="$(mktemp -d)"
mkdir -p "$OUT"
cd "$ROOT"

log() { printf '\n=== %s\n' "$*"; }

SDK="$(xcrun --sdk iphonesimulator --show-sdk-version)"
log "Xcode $(xcodebuild -version | tr '\n' ' ') · simulator SDK $SDK"

# The newest simulator of this name whose iOS version doesn't exceed the SDK
# the app is built with. Prints "UDID VERSION", or nothing.
find_device() {
  xcrun simctl list devices available --json | python3 -c '
import json, sys
name, ceiling = sys.argv[1], tuple(int(p) for p in sys.argv[2].split("."))
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(p) for p in runtime.rsplit(".iOS-", 1)[1].split("-") if p.isdigit())
    if version[:2] > ceiling[:2]:
        continue
    for device in devices:
        if device.get("name") == name and (best is None or version > best[0]):
            best = (version, device["udid"])
if best:
    print(best[1], ".".join(str(p) for p in best[0]))
' "$1" "$SDK"
}

read -r DUO DUO_OS <<< "$(find_device 'iPhone Duo')"
PHONE=""
for NAME in "iPhone 17" "iPhone 18 Pro" "iPhone 17e" "iPhone Air"; do
  read -r PHONE PHONE_OS <<< "$(find_device "$NAME")"
  if [ -n "$PHONE" ]; then PHONE_NAME="$NAME"; break; fi
done
echo "iPhone Duo simulator: ${DUO:-none} (iOS ${DUO_OS:-?})"
echo "iPhone simulator:     ${PHONE:-none} (${PHONE_NAME:-?}, iOS ${PHONE_OS:-?})"
if [ -z "$DUO" ] && [ -z "$PHONE" ]; then
  echo "No usable simulator found."
  xcrun simctl list devices available
  exit 1
fi
BUILD_FOR="${DUO:-$PHONE}"

log "Building the Debug app for the simulator"
set -o pipefail
xcodebuild \
  -project HIIT.xcodeproj \
  -scheme HIIT \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$BUILD_FOR" \
  -derivedDataPath "$DERIVED" \
  build 2>&1 | tee "$RAW/xcodebuild.log" | (xcbeautify --quiet || cat)
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "The simulator build failed:"
  grep -E "(error|fatal error):" "$RAW/xcodebuild.log" | sort -u | head -n 120
  exit 1
fi
APP="$DERIVED/Build/Products/Debug-iphonesimulator/HIIT.app"
test -d "$APP" || { echo "Built app not found at $APP"; exit 1; }

boot() {
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b > /dev/null
  xcrun simctl install "$1" "$APP"
  # A tidy status bar where the simulator supports overriding it.
  xcrun simctl status_bar "$1" override --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 > /dev/null 2>&1 || true
}

# shoot UDID NAME [launch arguments…] — open the app on one demo screen and
# photograph it.
SETTLE=3
shoot() {
  local udid="$1" name="$2"
  shift 2
  xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1 || true
  if ! xcrun simctl launch "$udid" "$BUNDLE" "$@" > /dev/null 2>&1; then
    echo "  launch failed: $name"
    return
  fi
  sleep "$SETTLE"
  if xcrun simctl io "$udid" screenshot "$RAW/$name.png" > /dev/null 2>&1; then
    # Smaller copies for review: long edge 1500 px, JPEG.
    sips -s format jpeg -s formatOptions 72 -Z 1500 "$RAW/$name.png" --out "$OUT/$name.jpg" > /dev/null 2>&1 \
      || cp "$RAW/$name.png" "$OUT/$name.png"
    echo "  $name  ($(sips -g pixelWidth -g pixelHeight "$RAW/$name.png" 2>/dev/null | awk '/pixel/ {printf "%s ", $2}'))"
  else
    echo "  screenshot failed: $name"
  fi
}

# Every screen, in whatever pose the device is in. PREFIX names the files.
all_screens() {
  local udid="$1" prefix="$2"
  shoot "$udid" "$prefix-01-home"              -demoScreen home
  shoot "$udid" "$prefix-02-setup"             -demoScreen setup
  shoot "$udid" "$prefix-03-workout-work"      -demoScreen workout -demoState work
  shoot "$udid" "$prefix-04-workout-warning"   -demoScreen workout -demoState warning
  shoot "$udid" "$prefix-05-workout-coach"     -demoScreen workout -demoState suggestion
  shoot "$udid" "$prefix-06-workout-bike"      -demoScreen workout -demoState recover -demoEquipment bike
  shoot "$udid" "$prefix-07-workout-endurance" -demoScreen workout -demoState endurance
  shoot "$udid" "$prefix-08-workout-done"      -demoScreen workout -demoState overtime
  shoot "$udid" "$prefix-09-summary"           -demoScreen summary
  shoot "$udid" "$prefix-10-history"           -demoScreen history
  shoot "$udid" "$prefix-11-detail"            -demoScreen detail
  shoot "$udid" "$prefix-12-settings"          -demoScreen settings
  shoot "$udid" "$prefix-13-welcome"           -demoScreen welcome
}

# The screens whose layout changes most between poses.
key_screens() {
  local udid="$1" prefix="$2"
  shoot "$udid" "$prefix-info"    -demoScreen workout -demoState work -demoInfo 1
  shoot "$udid" "$prefix-work"    -demoScreen workout -demoState work
  shoot "$udid" "$prefix-warning" -demoScreen workout -demoState warning
  shoot "$udid" "$prefix-coach"   -demoScreen workout -demoState suggestion
  shoot "$udid" "$prefix-home"    -demoScreen home
  shoot "$udid" "$prefix-setup"   -demoScreen setup
  shoot "$udid" "$prefix-summary" -demoScreen summary
}

# The live workout only — the one fully custom layout.
workout_only() {
  local udid="$1" prefix="$2"
  shoot "$udid" "$prefix-info"    -demoScreen workout -demoState work -demoInfo 1
  shoot "$udid" "$prefix-work"    -demoScreen workout -demoState work
  shoot "$udid" "$prefix-warning" -demoScreen workout -demoState warning
}

if [ -n "$DUO" ]; then
  log "iPhone Duo (iOS $DUO_OS): booting"
  boot "$DUO"
  xcrun simctl io "$DUO" enumerate 2>/dev/null | grep -iE "display|class|width|height|port" | head -n 40 || true

  log "iPhone Duo: every screen, as booted"
  SETTLE=8
  shoot "$DUO" "duo-00-info" -demoScreen workout -demoState work -demoInfo 1
  SETTLE=2.5
  all_screens "$DUO" "duo"

  log "iPhone Duo: real poses (best effort)"
  # foldctl (MIT, github.com/tatsuz0u/foldctl) sets the simulator's hinge and
  # orientation through the same private CoreDevice channel Xcode's Device
  # Hub uses. Pinned to a reviewed commit; if it can't build or connect, the
  # canvas shots below stand in for the poses.
  FOLDCTL_DIR="$RAW/foldctl"
  FOLDCTL_REF="be3846f6b7371945c7c3eda973ff02ce330c9032"
  pose() { "$FOLDCTL_DIR/foldctl" "$DUO" "$@" 2>&1 | tail -n 2; sleep 3; }
  if git clone --quiet https://github.com/tatsuz0u/foldctl.git "$FOLDCTL_DIR" 2>/dev/null \
     && git -C "$FOLDCTL_DIR" checkout --quiet "$FOLDCTL_REF" 2>/dev/null \
     && "$FOLDCTL_DIR/foldctl" "$DUO" > "$RAW/foldctl.log" 2>&1; then
    echo "Hinge control available — simulator reports: $(tail -n 1 "$RAW/foldctl.log")"
    pose --hinge open --orientation portrait;          key_screens  "$DUO" "pose-open-portrait"
    pose --hinge open --orientation landscape-left;    key_screens  "$DUO" "pose-open-landscape"
    pose --hinge half --orientation landscape-left;    workout_only "$DUO" "pose-laptop"
    pose --hinge half --orientation portrait;          workout_only "$DUO" "pose-book"
    pose --hinge closed --orientation portrait;        key_screens  "$DUO" "pose-closed-portrait"
    pose --hinge closed --orientation landscape-left;  workout_only "$DUO" "pose-closed-landscape"
    pose --hinge open --orientation portrait
  else
    echo "Couldn't drive the hinge from the command line on this Xcode:"
    tail -n 6 "$RAW/foldctl.log" 2>/dev/null
    log "iPhone Duo: the live workout at the other poses' sizes (canvas)"
    # width x height in points, roughly the safe area of: closed, open
    # upright, open on its side, half a book fold, closed on its side
    for CANVAS in 400x620 626x830 890x600 300x850 620x400; do
      shoot "$DUO" "canvas-$CANVAS-work"    -demoScreen workout -demoState work -demoCanvas "$CANVAS"
      shoot "$DUO" "canvas-$CANVAS-warning" -demoScreen workout -demoState warning -demoCanvas "$CANVAS"
    done
  fi
  xcrun simctl shutdown "$DUO" > /dev/null 2>&1 || true
fi

if [ -n "$PHONE" ]; then
  log "$PHONE_NAME (iOS $PHONE_OS): booting"
  boot "$PHONE"
  SETTLE=8
  shoot "$PHONE" "iphone-info" -demoScreen workout -demoState work -demoInfo 1
  SETTLE=2.5
  shoot "$PHONE" "iphone-work"      -demoScreen workout -demoState work
  shoot "$PHONE" "iphone-warning"   -demoScreen workout -demoState warning
  shoot "$PHONE" "iphone-coach"     -demoScreen workout -demoState suggestion
  shoot "$PHONE" "iphone-home"      -demoScreen home
  shoot "$PHONE" "iphone-setup"     -demoScreen setup
  shoot "$PHONE" "iphone-summary"   -demoScreen summary
  shoot "$PHONE" "iphone-settings"  -demoScreen settings
  shoot "$PHONE" "iphone-landscape-info" -demoScreen workout -demoState work -demoOrientation landscape -demoInfo 1
  shoot "$PHONE" "iphone-landscape-work" -demoScreen workout -demoState work -demoOrientation landscape
  shoot "$PHONE" "iphone-landscape-home" -demoScreen home -demoOrientation landscape
  xcrun simctl shutdown "$PHONE" > /dev/null 2>&1 || true
fi

log "Done: $(ls "$OUT" | wc -l | tr -d ' ') pictures in $OUT"
ls "$OUT" | head -n 200
