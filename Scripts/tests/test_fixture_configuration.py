"""Keep synthetic fixture code in Debug and out of Release builds."""
from pathlib import Path
import re
import unittest


class FixtureConfigurationTests(unittest.TestCase):
    def test_pdf_fixtures_run_before_ui_and_install_built_app(self):
        script = (Path(__file__).resolve().parents[1] / "ci.sh").read_text()
        fixtures = script.index('phase="pdf_fixtures"')
        compact = script.index('phase="ui_tests"')
        self.assertLess(script.index('phase="app_build"'), fixtures)
        self.assertLess(fixtures, compact)
        self.assertIn('simctl install "$simulator_udid" "$derived_data/Build/Products/Debug-iphonesimulator/SeatWeave.app"',
                      script[fixtures:compact])
        self.assertIn('Scripts/check_pdf.swift', script[fixtures:compact])

    def test_debug_only_fixture_compilation(self):
        project = (Path(__file__).resolve().parents[2] /
                   "SeatWeave.xcodeproj/project.pbxproj").read_text()
        blocks = re.findall(
            r"A1000000000000000000090[12] /\* (Debug|Release) \*/ = \{(.*?)\n\t\t\};",
            project, re.S)
        self.assertEqual(len(blocks), 2)
        conditions = {}
        for name, block in blocks:
            match = re.search(r'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "([^"]*)";', block)
            conditions[name] = match[1].split() if match else []
        self.assertIn("DEBUG", conditions["Debug"])
        self.assertNotIn("DEBUG", conditions["Release"])


if __name__ == "__main__":
    unittest.main()
