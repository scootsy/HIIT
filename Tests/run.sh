#!/bin/bash
# Compiles the app's pure-logic sources together with the checks in this
# folder and runs them. Used by CI and runnable anywhere `swiftc` exists:
#
#   ./Tests/run.sh
#
# Only Foundation-only sources belong in the list below — anything importing
# SwiftUI, UIKit, SwiftData or HealthKit can't build outside Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

out_dir="${TMPDIR:-/tmp}"
out="${out_dir%/}/hiit-logic-tests"

swiftc -o "$out" \
  HIIT/Models/Equipment.swift \
  HIIT/Models/WorkoutModels.swift \
  HIIT/Engine/ProgressionEngine.swift \
  HIIT/Engine/SpeedCalibration.swift \
  HIIT/Engine/WorkoutGenerator.swift \
  HIIT/Engine/EnduranceGenerator.swift \
  HIIT/Engine/MetabolicMath.swift \
  HIIT/Coach/CoachModels.swift \
  HIIT/Support/FlexMath.swift \
  HIIT/Support/SigningProfile.swift \
  Tests/*.swift

"$out"
