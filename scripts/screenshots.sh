#!/bin/bash
# Photographs every screen of the app on the iPhone Duo simulator, using the
# Debug build's demo mode (HIIT/Support/DemoMode.swift) to open each one
# with sample data.
#
#   ./scripts/screenshots.sh [output-directory]
#
# Run by the "Simulator screenshots" job of the Build & Release workflow
# (Actions → Build & Release IPA → Run workflow → tick the box), or on any
# Mac with Xcode 27.1 or later. Takes about a quarter of an hour, most of it
# the simulator's first boot.
#
# What gets photographed:
#   1. iPhone Duo closed, upright: every screen
#   2. iPhone Duo opened, turned on its side, half folded both ways, and
#      closed on its side: the screens whose layout depends on the pose.
#      `simctl` has no command for the hinge, so this step borrows a small
#      open-source tool that talks to the simulator the way Xcode does. If
#      that stops working, the live workout is drawn at those poses' sizes
#      instead ("canvas" shots — exact for the app's own layout).
#   3. the live workout at ordinary iPhone sizes, drawn on the Duo's inner
#      display (canvas shots again). Set WITH_IPHONE=1 to also boot a real
#      iPhone simulator, which adds several minutes.
#
# The pictures come from the app itself (`-demoSnapshot`), not from
# `simctl io screenshot`, which fails on the Duo's two displays. They show
# everything the app draws; the system's status bar isn't part of that.
#
# Besides the files, small copies are printed into the log as text, in a
# folded section at the end. That is for AI coding tools working from a
# sandbox that can read a job's log but can't download its artifacts; set
# PICTURES_IN_LOG=0 to leave it out.
set -uo pipefail

OUT="${1:-screenshots}"
BUNDLE="com.scootsy.HIIT"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build-sim"
RAW="$(mktemp -d)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$ROOT"

log() { printf '\n=== [%3d s] %s\n' "$SECONDS" "$*"; }

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

DUO=""; DUO_OS=""; PHONE=""; PHONE_OS=""; PHONE_NAME=""
read -r DUO DUO_OS <<< "$(find_device 'iPhone Duo')"
if [ "${WITH_IPHONE:-0}" = "1" ] || [ -z "$DUO" ]; then
  for NAME in "iPhone 17" "iPhone 18 Pro" "iPhone 17e" "iPhone Air"; do
    read -r PHONE PHONE_OS <<< "$(find_device "$NAME")"
    if [ -n "$PHONE" ]; then PHONE_NAME="$NAME"; break; fi
  done
fi
echo "iPhone Duo simulator: ${DUO:-none} (iOS ${DUO_OS:-?})"
echo "iPhone simulator:     ${PHONE:-not used} ${PHONE_NAME:+($PHONE_NAME, iOS $PHONE_OS)}"
if [ -z "$DUO" ] && [ -z "$PHONE" ]; then
  echo "No usable simulator found."
  xcrun simctl list devices available
  exit 1
fi
BUILD_FOR="${DUO:-$PHONE}"

# A simulator's first boot takes minutes, so everything slow starts at once:
# the boot, the hinge tool's own build, and the app build.
xcrun simctl boot "$BUILD_FOR" 2> /dev/null || true

# foldctl (MIT, github.com/tatsuz0u/foldctl) sets the simulator's hinge and
# orientation through the same private CoreDevice channel Xcode's Device Hub
# uses. Pinned to a reviewed commit. It compiles itself on first use.
FOLDCTL_DIR="$RAW/foldctl"
FOLDCTL_REF="be3846f6b7371945c7c3eda973ff02ce330c9032"
FOLDCTL_JOB=""
if [ -n "$DUO" ]; then
  (
    git clone --quiet https://github.com/tatsuz0u/foldctl.git "$FOLDCTL_DIR" \
      && git -C "$FOLDCTL_DIR" checkout --quiet "$FOLDCTL_REF" \
      && "$FOLDCTL_DIR/foldctl" --help
  ) > "$RAW/foldctl-build.log" 2>&1 &
  FOLDCTL_JOB=$!
fi

