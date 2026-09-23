#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_sha="${1:-}"
if [[ -z "$expected_sha" ]]; then
  echo "usage: Scripts/ci.sh <expected-commit-sha>" >&2
  exit 2
fi

artifact_root="${SEATWEAVE_ARTIFACT_DIR:-$repo_root/build/ci-artifacts}"
mkdir -p "$artifact_root" "$repo_root/build"
artifact_dir="$(mktemp -d "$artifact_root/run.XXXXXX")"
derived_data="$(mktemp -d "$repo_root/build/DerivedData.XXXXXX")"
phase="initialization"

write_provenance() {
  local result=$?
  {
    echo "expected_sha=$expected_sha"
    echo "actual_sha=$(git rev-parse HEAD 2>/dev/null || echo unavailable)"
    echo "runner_os=${RUNNER_OS:-unknown}"
    echo "runner_arch=${RUNNER_ARCH:-unknown}"
    echo "developer_dir=${DEVELOPER_DIR:-unselected}"
    echo "simulator_udid=${simulator_udid:-unselected}"
    echo "phase=$phase"
    echo "exit_status=$result"
  } > "$artifact_dir/provenance.txt"
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    python3 Scripts/boot_simulator.py capture \
      --timeout 15 --output "$artifact_dir/xcode-version.txt" \
      -- xcodebuild -version || true
    python3 Scripts/boot_simulator.py capture \
      --timeout 15 --output "$artifact_dir/iphoneos-sdk-version.txt" \
      -- xcrun --sdk iphoneos --show-sdk-version || true
    python3 Scripts/boot_simulator.py capture \
      --timeout 20 --output "$artifact_dir/simulator-devices-exit.log" \
      -- xcrun simctl list devices available --json || true
  fi
}
trap write_provenance EXIT

actual_sha="$(git rev-parse HEAD)"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "Checked out SHA $actual_sha does not equal requested SHA $expected_sha" >&2
  exit 1
fi

phase="helper_tests"
python3 -m unittest discover -s Scripts/tests -v 2>&1 | tee "$artifact_dir/helper-tests.log"

phase="offline_privacy_audit"
# Issue #6: static, source-level offline-privacy audit (no network /
# analytics / CloudKit references, no custom entitlements). This is a
# static review, not observed network-capture evidence.
python3 Scripts/entitlement_audit.py \
  --repo-root "$repo_root" --source-only \
  --report "$artifact_dir/offline-privacy-audit-source.json"

phase="toolchain_selection"
python3 Scripts/select_xcode.py \
  --toolchain toolchain.json \
  > "$artifact_dir/developer-dir.txt" \
  2> >(tee "$artifact_dir/toolchain-selection.log" >&2)
export DEVELOPER_DIR
DEVELOPER_DIR="$(<"$artifact_dir/developer-dir.txt")"

phase="simulator_selection"
sdk_version="$(python3 -c 'import json; print(json.load(open("toolchain.json", encoding="utf-8"))["iphoneos_sdk"])')"
simulator_udid="$(python3 Scripts/select_simulator.py \
  --sdk "$sdk_version" \
  --devices-json-out "$artifact_dir/simulator-devices.json")"
echo "platform=iOS Simulator,id=$simulator_udid" > "$artifact_dir/destination.txt"
# Issue #4: a regular-width (iPad-family) destination proves the auto
# path of SeatingWorkspaceLayout. Fall back to phone-only when no iPad
# simulator is available and record that honestly.
regular_udid="$(python3 Scripts/select_simulator.py --sdk "$sdk_version" --family ipad)" || regular_udid=""

phase="simulator_boot"
python3 Scripts/boot_simulator.py boot \
  --udid "$simulator_udid" \
  --devices-json "$artifact_dir/simulator-devices.json" \
  --log "$artifact_dir/simulator-boot.log" \
  --boot-timeout 120 \
  --bootstatus-timeout 180 \
  2> >(tee -a "$artifact_dir/simulator-boot.log" >&2)

phase="domain_tests"
xcrun swift test \
  --package-path Packages/SeatingDomain \
  2>&1 | tee "$artifact_dir/domain-tests.log"

phase="app_build"
xcodebuild build \
  -project SeatWeave.xcodeproj \
  -scheme SeatWeave \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$artifact_dir/build.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$artifact_dir/xcodebuild-build.log"

# Compact-phone journeys (issue #3/#5/#6) and the override-driven region
# transitions (issue #4) run on the pinned iPhone destination. The
# large-text journey drives the same core flow at the
# extra-extra-large Dynamic Type size (script-set via `simctl ui`).
phase="ui_tests"
xcodebuild test \
  -project SeatWeave.xcodeproj \
  -scheme SeatWeave \
  -only-testing:SeatWeaveUITests/SeatWeaveLaunchTests \
  -only-testing:SeatWeaveUITests/SeatWeaveSeatingJourneyTests \
  -only-testing:SeatWeaveUITests/SeatWeaveShareJourneyTests \
  -only-testing:SeatWeaveUITests/SeatWeaveWorkspaceTransitionTests \
  -only-testing:SeatWeaveUITests/SeatWeaveLargeTextJourneyTests \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$artifact_dir/tests-compact.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$artifact_dir/xcodebuild-test-compact.log"

# Regular-width evidence (issue #4): the auto region path on an actual
# regular-size-class destination. No iPad simulator => explicit, honest
# gap in provenance; the phone results above still gate the merge.
if [[ -n "$regular_udid" ]]; then
  echo "platform=iOS Simulator,id=$regular_udid" > "$artifact_dir/destination-regular.txt"
  python3 Scripts/boot_simulator.py boot \
    --udid "$regular_udid" \
    --devices-json "$artifact_dir/simulator-devices.json" \
    --log "$artifact_dir/simulator-boot-regular.log" \
    --boot-timeout 120 \
    --bootstatus-timeout 180 \
    2> >(tee -a "$artifact_dir/simulator-boot-regular.log" >&2)
  phase="ui_tests_regular"
  xcodebuild test \
    -project SeatWeave.xcodeproj \
    -scheme SeatWeave \
    -only-testing:SeatWeaveUITests/SeatWeaveRegularWidthTests \
    -destination "platform=iOS Simulator,id=$regular_udid" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$artifact_dir/tests-regular.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    2>&1 | tee "$artifact_dir/xcodebuild-test-regular.log"
else
  echo "no-available-ipad-simulator" > "$artifact_dir/destination-regular.txt"
fi

phase="complete"
