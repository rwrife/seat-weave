import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from Scripts.boot_simulator import SimulatorBootError, boot_selected_simulator, run_logged


def devices(state="Shutdown"):
    return {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {
                    "name": "iPhone 17 Pro",
                    "udid": "PHONE-26",
                    "isAvailable": True,
                    "state": state,
                }
            ]
        }
    }


class FakeRunner:
    def __init__(self, results):
        self.results = iter(results)
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append((command, kwargs))
        result = next(self.results)
        if isinstance(result, BaseException):
            raise result
        return result


class BootTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.log_path = Path(directory.name) / "simulator-boot.log"

    def completed(self, returncode=0, output="ok\n"):
        return subprocess.CompletedProcess([], returncode, output)

    def test_already_booted_skips_boot_and_waits_for_readiness(self):
        runner = FakeRunner([self.completed()])

        boot_selected_simulator(
            "PHONE-26", devices("Booted"), self.log_path, runner=runner
        )

        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(runner.calls[0][0][2:4], ["bootstatus", "PHONE-26"])
        self.assertIn("already Booted", self.log_path.read_text())

    def test_boot_timeout_fails_clearly_and_preserves_output(self):
        timeout = subprocess.TimeoutExpired(
            ["xcrun", "simctl", "boot", "PHONE-26"], 120, output="partial boot\n"
        )
        # First boot times out; the bounded recovery retries once (shutdown,
        # second boot) and still fails, preserving the timeout diagnostics.
        runner = FakeRunner(
            [timeout, self.completed(), timeout]
        )

        with self.assertRaisesRegex(SimulatorBootError, "timed out after 120"):
            boot_selected_simulator(
                "PHONE-26", devices(), self.log_path, runner=runner
            )

        log = self.log_path.read_text()
        self.assertIn("partial boot", log)
        self.assertIn("retrying once", log)
        self.assertEqual(len(runner.calls), 3)
        self.assertEqual(runner.calls[1][0][2], "shutdown")
        self.assertEqual(runner.calls[2][0][2], "boot")

    def test_bootstatus_timeout_shuts_down_and_retries_once(self):
        bootstatus_timeout = subprocess.TimeoutExpired(
            ["xcrun", "simctl", "bootstatus", "PHONE-26", "-b"],
            180,
            output="waiting\n",
        )
        runner = FakeRunner(
            [
                self.completed(output="boot requested\n"),
                bootstatus_timeout,
                self.completed(output="shutdown ok\n"),
                self.completed(output="boot requested\n"),
                self.completed(output="ready\n"),
            ]
        )

        boot_selected_simulator("PHONE-26", devices(), self.log_path, runner=runner)

        log = self.log_path.read_text()
        self.assertIn("retrying once", log)
        calls = [call[0][2] for call in runner.calls]
        self.assertEqual(calls, ["boot", "bootstatus", "shutdown", "boot", "bootstatus"])

    def test_second_startup_timeout_is_not_retried(self):
        boot_timeout = subprocess.TimeoutExpired(
            ["xcrun", "simctl", "boot", "PHONE-26"], 120, output="first\n"
        )
        second_timeout = subprocess.TimeoutExpired(
            ["xcrun", "simctl", "boot", "PHONE-26"], 120, output="second\n"
        )
        runner = FakeRunner([boot_timeout, self.completed(), second_timeout])

        with self.assertRaisesRegex(SimulatorBootError, "timed out after 120"):
            boot_selected_simulator(
                "PHONE-26", devices(), self.log_path, runner=runner
            )

        # Exactly one retry: boot, (failed) then shutdown + boot, (failed) -> stop.
        self.assertEqual(len(runner.calls), 3)

    def test_shutdown_failure_is_tolerated_during_recovery(self):
        boot_timeout = subprocess.TimeoutExpired(
            ["xcrun", "simctl", "boot", "PHONE-26"], 120, output="first\n"
        )
        runner = FakeRunner(
            [
                boot_timeout,
                self.completed(returncode=5, output="shutdown failed\n"),
                self.completed(output="boot requested\n"),
                self.completed(output="ready\n"),
            ]
        )

        boot_selected_simulator("PHONE-26", devices(), self.log_path, runner=runner)

        log = self.log_path.read_text()
        self.assertIn("shutdown failed", log)
        self.assertIn("tolerated", log)

    def test_boot_nonzero_exit_is_not_ignored(self):
        runner = FakeRunner([self.completed(returncode=9, output="boot failed\n")])

        with self.assertRaisesRegex(SimulatorBootError, "exited 9"):
            boot_selected_simulator(
                "PHONE-26", devices(), self.log_path, runner=runner
            )

        self.assertIn("boot failed", self.log_path.read_text())

    def test_bootstatus_nonzero_exit_is_not_ignored(self):
        runner = FakeRunner(
            [self.completed(output="boot requested\n"), self.completed(7, "not ready\n")]
        )

        with self.assertRaisesRegex(SimulatorBootError, "bootstatus.*exited 7"):
            boot_selected_simulator(
                "PHONE-26", devices(), self.log_path, runner=runner
            )

        self.assertIn("not ready", self.log_path.read_text())


class RealSubprocessTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.log_path = Path(directory.name) / "command.log"

    def test_real_subprocess_is_terminated_at_timeout(self):
        command = [
            sys.executable,
            "-c",
            "import time; print('started', flush=True); time.sleep(10)",
        ]

        with self.assertRaisesRegex(SimulatorBootError, "timed out"):
            run_logged(command, 0.05, self.log_path)

        log = self.log_path.read_text()
        self.assertIn("started", log)
        self.assertIn("timed out", log)

    def test_real_subprocess_nonzero_exit_is_reported(self):
        command = [sys.executable, "-c", "print('failed'); raise SystemExit(6)"]

        with self.assertRaisesRegex(SimulatorBootError, "exited 6"):
            run_logged(command, 5, self.log_path)

        self.assertIn("failed", self.log_path.read_text())


if __name__ == "__main__":
    unittest.main()
