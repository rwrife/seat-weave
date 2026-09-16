import json
import subprocess
import sys
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

    def test_main_writes_devices_json_after_a_timed_out_attempt(self):
        # CI regression (run 35162091105): after one timed-out attempt the
        # successful retry wrote the devices JSON without flushing, so the
        # next phase read an empty file. Run the real CLI as a subprocess
        # against a fake xcrun whose first list call stalls.
        import os
        import tempfile
        from pathlib import Path

        script = Path(__file__).resolve().parents[2] / "Scripts" / "select_simulator.py"
        payload = json.dumps(
            {
                "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                        {
                            "name": "iPhone SE",
                            "udid": "PHONE-26",
                            "isAvailable": True,
                            "state": "Shutdown",
                        }
                    ]
                }
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            fake_bin = Path(directory) / "bin"
            fake_bin.mkdir()
            counter = Path(directory) / "calls"
            fake_xcrun = fake_bin / "xcrun"
            fake_xcrun.write_text(
                "#!/usr/bin/env bash\n"
                f'count=$(cat "{counter}" 2>/dev/null || echo 0)\n'
                'count=$((count+1)); echo $count > "' + str(counter) + '"\n'
                'if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then\n'
                "  if [ \"$count\" = \"1\" ]; then sleep 5; fi\n"
                f"  printf '%s' '{payload}'\n"
                "fi\n",
                encoding="utf-8",
            )
            fake_xcrun.chmod(0o755)
            out_path = Path(directory) / "devices.json"
            env = dict(os.environ, PATH=f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
                       SEATWEAVE_SIMCTL_TIMEOUT_SECONDS="1")
            result = subprocess.run(
                [sys.executable, str(script), "--sdk", "26.0",
                 "--devices-json-out", str(out_path)],
                capture_output=True, text=True, timeout=30, env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PHONE-26", result.stdout)
            # The decisive assertion: the file must contain valid JSON.
            content = out_path.read_text()
            self.assertIn("PHONE-26", content)
            self.assertTrue(json.loads(content)["devices"])


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
