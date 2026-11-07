#!/usr/bin/env python3
"""Kill real SwiftData writer at pre-commit barrier, then reopen SQLite.

Synthetic private store remains outside uploaded CI artifacts. This tests a
process death BEFORE context.save(), not power loss DURING SQLite fsync.
"""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def run(root: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="seatweave-kill-") as temporary:
        directory = Path(temporary)
        env = {**os.environ, "SEATWEAVE_KILL_DIR": str(directory)}
        command = ["xcrun", "swift", "test", "--package-path",
                   str(root / "Packages/SeatingDomain"), "--filter", "CommitKillTests"]
        writer = subprocess.Popen(command, cwd=root,
                                  env={**env, "SEATWEAVE_KILL_PHASE": "writer"},
                                  stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                                  start_new_session=True)
        try:
            deadline = time.monotonic() + 300
            while not (directory / "at-commit").exists():
                if writer.poll() is not None:
                    raise RuntimeError(f"Writer exited before commit barrier (status {writer.returncode})")
                if time.monotonic() >= deadline:
                    raise TimeoutError("Writer never reached pre-commit barrier")
                time.sleep(0.1)
            os.killpg(writer.pid, signal.SIGKILL)
            writer.wait(timeout=15)
            if writer.returncode != -signal.SIGKILL:
                raise RuntimeError(f"Writer not killed: {writer.returncode}")
            print("Writer killed at pre-commit barrier; checking persisted snapshot", flush=True)
        finally:
            if writer.poll() is None:
                os.killpg(writer.pid, signal.SIGKILL)
                writer.wait(timeout=15)
        subprocess.run(command, cwd=root,
                       env={**env, "SEATWEAVE_KILL_PHASE": "reader"},
                       check=True, timeout=300)
        print("Reader reopened SQLite and saved again; test passed", flush=True)


if __name__ == "__main__":
    run(Path(__file__).resolve().parent.parent)
