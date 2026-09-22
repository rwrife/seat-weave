#!/usr/bin/env python3
"""Choose an explicit available iPhone simulator UDID for the pinned SDK."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys


class DestinationError(ValueError):
    pass


def select_destination(payload: dict, sdk_version: str) -> str:
    runtime = f"com.apple.CoreSimulator.SimRuntime.iOS-{sdk_version.replace('.', '-')}"
    candidates = [
        device
        for device in payload.get("devices", {}).get(runtime, [])
        if device.get("isAvailable") is True
        and str(device.get("name", "")).startswith("iPhone")
        and device.get("udid")
    ]
    if not candidates:
        raise DestinationError(f"No available iPhone simulator found for iOS {sdk_version}")
    candidates.sort(key=lambda device: (device["name"], device["udid"]), reverse=True)
    return str(candidates[0]["udid"])


def _ios_runtimes(payload: dict) -> list[str]:
    """iOS runtime keys sorted newest-first (numeric dot-part comparison)."""
    return sorted(
        (
            key
            for key in payload.get("devices", {})
            if key.startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
        ),
        key=lambda key: [int(part) if part.isdigit() else 0
                         for part in key.rsplit("iOS-", 1)[1].split("-")],
        reverse=True,
    )


def select_regular_destination(payload: dict, sdk_version: str) -> str:
    """Choose a regular-width (iPad-family) simulator UDID.

    Issue #4 needs a second destination whose environment reports a
    regular horizontal size class so `SeatingWorkspaceLayout`'s auto path
    is exercised natively. Prefers the exact pinned runtime, then any
    newer iOS runtime, then older ones; ties break deterministically on
    (name, udid) descending, matching select_destination.
    """
    exact = f"com.apple.CoreSimulator.SimRuntime.iOS-{sdk_version.replace('.', '-')}"
    runtimes = _ios_runtimes(payload)
    ordered = ([exact] if exact in runtimes else []) + [
        key for key in runtimes if key != exact
    ]
    for runtime in ordered:
        candidates = [
            device
            for device in payload.get("devices", {}).get(runtime, [])
            if device.get("isAvailable") is True
            and str(device.get("name", "")).startswith("iPad")
            and device.get("udid")
        ]
        if candidates:
            candidates.sort(key=lambda device: (device["name"], device["udid"]), reverse=True)
            return str(candidates[0]["udid"])
    raise DestinationError(f"No available iPad simulator found for iOS {sdk_version}")


def enumerate_available_devices(
    *,
    runner=subprocess.run,
    timeout: int | None = None,
    attempts: int = 2,
) -> str:
    """Enumerate available simulators with bounded retries.

    Hosted runners occasionally stall the first `simctl list` call; one
    bounded retry absorbs that without raising any timeout budget. The
    timeout may be overridden via SEATWEAVE_SIMCTL_TIMEOUT_SECONDS
    (integer seconds) for tests and constrained environments.
    """
    if timeout is None:
        try:
            timeout = int(os.environ.get("SEATWEAVE_SIMCTL_TIMEOUT_SECONDS", "30"))
        except ValueError:
            timeout = 30
        if timeout <= 0:
            timeout = 30
    command = ["xcrun", "simctl", "list", "devices", "available", "--json"]
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return runner(
                command,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
                timeout=timeout,
            ).stdout
        except subprocess.TimeoutExpired as error:
            last_error = error
            if attempt < attempts:
                print(
                    "Simulator enumeration timed out after "
                    f"{timeout}s; retrying once.",
                    file=sys.stderr,
                )
    assert last_error is not None
    raise last_error


def main(argv: list[str] | None = None, enumerator=enumerate_available_devices) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", required=True)
    parser.add_argument("--family", choices=("iphone", "ipad"), default="iphone")
    parser.add_argument("--devices-json-out", type=argparse.FileType("w", encoding="utf-8"))
    args = parser.parse_args(argv)
    try:
        output = enumerator()
        if args.devices_json_out:
            args.devices_json_out.write(output)
            # Flush now: a caught enumeration TimeoutExpired can keep this
            # handle's buffer alive until exit, leaving an empty file behind.
            args.devices_json_out.flush()
        selector = select_destination if args.family == "iphone" else select_regular_destination
        udid = selector(json.loads(output), args.sdk)
    except (
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        json.JSONDecodeError,
        DestinationError,
    ) as error:
        print(error, file=sys.stderr)
        return 1
    print(udid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
