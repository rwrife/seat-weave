#!/usr/bin/env python3
"""Kill real SwiftData writer at pre-commit barrier, then reopen SQLite.

Synthetic private store remains outside uploaded CI artifacts. This tests a
process death BEFORE context.save(), not power loss DURING SQLite fsync.
"""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


OPERATIONS = ("assignment", "swap", "resize", "duplicate", "restore")
PHASES = ("pre-commit", "post-commit")


def verify_operation(root: Path, operation: str, boundary: str = "pre-commit") -> None:
    writer_phase = "committed-writer" if boundary == "post-commit" else "writer"
    reader_phase = "committed-reader" if boundary == "post-commit" else "reader"
    marker_name = "after-commit" if boundary == "post-commit" else "at-commit"

    with tempfile.TemporaryDirectory(prefix=f"seatweave-kill-{boundary}-") as temporary:
        directory = Path(temporary)
        env = {**os.environ, "SEATWEAVE_KILL_DIR": str(directory),
               "SEATWEAVE_KILL_OPERATION": operation}
        command = ["xcrun", "swift", "test", "--package-path",
                   str(root / "Packages/SeatingDomain"), "--filter", "CommitKillTests"]
        writer = subprocess.Popen(command, cwd=root,
                                  env={**env, "SEATWEAVE_KILL_PHASE": writer_phase},
                                  stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                                  start_new_session=True)
        try:
            deadline = time.monotonic() + 300
            while not (directory / marker_name).exists():
                if writer.poll() is not None:
                    raise RuntimeError(f"Writer exited before {boundary} barrier (status {writer.returncode})")
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"Writer never reached {boundary} barrier")
                time.sleep(0.1)
            os.killpg(writer.pid, signal.SIGKILL)
            writer.wait(timeout=15)
            if writer.returncode != -signal.SIGKILL:
                raise RuntimeError(f"Writer not killed: {writer.returncode}")
            print(f"{operation} ({boundary}): writer killed at barrier; checking persisted snapshot", flush=True)
        finally:
            if writer.poll() is None:
                os.killpg(writer.pid, signal.SIGKILL)
                writer.wait(timeout=15)
        subprocess.run(command, cwd=root,
                       env={**env, "SEATWEAVE_KILL_PHASE": reader_phase},
                       check=True, timeout=300)
        print(f"{operation} ({boundary}): reader reopened SQLite and saved again; test passed", flush=True)


def run(root: Path, execute=verify_operation) -> None:
    for operation in OPERATIONS:
        execute(root, operation, "pre-commit")
        execute(root, operation, "post-commit")


if __name__ == "__main__":
    run(Path(__file__).resolve().parent.parent)