log "Building the Debug app for the simulator"
xcodebuild \
  -project HIIT.xcodeproj \
  -scheme HIIT \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$BUILD_FOR" \
  -derivedDataPath "$DERIVED" \
  build 2>&1 | tee "$RAW/xcodebuild.log" | (xcbeautify --quiet || cat) | grep -v -E "^[[:space:]]*$" | tail -n 40
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "The simulator build failed:"
  grep -E "(error|fatal error):" "$RAW/xcodebuild.log" | sort -u | head -n 120
  exit 1
fi
APP="$DERIVED/Build/Products/Debug-iphonesimulator/HIIT.app"
test -d "$APP" || { echo "Built app not found at $APP"; exit 1; }

# Where the running app saves its pictures, on this Mac's disk.
SNAPSHOTS=""
locate_snapshots() {
  local container
  [ -n "$SNAPSHOTS" ] && return
  container="$(xcrun simctl get_app_container "$1" "$BUNDLE" data 2> /dev/null || true)"
  [ -n "$container" ] && SNAPSHOTS="$container/Documents/demo-snapshots"
}

boot() {
  xcrun simctl boot "$1" 2> /dev/null || true
  xcrun simctl bootstatus "$1" -b > /dev/null
  xcrun simctl install "$1" "$APP"
  SNAPSHOTS=""
  locate_snapshots "$1"
}

# shoot UDID NAME [launch arguments…] — open the app on one demo screen and
# collect the picture it takes of itself.
shoot() {
  local udid="$1" name="$2" tries=0
  shift 2
  [ -n "$SNAPSHOTS" ] && rm -f "$SNAPSHOTS/$name.jpg" "$SNAPSHOTS/$name.txt"
  xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1 || true
  if ! xcrun simctl launch "$udid" "$BUNDLE" -demoSnapshot "$name" "$@" > /dev/null 2> "$RAW/launch.err"; then
    echo "  LAUNCH FAILED: $name — $(tail -n 1 "$RAW/launch.err")"
    return
  fi
  locate_snapshots "$udid"
  while [ ! -s "$SNAPSHOTS/$name.jpg" ] && [ "$tries" -lt 50 ]; do
    sleep 0.4
    tries=$((tries + 1))
  done
  if [ -s "$SNAPSHOTS/$name.jpg" ]; then
    cp "$SNAPSHOTS/$name.jpg" "$OUT/$name.jpg"
    echo "  $name — $(tr '\n' ';' < "$SNAPSHOTS/$name.txt" 2> /dev/null | sed 's/;$//; s/;/ · /g')"
  elif xcrun simctl io "$udid" screenshot "$RAW/$name.png" > /dev/null 2>&1 \
       && sips -s format jpeg -s formatOptions 72 -Z 1500 "$RAW/$name.png" --out "$OUT/$name.jpg" > /dev/null 2>&1; then
    echo "  $name — the app saved no picture (did it crash?); this is the simulator's own screenshot"
  else
    echo "  NO PICTURE: $name — the app saved none (did it crash?)"
  fi
}

# The live workout — the one fully custom layout — in its main states.
live_screens() {
  shoot "$1" "$2-live-info"    -demoScreen workout -demoState work -demoInfo 1
  shoot "$1" "$2-live-work"    -demoScreen workout -demoState work
  shoot "$1" "$2-live-warning" -demoScreen workout -demoState warning
  shoot "$1" "$2-live-coach"   -demoScreen workout -demoState suggestion
}

# The screens a session passes through before and after.
main_screens() {
  shoot "$1" "$2-home"    -demoScreen home
  shoot "$1" "$2-setup"   -demoScreen setup
  shoot "$1" "$2-summary" -demoScreen summary
}

# Everything else.
other_screens() {
  shoot "$1" "$2-live-bike"      -demoScreen workout -demoState recover -demoEquipment bike
  shoot "$1" "$2-live-endurance" -demoScreen workout -demoState endurance
  shoot "$1" "$2-live-done"      -demoScreen workout -demoState overtime
  shoot "$1" "$2-history"        -demoScreen history
  shoot "$1" "$2-detail"         -demoScreen detail
  shoot "$1" "$2-settings"       -demoScreen settings
  shoot "$1" "$2-welcome"        -demoScreen welcome
}

