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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", required=True)
    args = parser.parse_args()
    try:
        output = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "--json"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout
        udid = select_destination(json.loads(output), args.sdk)
    except (subprocess.CalledProcessError, json.JSONDecodeError, DestinationError) as error:
        print(error, file=sys.stderr)
        return 1
    print(udid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
