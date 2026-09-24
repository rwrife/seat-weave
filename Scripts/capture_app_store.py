#!/usr/bin/env python3
"""Capture real UI with synthetic data in an isolated, unsigned simulator build.
Requires Xcode and the iOS 26.5 runtime. Production source is never modified.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'AppStore/screenshots/6.5-inch'
ENV = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')

def run(*args, **kwargs):
    return subprocess.run(args, env=ENV, check=True, text=True, **kwargs)

def sim(*args, **kwargs):
    return run('xcrun', 'simctl', *args, **kwargs)

fixture = '''
        let guests = ["Avery", "Jordan", "Maya", "Noah", "Olivia", "Theo", "Isla", "Leo"].map { GuestIdentity(displayName: $0) }
        let tables = [SeatingTable(label: "Table 1", seatCount: 4), SeatingTable(label: "Table 2", seatCount: 4)]
        let seats = guests.enumerated().map { i, guest in
            SeatAssignment(guestID: guest.id, tableID: tables[i / 4].id, seatNumber: i % 4 + 1)
        }
        let preferences = [
            PairPreference(firstGuestID: guests[0].id, secondGuestID: guests[1].id, kind: .adjacent),
            PairPreference(firstGuestID: guests[2].id, secondGuestID: guests[3].id, kind: .sameTable),
            PairPreference(firstGuestID: guests[0].id, secondGuestID: guests[4].id, kind: .differentTables),
            PairPreference(firstGuestID: guests[6].id, secondGuestID: guests[7].id, kind: .adjacent)
        ]
        let main = PlanVariant(name: "Dinner together", tables: tables, assignments: seats)
        var alternate = seats
        alternate[1] = SeatAssignment(guestID: guests[1].id, tableID: tables[1].id, seatNumber: 2)
        alternate[5] = SeatAssignment(guestID: guests[5].id, tableID: tables[0].id, seatNumber: 2)
        let other = PlanVariant(name: "Mix it up", tables: tables, assignments: alternate)
        let draft = PlanVariant(name: "Fresh start", tables: tables)
        let sample = SeatingEvent(title: "Friendsgiving", guests: guests, preferences: preferences, variants: [main, other, draft])
        try! store!.save(sample)
        refreshEventList()
        open(eventID: sample.id)
'''

OUT.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='seat-weave-capture-') as tmp:
    work = Path(tmp)
    for folder in ['App', 'Packages', 'SeatWeave.xcodeproj', 'UITests']:
        shutil.copytree(ROOT / folder, work / folder, ignore=shutil.ignore_patterns('.build', 'xcuserdata'))
    model = work / 'App/AppModel.swift'
    source = model.read_text()
    marker = 'self.store = AppModel.makeStore()\n        refreshEventList()'
    assert marker in source
    model.write_text(source.replace(marker, marker + fixture, 1))
    layout = work / 'App/SeatingWorkspaceLayout.swift'
    source = layout.read_text().replace('struct CompactWorkspaceTabs: View {', 'struct CompactWorkspaceTabs: View {\n    @State private var captureTab = UserDefaults.standard.integer(forKey: "captureTab")')
    source = source.replace('TabView {', 'TabView(selection: $captureTab) {', 1)
    for i, name in enumerate(['Guests', 'Tables', 'Pairs', 'Plans', 'Share']):
        source = source.replace(f'{name}Tab()\n                .tabItem', f'{name}Tab()\n                .tag({i})\n                .tabItem', 1)
    layout.write_text(source)
    share = work / 'App/ShareTab.swift'
    source = share.read_text()
    source = source.replace('.sheet(item: $previewBox)', '.onAppear {\n            if let preview = model.exportSelectedPlan() { previewBox = PreviewBox(preview: preview) }\n        }\n        .sheet(item: $previewBox)', 1)
    share.write_text(source)
    device = sim('create', 'Seat Weave App Store 6.5', 'com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max', 'com.apple.CoreSimulator.SimRuntime.iOS-26-5', capture_output=True).stdout.strip()
    try:
        sim('boot', device)
        sim('bootstatus', device, '-b')
        sim('ui', device, 'appearance', 'light')
        sim('status_bar', device, 'override', '--time', '9:41', '--dataNetwork', 'wifi', '--wifiMode', 'active', '--wifiBars', '3', '--batteryState', 'charged', '--batteryLevel', '100')
        log_path = ROOT / 'build/app-store/capture-build.log'
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open('w') as log:
            run('xcodebuild', '-project', str(work / 'SeatWeave.xcodeproj'), '-scheme', 'SeatWeave', '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', f'id={device}', '-derivedDataPath', str(work / 'DerivedData'), 'CODE_SIGNING_ALLOWED=NO', 'build', stdout=log, stderr=subprocess.STDOUT)
        sim('install', device, str(work / 'DerivedData/Build/Products/Debug-iphonesimulator/SeatWeave.app'))
        for tab, name in [(1, '01-seating'), (0, '02-guests'), (2, '03-preferences'), (3, '04-plans'), (4, '05-share')]:
            sim('launch', device, 'com.infinityball.seatweave', '-resetStore', 'YES', '-captureTab', str(tab))
            time.sleep(4)
            sim('io', device, 'screenshot', str(OUT / f'{name}.png'))
            sim('terminate', device, 'com.infinityball.seatweave')
    finally:
        sim('shutdown', device)
        sim('delete', device)
run('xcrun', 'swift', '-module-cache-path', str(Path(tempfile.gettempdir()) / 'seat-weave-swift-cache'), str(ROOT / 'Scripts/opaque_png.swift'), *map(str, sorted(OUT.glob('*.png'))))
print(f'Screenshots saved to {OUT}')