# The live workout drawn at other screens' sizes, in points (roughly their
# safe areas). NAME:WIDTHxHEIGHT pairs.
canvas_screens() {
  local udid="$1" pair
  shift
  for pair in "$@"; do
    shoot "$udid" "canvas-${pair%%:*}-work"  -demoScreen workout -demoState work       -demoCanvas "${pair##*:}"
    shoot "$udid" "canvas-${pair%%:*}-coach" -demoScreen workout -demoState suggestion -demoCanvas "${pair##*:}"
  done
}
IPHONE_SIZES="iphone17:402x778 iphoneSE:375x647 iphone17-sideways:750x381"

if [ -n "$DUO" ]; then
  log "iPhone Duo (iOS $DUO_OS): waiting for it to finish booting"
  boot "$DUO"

  log "iPhone Duo: checking the hinge control"
  [ -n "$FOLDCTL_JOB" ] && wait "$FOLDCTL_JOB"
  pose() { "$FOLDCTL_DIR/foldctl" "$DUO" "$@" 2>&1 | tail -n 1; sleep 2; }
  if "$FOLDCTL_DIR/foldctl" "$DUO" > "$RAW/foldctl.log" 2>&1; then
    echo "Hinge control works — the simulator booted as: $(tail -n 1 "$RAW/foldctl.log")"

    log "iPhone Duo closed, upright: every screen"
    pose --hinge closed --orientation portrait
    live_screens  "$DUO" "1-closed"
    # For the record, what `simctl io screenshot` says on this device.
    for FLAGS in "" "--display=internal" "--display=external"; do
      # shellcheck disable=SC2086
      if xcrun simctl io "$DUO" screenshot $FLAGS "$RAW/probe.png" > /dev/null 2> "$RAW/probe.err"; then
        echo "  (simctl io screenshot ${FLAGS:-with no options}: works, $(sips -g pixelWidth -g pixelHeight "$RAW/probe.png" 2> /dev/null | awk '/pixel/ {printf "%s ", $2}'))"
      else
        echo "  (simctl io screenshot ${FLAGS:-with no options}: fails — $(tr '\n' ' ' < "$RAW/probe.err" | cut -c 1-200))"
      fi
    done
    main_screens  "$DUO" "1-closed"
    other_screens "$DUO" "1-closed"

    log "iPhone Duo open, upright"
    pose --hinge open --orientation portrait
    live_screens "$DUO" "2-open"
    main_screens "$DUO" "2-open"
    shoot "$DUO" "2-open-history"  -demoScreen history
    shoot "$DUO" "2-open-detail"   -demoScreen detail
    shoot "$DUO" "2-open-settings" -demoScreen settings
    log "Ordinary iPhone sizes, drawn on the open Duo"
    # shellcheck disable=SC2086
    canvas_screens "$DUO" $IPHONE_SIZES

    log "iPhone Duo open, on its side"
    pose --hinge open --orientation landscape-left
    live_screens "$DUO" "3-open-sideways"
    shoot "$DUO" "3-open-sideways-home"    -demoScreen home
    shoot "$DUO" "3-open-sideways-summary" -demoScreen summary

    log "iPhone Duo half folded like a book"
    pose --hinge half --orientation portrait
    shoot "$DUO" "4-book-live-info"    -demoScreen workout -demoState work -demoInfo 1
    shoot "$DUO" "4-book-live-work"    -demoScreen workout -demoState work
    shoot "$DUO" "4-book-live-warning" -demoScreen workout -demoState warning

    log "iPhone Duo half folded like a laptop"
    pose --hinge half --orientation landscape-left
    shoot "$DUO" "5-laptop-live-info"    -demoScreen workout -demoState work -demoInfo 1
    shoot "$DUO" "5-laptop-live-work"    -demoScreen workout -demoState work
    shoot "$DUO" "5-laptop-live-warning" -demoScreen workout -demoState warning

    log "iPhone Duo closed, on its side"
    pose --hinge closed --orientation landscape-left
    shoot "$DUO" "6-closed-sideways-live-info" -demoScreen workout -demoState work -demoInfo 1
    shoot "$DUO" "6-closed-sideways-live-work" -demoScreen workout -demoState work
    shoot "$DUO" "6-closed-sideways-home"      -demoScreen home
    pose --hinge closed --orientation portrait
  else
    echo "Couldn't drive the hinge from the command line on this Xcode:"
    tail -n 6 "$RAW/foldctl-build.log" "$RAW/foldctl.log" 2> /dev/null
    log "iPhone Duo as booted: every screen"
    live_screens  "$DUO" "1-booted"
    main_screens  "$DUO" "1-booted"
    other_screens "$DUO" "1-booted"
    log "The live workout at the other poses' sizes, and at ordinary iPhone sizes"
    # shellcheck disable=SC2086
    canvas_screens "$DUO" duo-closed:466x620 duo-open:669x880 duo-open-sideways:951x600 \
      duo-book-half:320x880 duo-closed-sideways:620x420 $IPHONE_SIZES
  fi
  xcrun simctl shutdown "$DUO" > /dev/null 2>&1 || true
