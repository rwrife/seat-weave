# Native bootstrap evidence — 2026-09-15

This is issue #1 foundation evidence, not a completed seating planner or release.

## Successful native execution

- [GitHub Actions run 35007070382, attempt 2](https://github.com/rwrife/seat-weave/actions/runs/35007070382/attempts/2), job `104510423886`.
- Exact checked-out/tested SHA: `a319c05dcb0b78f54964b8a417905caa82e135f5` (PR head, not synthetic merge).
- Hosted macOS ARM64. Measured `xcodebuild -version`: **Xcode 26.0.1, Build version 17A400**.
- Measured `xcrun --sdk iphoneos --show-sdk-version`: **26.0**. Compiler invocations include `-swift-version 6`.
- Destination: `platform=iOS Simulator,id=F3967A6C-63E1-4323-9EA7-6C26D42F77A3`.
- Xcode identified **iPhone SE (3rd generation), simulator OS 26.0.1**; CoreSimulator runtime key is `iOS-26-0`. Simulator OS patch and SDK version are distinct.
- **15 Python helper tests passed.**
- **4 Swift Testing domain contract tests passed.** The separate XCTest discovery line reports zero tests; it is not the Swift Testing result.
- Unsigned simulator application build: **BUILD SUCCEEDED**.
- `SeatWeaveLaunchTests.testBootstrapHomeLaunches`: **1 test, 0 failures**, 18.849 seconds; **TEST SUCCEEDED**.
- Provenance records `expected_sha == actual_sha`, `phase=complete`, `exit_status=0`.

Downloaded and inspected the successful artifact `ios-ci-a319c05dcb0b78f54964b8a417905caa82e135f5`, artifact ID **10412552151** (112055 bytes). It contains `build.xcresult`, `tests.xcresult`, native/domain/helper logs, measured toolchain, device list, explicit destination and SHA provenance. Artifacts are retained for 14 days. Attempt 1 has a same-named failure artifact; identify successful evidence by ID, run attempt and provenance, not name alone.

## Reproduction

On an exact-pinned Mac with the corresponding available iPhone simulator:

```sh
Scripts/ci.sh "$(git rev-parse HEAD)"
```

It uses a fresh DerivedData/run directory and runs helper tests, actual toolchain selection, bounded simulator boot/readiness, package tests, unsigned `xcodebuild build`, and `xcodebuild test` with the shared `SeatWeave` scheme. PR CI explicitly checks out the head SHA and always uploads results. Future commits require their own green CI; this dated record does not claim results for untested revisions.

## Failure history and repairs

1. Run `35000901774` measured the correct toolchain and passed four domain tests, but the app attempted an x86_64 simulator slice while the package had built arm64 only. The failing native build returned 65. Project Debug now uses `ONLY_ACTIVE_ARCH=YES`; Release was not narrowed.
2. Run `35001629386` hung during `simctl boot` and reached the 45-minute job limit; no app/domain test execution from that run is claimed. Simulator commands and exit diagnostics now have timeouts and phase-aware provenance. Validation has a shorter step timeout than the job to allow artifact upload.
3. Run `35007070382` attempt 1 hit a 30-second simulator enumeration timeout. Retrying the unchanged SHA on a fresh runner produced the successful attempt 2 above. No checks were bypassed or toolchain pins lowered.
4. Run `35008561159` (docs-only head `fad1bf9`) failed three times on transient hosted-runner CoreSimulator stalls: attempt 1 `bootstatus` timed out at 180s, attempt 2 hit a 30-second simulator enumeration timeout, attempt 3 (2026-09-16) again timed out in `bootstatus` after boot. All attempts measured the exact toolchain and passed the helper tests before stalling. Repair: a timed-out `boot`/`bootstatus` on a shut-down simulator now performs one bounded `simctl shutdown` and retry (startup gets at most two bounded attempts); nonzero exits still fail immediately and every timeout budget is unchanged. Hosted runner stalls are not a code defect, but the retry removes the single-flaky-device failure mode without weakening bounds. Helper coverage grew to 18 tests, all passing locally on Linux.

## Unresolved later acceptance

- Event persistence, commands, usable seating flows, adaptive/accessibility journeys, private backups and public export belong to issues #2–#6.
- No physical-iPhone offline/network observation, VoiceOver/Switch Control manual result, or physical Duo evidence exists. No unavailable fold API is used.
- No signing, certificate/profile, App Store app record verification, processed TestFlight build or store submission occurred. Issue #7 remains gated; configured secret names and registered bundle ID do not prove distribution.
- App inspection finds no external packages, networking, analytics or CloudKit integration; that is static review, not observed on-device traffic evidence.
