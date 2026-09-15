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

write_provenance() {
  local result=$?
  {
    echo "expected_sha=$expected_sha"
    echo "actual_sha=$(git rev-parse HEAD 2>/dev/null || echo unavailable)"
    echo "runner_os=${RUNNER_OS:-unknown}"
    echo "runner_arch=${RUNNER_ARCH:-unknown}"
    echo "developer_dir=${DEVELOPER_DIR:-unselected}"
    echo "simulator_udid=${simulator_udid:-unselected}"
    echo "exit_status=$result"
  } > "$artifact_dir/provenance.txt"
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    xcodebuild -version > "$artifact_dir/xcode-version.txt" 2>&1 || true
    xcrun --sdk iphoneos --show-sdk-version > "$artifact_dir/iphoneos-sdk-version.txt" 2>&1 || true
    xcrun simctl list devices available --json > "$artifact_dir/simulator-devices.json" 2>&1 || true
  fi
}
trap write_provenance EXIT

actual_sha="$(git rev-parse HEAD)"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "Checked out SHA $actual_sha does not equal requested SHA $expected_sha" >&2
  exit 1
fi

python3 -m unittest discover -s Scripts/tests -v 2>&1 | tee "$artifact_dir/helper-tests.log"

python3 Scripts/select_xcode.py \
  --toolchain toolchain.json \
  > "$artifact_dir/developer-dir.txt" \
  2> >(tee "$artifact_dir/toolchain-selection.log" >&2)
export DEVELOPER_DIR
DEVELOPER_DIR="$(<"$artifact_dir/developer-dir.txt")"

sdk_version="$(python3 -c 'import json; print(json.load(open("toolchain.json", encoding="utf-8"))["iphoneos_sdk"])')"
xcrun simctl list devices available --json > "$artifact_dir/simulator-devices.json"
simulator_udid="$(python3 Scripts/select_simulator.py --sdk "$sdk_version")"
echo "platform=iOS Simulator,id=$simulator_udid" > "$artifact_dir/destination.txt"

xcrun simctl boot "$simulator_udid" 2>&1 | tee "$artifact_dir/simulator-boot.log" || true
xcrun simctl bootstatus "$simulator_udid" -b 2>&1 | tee -a "$artifact_dir/simulator-boot.log"

xcrun swift test \
  --package-path Packages/SeatingDomain \
  2>&1 | tee "$artifact_dir/domain-tests.log"

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

xcodebuild test \
  -project SeatWeave.xcodeproj \
  -scheme SeatWeave \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$artifact_dir/tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$artifact_dir/xcodebuild-test.log"