fi

if [ -n "$PHONE" ]; then
  log "$PHONE_NAME (iOS $PHONE_OS): waiting for it to finish booting"
  boot "$PHONE"
  live_screens "$PHONE" "7-iphone"
  main_screens "$PHONE" "7-iphone"
  shoot "$PHONE" "7-iphone-settings"           -demoScreen settings
  shoot "$PHONE" "7-iphone-sideways-live-info" -demoScreen workout -demoState work -demoOrientation landscape -demoInfo 1
  shoot "$PHONE" "7-iphone-sideways-live-work" -demoScreen workout -demoState work -demoOrientation landscape
  shoot "$PHONE" "7-iphone-sideways-home"      -demoScreen home -demoOrientation landscape
  xcrun simctl shutdown "$PHONE" > /dev/null 2>&1 || true
fi

# If the app crashed on a screen, say where — the first lines of the stack.
CRASH="$(ls -t "$HOME"/Library/Logs/DiagnosticReports/HIIT*.ips 2> /dev/null | head -n 1)"
if [ -n "$CRASH" ]; then
  log "The app crashed at least once — newest report: $(basename "$CRASH")"
  python3 - "$CRASH" <<'PY' || head -n 40 "$CRASH"
import json, sys
head, _, body = open(sys.argv[1], errors="replace").read().partition("\n")
report = json.loads(body)
print("exception:", json.dumps(report.get("exception", {})))
for key in ("termination", "asi"):
    if key in report:
        print(key + ":", json.dumps(report[key])[:600])
for thread in report.get("threads", []):
    if thread.get("triggered"):
        for frame in thread.get("frames", [])[:16]:
            print("   ", frame.get("symbol", "?"), frame.get("sourceFile", ""), frame.get("sourceLine", ""))
PY
fi

COUNT="$(find "$OUT" -name '*.jpg' | wc -l | tr -d ' ')"
log "Done: $COUNT pictures in $OUT"
ls "$OUT"

if [ "${PICTURES_IN_LOG:-1}" != "0" ] && [ "$COUNT" -gt 0 ]; then
  echo "::group::The pictures as text (small copies, for tools that can read this log but can't download the artifact)"
  # One block per picture: "@@PIC name bytes sha256", base64 lines that
  # start "@@ ", then "@@END name". Most important pictures last.
  python3 - "$OUT" "$RAW/small" <<'PY'
import base64, hashlib, pathlib, subprocess, sys
source, small = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
small.mkdir(parents=True, exist_ok=True)
total = 0
for picture in sorted(source.glob("*.jpg"), reverse=True):
    copy = small / picture.name
    subprocess.run(["sips", "-Z", "600", "-s", "format", "jpeg", "-s", "formatOptions", "40",
                    str(picture), "--out", str(copy)], capture_output=True)
    if not copy.exists():
        continue
    data = copy.read_bytes()
    total += len(data)
    text = base64.b64encode(data).decode()
    print(f"@@PIC {picture.stem} {len(data)} {hashlib.sha256(data).hexdigest()}")
    for start in range(0, len(text), 2000):
        print("@@ " + text[start:start + 2000])
    print(f"@@END {picture.stem}")
print(f"@@TOTAL {total} bytes")
PY
  echo "::endgroup::"
fi

if [ "$COUNT" -eq 0 ]; then
  echo "No pictures were taken."
  exit 1
fi
