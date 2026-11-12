"""One killed process per persistence operation, never one shared store."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kill_commit_writer import run


class KillCommitWriterTests(unittest.TestCase):
    def test_runs_every_edit_in_isolated_process_pair(self):
        cases = []
        run(Path("/unused"), execute=lambda root, name, phase: cases.append((name, phase)))
        self.assertEqual(cases, [(name, phase) for name in
                                 ("assignment", "swap", "resize", "duplicate", "restore")
                                 for phase in ("pre-commit", "post-commit")])


if __name__ == "__main__":
    unittest.main()
