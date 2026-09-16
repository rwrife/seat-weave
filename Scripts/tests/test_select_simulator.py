import subprocess
import unittest

from Scripts.select_simulator import (
    DestinationError,
    enumerate_available_devices,
    select_destination,
)


class EnumerationTests(unittest.TestCase):
    class FakeRunner:
        def __init__(self, results):
            self.results = iter(results)
            self.calls = []

        def __call__(self, command, **kwargs):
            self.calls.append(command)
            result = next(self.results)
            if isinstance(result, BaseException):
                raise result
            return result

    def test_times_out_then_succeeds_on_retry(self):
        timeout = subprocess.TimeoutExpired(["xcrun", "simctl", "list"], 30)
        completed = subprocess.CompletedProcess([], 0, '{"devices": {}}')
        runner = self.FakeRunner([timeout, completed])

        output = enumerate_available_devices(runner=runner, timeout=30)

        self.assertEqual(output, '{"devices": {}}')
        self.assertEqual(len(runner.calls), 2)

    def test_repeated_timeouts_are_not_swallowed(self):
        timeout = subprocess.TimeoutExpired(["xcrun", "simctl", "list"], 30)
        runner = self.FakeRunner([timeout, timeout])

        with self.assertRaises(subprocess.TimeoutExpired):
            enumerate_available_devices(runner=runner, timeout=30)

        self.assertEqual(len(runner.calls), 2)


class DestinationTests(unittest.TestCase):
    def test_selects_available_iphone_on_exact_runtime(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {
                        "name": "iPhone 17 Pro",
                        "udid": "PHONE-26",
                        "isAvailable": True,
                    },
                    {
                        "name": "iPad Pro",
                        "udid": "PAD-26",
                        "isAvailable": True,
                    },
                ]
            }
        }
        self.assertEqual(select_destination(devices, "26.0"), "PHONE-26")

    def test_rejects_unavailable_iphone(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {"name": "iPhone 17", "udid": "NOPE", "isAvailable": False}
                ]
            }
        }
        with self.assertRaisesRegex(DestinationError, "available iPhone"):
            select_destination(devices, "26.0")

    def test_rejects_unsupported_sdk_runtime(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-25-5": [
                    {"name": "iPhone 16", "udid": "OLD", "isAvailable": True}
                ]
            }
        }
        with self.assertRaisesRegex(DestinationError, "iOS 26.0"):
            select_destination(devices, "26.0")


if __name__ == "__main__":
    unittest.main()
