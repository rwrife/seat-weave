#!/usr/bin/env python3
"""Choose an explicit available iPhone simulator UDID for the pinned SDK."""

from __future__ import annotations

import argparse
import json
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


def enumerate_available_devices(
    *,
    runner=subprocess.run,
    timeout: int = 30,
    attempts: int = 2,
) -> str:
    """Enumerate available simulators with bounded retries.

    Hosted runners occasionally stall the first `simctl list` call; one
    bounded retry absorbs that without raising any timeout budget.
    """
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", required=True)
    parser.add_argument("--devices-json-out", type=argparse.FileType("w", encoding="utf-8"))
    args = parser.parse_args()
    try:
        output = enumerate_available_devices()
        if args.devices_json_out:
            args.devices_json_out.write(output)
        udid = select_destination(json.loads(output), args.sdk)
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
