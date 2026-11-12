#!/usr/bin/env python3
"""Make a real previous-build SwiftData SQLite store using pinned historical sources.

Run only on macOS with pinned Xcode selected. Fixture contains synthetic names;
SQLite bytes stay in local CI artifact directory and are never uploaded.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

OLD_COMMIT = "027dec31f234caa10a2d86eeff9b53fcc4c5a970"
EVENT_ID = "10941234-5678-4000-8000-000000000021"


def run(repo: Path, directory: Path) -> None:
    from_dir = Path(__file__).resolve().parent
    package = "Packages/SeatingDomain/"
    files = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", OLD_COMMIT, package + "Sources/"],
        cwd=repo, text=True,
    ).splitlines()
    if not files:
        raise RuntimeError("historical package sources missing")
    with tempfile.TemporaryDirectory(prefix="seatweave-prior-build-") as temporary:
        root = Path(temporary)
        for file in [package + "Package.swift", *files]:
            destination = root / file.removeprefix(package)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("wb") as output:
                subprocess.run(["git", "show", f"{OLD_COMMIT}:{file}"],
                               cwd=repo, stdout=output, check=True)
        target = root / "Tests/SeatingDomainTests/LegacyStoreFixtureTests.swift"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((from_dir / "LegacyStoreFixtureTests.swift").read_bytes())
        directory.mkdir(parents=True, exist_ok=True)
        env = {**os.environ, "SEATWEAVE_LEGACY_STORE_DIR": str(directory)}
        subprocess.run(["xcrun", "swift", "test", "--package-path", str(root),
                        "--filter", "LegacyStoreFixtureTests"],
                       cwd=repo, env=env, check=True, timeout=300)
        if not (directory / "seatweave.sqlite").is_file():
            raise RuntimeError("historical SwiftData store not written")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    run(Path(__file__).resolve().parent.parent, args.directory.resolve())
