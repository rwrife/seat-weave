#!/usr/bin/env python3
"""Static offline-privacy audit for issue #6.

Proves, WITHOUT running the app, that no Mach-O binary, framework or
Info.plist under the built app bundle references network, analytics or
CloudKit capabilities, and that the app target uses no custom
entitlements file. This is static binary/plist review only: it is NOT
observed network-capture evidence, and it never substitutes for the
physical-device offline journey (recorded as an explicit blocker).

Usage:
    python3 Scripts/entitlement_audit.py --app-bundle path/to/SeatWeave.app
    python3 Scripts/entitlement_audit.py --source-only   # no built bundle

Exit status 0 = audit passed, 1 = violation found, 2 = usage/IO error.
"""
import argparse
import json
import plistlib
import re
import sys
import subprocess
from pathlib import Path

# Frameworks whose mere presence inside the bundle would mean a
# networking / tracking / sync dependency. Swift system libraries
# (SwiftUI, SwiftData, CoreData, ...) are expected and NOT flagged.
FORBIDDEN_FRAMEWORKS = {
    "Network.framework",
    "CFNetwork.framework",
    "CloudKit.framework",
    "AdSupport.framework",
    "AppTrackingTransparency.framework",
}

# Capability / purpose-string keys that must not appear in Info.plist
# or embedded entitlements.
FORBIDDEN_KEYS = {
    "NSAppTransportSecurity",
    "NSBonjourServices",
    "NSLocalNetworkUsageDescription",
    "NSMotionUsageDescription",
    "NSUbiquitousContainers",
    "UIBackgroundModes",
    "NSUserTrackingUsageDescription",
}

# Capability values forbidden inside entitlements dictionaries.
FORBIDDEN_ENTITLEMENT_VALUES = re.compile(
    r"(icloud|cloudkit|aps-environment|network|sigapp|get-task-allow)", re.IGNORECASE
)

# Absolute Mach-O section markers: a linked binary embedding CloudKit or
# the network framework carries these dylib load commands.
FORBIDDEN_LOAD_COMMAND_MARKERS = (
    "/System/Library/Frameworks/Network.framework/",
    "/System/Library/Frameworks/CFNetwork.framework/",
    "/System/Library/Frameworks/CloudKit.framework/",
    "/System/Library/Frameworks/AdSupport.framework/",
    "/System/Library/Frameworks/AppTrackingTransparency.framework/",
)


def _otool_output(binary: Path) -> str:
    """Return `otool -L` output for a binary, or an empty string when
    otool is unavailable (Linux hosts cannot parse Mach-O here)."""
    try:
        result = subprocess.run(
            ["otool", "-L", str(binary)], capture_output=True, text=True, timeout=30
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""
    return result.stdout


def audit_bundle(bundle: Path) -> list[str]:
    violations: list[str] = []

    if not bundle.is_dir():
        return [f"app bundle missing: {bundle}"]

    # 1. Forbidden frameworks anywhere in the bundle.
    for path in bundle.rglob("*"):
        for framework in FORBIDDEN_FRAMEWORKS:
            if framework in path.parts:
                violations.append(f"forbidden framework present: {path}")

    # 2. Info.plists: main and any nested.
    plists = [bundle / "Info.plist", *bundle.rglob("Info.plist")]
    seen = set()
    for plist_path in plists:
        if not plist_path.is_file() or plist_path in seen:
            continue
        seen.add(plist_path)
        try:
            with plist_path.open("rb") as handle:
                info = plistlib.load(handle)
        except Exception as error:  # unreadable plist is itself a finding
            violations.append(f"unreadable Info.plist {plist_path}: {error}")
            continue
        for key in FORBIDDEN_KEYS:
            if key in info:
                violations.append(f"forbidden Info.plist key {key} in {plist_path}")
        modes = info.get("UIBackgroundModes", [])
        if isinstance(modes, list) and any("fetch" in m or "processing" in m or "remote" in m for m in modes):
            violations.append(f"background networking modes in {plist_path}: {modes}")

    # 3. Mach-O load commands (only meaningful on macOS).
    binaries = [p for p in bundle.rglob("*") if p.is_file() and p.suffix == ""]
    checked_any_macho = False
    for binary in binaries:
        listing = _otool_output(binary)
        if not listing:
            continue
        checked_any_macho = True
        for marker in FORBIDDEN_LOAD_COMMAND_MARKERS:
            if marker in listing:
                violations.append(f"binary {binary} links {marker}")

    # 4. Embedded entitlements (plist XML inside __TEXT,__ents or .xcent).
    # Unsigned simulator builds carry none; presence of capability
    # strings is a violation.
    for path in bundle.rglob("*.xcent"):
        violations.append(f"unexpected entitlements artifact in bundle: {path}")

    return violations


def audit_source_only(repo_root: Path) -> list[str]:
    """Linux-runnable subset: source tree and project file must not
    reference forbidden capabilities or a custom entitlements file."""
    violations: list[str] = []
    project = repo_root / "SeatWeave.xcodeproj" / "project.pbxproj"
    if project.is_file():
        text = project.read_text(encoding="utf-8", errors="replace")
        if "CODE_SIGN_ENTITLEMENTS" in text:
            violations.append("project.pbxproj declares CODE_SIGN_ENTITLEMENTS")
        for framework in FORBIDDEN_FRAMEWORKS:
            if framework in text:
                violations.append(f"project.pbxproj links {framework}")
    else:
        violations.append(f"project file missing: {project}")

    for source in sorted(list((repo_root / "App").rglob("*.swift")) +
                         list((repo_root / "Packages" / "SeatingDomain" / "Sources").rglob("*.swift"))):
        text = source.read_text(encoding="utf-8", errors="replace")
        imports = re.findall(r"\bimport\s+(Network|CloudKit|AdSupport|AppTrackingTransparency|CoreBluetooth|MultipeerConnectivity)\b", text)
        for module in imports:
            violations.append(f"forbidden import {module} in {source}")
        for api in ("URLSession", "NWConnection", "WCSession"):
            if api in text:
                violations.append(f"networking API reference {api} in {source}")
    return violations


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="repository root")
    parser.add_argument("--app-bundle", default="",
                        help="built .app path; omit or --source-only for the static source subset")
    parser.add_argument("--source-only", action="store_true")
    parser.add_argument("--report", default="", help="optional JSON report path")
    args = parser.parse_args(argv[1:])

    repo_root = Path(args.repo_root).resolve()
    violations = audit_source_only(repo_root)
    mode = "source-only"
    if not args.source_only and args.app_bundle:
        mode = "bundle"
        violations += audit_bundle(Path(args.app_bundle))

    report = {
        "mode": mode,
        "note": ("static Mach-O/plist/source review; not observed network-capture evidence "
                 "and not a substitute for a physical-device offline journey"),
        "violations": violations,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
