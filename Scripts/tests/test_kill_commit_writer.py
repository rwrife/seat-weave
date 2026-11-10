"""One killed process per persistence operation, never one shared store."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kill_commit_writer import run


class KillCommitWriterTests(unittest.TestCase):
    def test_runs_every_edit_in_isolated_process_pair(self):
        cases = []
        run(Path("/unused"), execute=lambda root, name: cases.append(name))
        self.assertEqual(cases, ["assignment", "swap", "resize", "duplicate", "restore"])


if __name__ == "__main__":
    unittest.main()
