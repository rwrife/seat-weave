"""Unit tests for the static offline-privacy audit (issue #6).

Runs on Linux and macOS: exercises the source-only subset, which is the
portion CI can gate. Bundle (Mach-O) auditing needs macOS and is covered
by Scripts/ci.sh when a built app is available.
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "entitlement_audit.py"
spec = importlib.util.spec_from_file_location("entitlement_audit", MODULE_PATH)
assert spec is not None and spec.loader is not None
entitlement_audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entitlement_audit)


def make_fake_repo(root: Path, *, app_source: str = "import SwiftUI\nstruct V {}\n",
                   project_text: str = "build settings\n") -> Path:
    (root / "App").mkdir(parents=True)
    (root / "Packages" / "SeatingDomain" / "Sources" / "SeatingDomain").mkdir(parents=True)
    (root / "SeatWeave.xcodeproj").mkdir()
    (root / "App" / "V.swift").write_text(app_source, encoding="utf-8")
    (root / "SeatWeave.xcodeproj" / "project.pbxproj").write_text(project_text, encoding="utf-8")
    (root / "Packages" / "SeatingDomain" / "Sources" / "SeatingDomain" / "M.swift").write_text(
        "import Foundation\n", encoding="utf-8")
    return root


class SourceAuditTests(unittest.TestCase):
    def test_clean_repo_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = make_fake_repo(Path(tmp))
            self.assertEqual(entitlement_audit.audit_source_only(root), [])

    def test_forbidden_import_flagged(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = make_fake_repo(Path(tmp), app_source="import SwiftUI\nimport Network\n")
            violations = entitlement_audit.audit_source_only(root)
            self.assertEqual(len(violations), 1)
            self.assertIn("Network", violations[0])

    def test_urlsession_reference_flagged(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = make_fake_repo(Path(tmp), app_source="import Foundation\nlet s = URLSession.shared\n")
            violations = entitlement_audit.audit_source_only(root)
            self.assertEqual(len(violations), 1)
            self.assertIn("URLSession", violations[0])

    def test_entitlements_setting_flagged(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = make_fake_repo(Path(tmp),
                                  project_text="CODE_SIGN_ENTITLEMENTS = App/seatweave.entitlements;\n")
            violations = entitlement_audit.audit_source_only(root)
            self.assertEqual(len(violations), 1)
            self.assertIn("CODE_SIGN_ENTITLEMENTS", violations[0])

    def test_missing_project_flagged(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "App").mkdir()
            violations = entitlement_audit.audit_source_only(root)
            self.assertTrue(any("project file missing" in v for v in violations))

    def test_main_reports_machine_readable_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = make_fake_repo(Path(tmp))
            report_path = Path(tmp) / "report.json"
            code = entitlement_audit.main([
                "entitlement_audit.py", "--repo-root", str(root),
                "--source-only", "--report", str(report_path)])
            self.assertEqual(code, 0)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["mode"], "source-only")
            self.assertEqual(report["violations"], [])
            self.assertIn("not observed network-capture", report["note"])


if __name__ == "__main__":
    unittest.main()
