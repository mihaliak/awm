import Carbon
import Foundation
import ServiceManagement
import Testing
@testable import AWM

@Test @MainActor func captureSavesOverlappingVisibleWindowsAndOmitsRunningAppsInventory() throws {
    let system = WindowFixture()
    system.running = [
        liveApp("Writer", pid: 10), liveApp("Hidden", pid: 20, hidden: true),
        liveApp("Background", pid: 30)
    ]
    let overlapping = CGRect(x: 100, y: 60, width: 300, height: 500)
    system.list[10] = [
        window(1, frame: overlapping), window(2, frame: overlapping),
        window(3, minimized: true), window(4)
    ]
    system.list[20] = [window(5)]
    system.offSpace.insert(4)
    system.focus = 2
    let snapshot = try system.capture(focusedPID: 10)
    #expect(snapshot.runningApps == nil)
    #expect(snapshot.members.map(\.identity.name) == ["Writer"])
    let member = try #require(snapshot.members.first)
    #expect(member.windows.count == 2)
    #expect(member.windows.map(\.frame) == [overlapping, overlapping])
    #expect(member.windows.last?.id == snapshot.focusedWindow)
}

@Test @MainActor func captureRejectsEmptyPermissionAndUnavailableWindowList() {
    let system = WindowFixture()
    #expect(throws: WorkspaceError.emptyCapture) { try system.capture(focusedPID: nil) }
    system.compositorAvailable = false
    #expect(throws: WorkspaceError.visibility) { try system.capture(focusedPID: nil) }
    system.authorized = false
    #expect(throws: WorkspaceError.permission) { try system.capture(focusedPID: nil) }
}

@Test @MainActor func captureSelectionUsesFrozenPositionsAndDropsExcludedFocusAndApps() throws {
    let system = WindowFixture()
    system.running = [liveApp("Chrome", pid: 10), liveApp("Writer", pid: 20)]
    system.list[10] = [window(1), window(2)]
    system.list[20] = [window(3)]
    system.focus = 2
    let frozen = try system.capture(focusedPID: 10)
    let chooser = PresetCapture(frozen, preferences: Preferences())
    let chrome = try #require(frozen.members.first)
    let first = try #require(chrome.windows.first)
    #expect(chooser.initialSelection.count == 3)
    #expect(chrome.windowLabel(for: first) == "Window 1")
    #expect(chooser.location(of: first).contains(referenceDisplay.name))
    system.list[10] = [window(5)]
    system.focus = 5
    let selected = chooser.selecting([first.id])
    #expect(selected.members == [SavedApp(identity: chrome.identity, windows: [first])])
    #expect(selected.focusedWindow == nil)
    #expect(selected.displays == frozen.displays)
    #expect(selected.runningApps == nil)
    #expect(chooser.selecting(chooser.initialSelection).focusedWindow == frozen.focusedWindow)
    var state = AppState()
    #expect(throws: WorkspaceError.name) { try state.save(name: "  ", snapshot: selected) }
    #expect(throws: WorkspaceError.emptyCapture) { try state.save(name: "Work", snapshot: chooser.selecting([])) }
    #expect(state.presets.isEmpty)
}

@Test @MainActor func updateSelectionDefaultsToMappedExistingWindowsAndLeavesExtrasUnchecked() throws {
    let left = display("left", frame: CGRect(x: -1200, y: 0, width: 1200, height: 900))
    let original = DisplayLayout(screens: [referenceDisplay, left])
    let savedSlot = saved(window(1, frame: CGRect(x: -1000, y: 150, width: 450, height: 500)), display: left)
    let browser = identity("Chrome")
    let previous = preset([SavedApp(identity: browser, windows: [savedSlot])], layout: original)
    let target = try #require(referenceLayout.target(for: savedSlot, from: original, destinations: [:],
                                                    preferences: Preferences()))
    let system = WindowFixture()
    system.running = [liveApp("Chrome", pid: 10), liveApp("Chrome", pid: 11), liveApp("Writer", pid: 20)]
    system.list[10] = [window(2)]
    system.list[11] = [window(3, frame: target, order: 2)]
    system.list[20] = [window(4)]
    system.focus = 3
    let current = try system.capture(focusedPID: 11)
    let update = PresetCapture(current, updating: previous, preferences: Preferences())
    let selected = update.selecting(update.initialSelection)
    #expect(update.initialSelection.count == 1)
    #expect(selected.members.map(\.identity) == [browser])
    #expect(selected.members.first?.windows.first?.frame == target)
    #expect(selected.focusedWindow == current.focusedWindow)
}

@Test func storeRoundTripsFullStateAndKeepsStableIDsAcrossRenameAndUpdate() throws {
    try withStore { store in
        let member = SavedApp(identity: identity("Writer"), windows: [saved(window(1))])
        let initial = try store.load()
        var state = initial.state
        let created = try state.save(name: "Work", snapshot: preset([member]).snapshot, icon: .code)
        #expect(created.icon == .code)
        try state.setIcon(.book, for: created.id)
        try state.rename(created.id, to: "Písanie: #1 🪟")
        let extra = display("external", frame: CGRect(x: -900, y: 0, width: 900, height: 800))
        let focused = saved(window(2, frame: CGRect(x: -800, y: 20, width: 521.5, height: 622)),
                            display: extra)
        let later = WorkspaceSnapshot(displays: DisplayLayout(screens: [referenceDisplay, extra]),
                                      runningApps: [member.identity, identity("Background")],
                                      members: [SavedApp(identity: member.identity, windows: [focused])],
                                      focusedWindow: focused.id)
        try state.update(created.id, snapshot: later)
        try state.associateDisplays(created.id, enabled: true)
        state.lastActive = created.id
        state.preferences.windowGapUnit = .points
        state.preferences.windowGapPercent = 3
        state.preferences.windowGapPoints = 21
        state.preferences.marginPercent = 8
        state.preferences.outsidePolicy = .leave
        state.preferences.autoActivate = true
        state.preferences.launchMissing = false
        state.preferences.revealMembers = false
        state.preferences.leftWidths = try [#require(WindowFraction(0.100000008))]
        state.preferences.rightWidths = try [#require(WindowFraction(0.9))]
        state.preferences.topHeights = try [#require(WindowFraction(0.4))]
        state.preferences.bottomHeights = try [#require(WindowFraction(0.75))]
        state.preferences.animate = true
        state.preferences.restoreOnLaunch = true
        state.preferences.launchAtLogin = true
        let key = try #require(state.shortcuts.first?.key)
        try state.assign(nil, to: .arrange(.left))
        try state.assign(key, to: .preset(created.id))
        let persisted = try store.write(state, replacing: initial)

        let file = try String(contentsOf: store.url, encoding: .utf8)
        #expect(file.split(separator: "\n").contains("version: \(AppState.currentFormat)"))
        #expect(file.contains("Písanie: #1"))
        var reopened = try WorkspaceStore(url: store.url).load().state
        try expectStored(reopened, preserves: state)
        #expect(reopened.preset(created.id)?.name == "Písanie: #1 🪟")
        #expect(reopened.preset(created.id)?.icon == .book)
        let persistedSnapshot = try #require(reopened.preset(created.id)?.snapshot)
        try withStore { restored in
            try FileManager.default.copyItem(at: store.url, to: restored.url)
            #expect(try restored.load().state == reopened)
        }
        let empty = preset([]).snapshot
        #expect(throws: WorkspaceError.emptyCapture) { try reopened.update(created.id, snapshot: empty) }
        #expect(reopened.preset(created.id)?.snapshot == persistedSnapshot)
        try reopened.delete(created.id)
        _ = try store.write(reopened, replacing: persisted)
        #expect(try store.load().state.presets.isEmpty)
        #expect(try store.load().state.lastActive == nil)
        #expect(!(try store.load()).state.shortcuts.contains(where: { $0.action == .preset(created.id) }))
    }
}

@Test(arguments: WorkspaceIcon.allCases)
func workspaceIconKeepsItsStableIDAcrossFormatSevenBackup(icon: WorkspaceIcon) throws {
    try withStore { store in
        let initial = try store.load()
        var state = initial.state
        let captured = preset([SavedApp(identity: identity("Writer"), windows: [saved(window(1))])])
        let workspace = try state.save(name: captured.name, snapshot: captured.snapshot, icon: icon)
        let persisted = try store.write(state, replacing: initial).state
        let file = try String(contentsOf: store.url, encoding: .utf8)
        #expect(file.contains("version: 7"))
        #expect(file.contains("presets:"))
        #expect(file.contains("icon: \(icon.rawValue)"))
        #expect(try store.load().state == persisted)
        #expect(persisted.preset(workspace.id)?.icon == icon)
    }
}

@Test @MainActor func workspaceOrderPersistsByIDWithoutChangingWorkspaceData() throws {
    try withStore { store in
        let initial = try store.load()
        let snapshot = preset([SavedApp(identity: identity("Writer"), windows: [saved(window(1))])]).snapshot
        var seeded = initial.state
        let first = try seeded.save(name: "Writing", snapshot: snapshot, icon: .book)
        let middle = try seeded.save(name: "Writing", snapshot: snapshot, icon: .code)
        let last = try seeded.save(name: "Review", snapshot: snapshot, icon: .star)
        try seeded.associateDisplays(middle.id, enabled: true)
        let key = try #require(seeded.shortcuts.first?.key)
        try seeded.assign(nil, to: .arrange(.left))
        try seeded.assign(key, to: .preset(middle.id))
        seeded.lastActive = middle.id
        seeded.preferences.autoActivate = true
        seeded.preferences.windowGapPoints = 21
        let stored = try store.write(seeded, replacing: initial).state
        let originalFile = try Data(contentsOf: store.url)
        let model = AppModel(store: store)
        #expect(model.state == stored)
        #expect(model.state.presets.map(\.id) == [first.id, middle.id, last.id])
        #expect(try Data(contentsOf: store.url) == originalFile)
        #expect(!model.authorized)

        #expect(model.state.index(ofPreset: middle.id) == 1)
        #expect(model.state.canMovePreset(middle.id, direction: .up))
        #expect(model.state.canMovePreset(middle.id, direction: .down))
        #expect(model.movePreset(middle.id, direction: .down))
        #expect(model.state.presets.map(\.id) == [first.id, last.id, middle.id])
        #expect(!model.state.canMovePreset(middle.id, direction: .down))
        #expect(model.movePreset(middle.id, direction: .up))
        #expect(model.state == stored)
        #expect(model.movePreset(middle.id, direction: .up))
        #expect(!model.state.canMovePreset(middle.id, direction: .up))

        let reopened = AppModel(store: store).state
        var expected = stored
        expected.presets.swapAt(0, 1)
        #expect(reopened == expected)
        #expect(reopened.automaticPreset(for: snapshot.displays)?.id == middle.id)
        var appended = reopened
        let newcomer = try appended.save(name: "New", snapshot: snapshot)
        #expect(appended.presets.map(\.id) == [middle.id, first.id, last.id, newcomer.id])
    }
}

@Test(arguments: [1, 3])
@MainActor func workspaceEndpointsLeaveExistingYAMLBytesAlone(count: Int) throws {
    try withStore { store in
        let initial = try store.load()
        let snapshot = preset([SavedApp(identity: identity("Writer"), windows: [saved(window(1))])]).snapshot
        var seeded = initial.state
        for position in 1...count { _ = try seeded.save(name: "Workspace \(position)", snapshot: snapshot) }
        let stored = try store.write(seeded, replacing: initial).state
        let bytes = try Data("# Existing backup\n".utf8) + Data(contentsOf: store.url)
        try bytes.write(to: store.url, options: .atomic)
        let first = try #require(stored.presets.first?.id)
        let last = try #require(stored.presets.last?.id)
        let model = AppModel(store: store)

        for (id, direction) in [(first, PresetMoveDirection.up), (last, .down)] {
            #expect(!model.state.canMovePreset(id, direction: direction))
            #expect(model.movePreset(id, direction: direction))
            #expect(model.movePreset(id, direction: direction))
        }
        let missing = UUID()
        #expect(!model.state.canMovePreset(missing, direction: .up))
        #expect(!model.movePreset(missing, direction: .up))
        #expect(model.state == stored)
        #expect(try Data(contentsOf: store.url) == bytes)

        var empty = AppState()
        #expect(empty.index(ofPreset: missing) == nil)
        #expect(!empty.canMovePreset(missing, direction: .down))
        #expect(throws: WorkspaceError.missingPreset) { try empty.movePreset(missing, direction: .down) }
    }
}

@Test(arguments: [nil, "future-icon"] as [String?])
func formatSevenWorkspaceWithoutKnownIconLoadsWithoutChangingBytes(iconID: String?) throws {
    try withStore { store in
        let initial = try store.load()
        var state = try privacyFixture()
        state.displaySalt = initial.state.displaySalt
        _ = try store.write(state, replacing: initial)
        let currentState = try store.load().state
        let encoded = try String(contentsOf: store.url, encoding: .utf8)
        let replacement = iconID.map { "  icon: \($0)\n" } ?? ""
        let fixture = encoded.replacingOccurrences(of: "  icon: layout\n", with: replacement)
        #expect(fixture != encoded)
        let bytes = Data(fixture.utf8)
        try bytes.write(to: store.url)
        let loaded = try store.load().state
        #expect(loaded == currentState)
        #expect(loaded.presets.first?.icon == .standard)
        #expect(try Data(contentsOf: store.url) == bytes)
    }
}

@Test(arguments: ["broken: [YAML", "version: 999", "version: 4", "version: 5\nversion: 5"])
func invalidOrNewerYAMLIsPreserved(text: String) throws {
    try withStore { store in
        let data = Data(text.utf8)
        try data.write(to: store.url)
        #expect(throws: WorkspaceError.self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == data)
    }
}

@Test @MainActor func appModelRemembersBothGapAmounts() throws {
    try withStore { store in
        let initial = try store.load()
        var next = initial.state
        next.preferences.windowGapPercent = 5
        _ = try store.write(next, replacing: initial)

        let model = AppModel(store: store)
        #expect(model.canSave)
        model.set(\.windowGapUnit, .points)
        model.set(\.windowGapPoints, 38)
        model.set(\.windowGapUnit, .percentage)
        #expect(model.state.preferences.windowGapPercent == 5)
        model.set(\.windowGapUnit, .points)
        #expect(model.state.preferences.windowGapPoints == 38)
        next.preferences.windowGapUnit = .points
        next.preferences.windowGapPoints = 38
        #expect(try store.load().state == next)
    }
}

#if DEBUG
@Test @MainActor func failedCapturesPreserveSavedWorkspacesAndReportTheirCause() throws {
    try withStore { store in
        let log = store.url.deletingLastPathComponent().appending(path: ".awm.error.log")
        let model = AppModel(store: store, errorLog: ErrorLog(url: log))
        model.verificationCapture = preset([SavedApp(identity: identity("Editor"), windows: [saved(window(1))])]).snapshot
        let capture = try #require(model.beginCapture(updating: nil, pid: nil))
        try #require(model.saveCapture(capture, name: "Existing", selected: capture.initialSelection))
        let existing = try #require(model.state.presets.first)
        let updating = try #require(model.beginCapture(updating: existing.id, pid: nil))
        let original = try Data(contentsOf: store.url)

        model.verificationAuthorized = false
        #expect(!model.saveCapture(updating, name: "", selected: updating.initialSelection))
        model.verificationAuthorized = true
        #expect(!model.saveCapture(capture, name: "No windows", selected: []))
        #expect(!model.saveCapture(capture, name: " \n", selected: capture.initialSelection))
        #expect(model.beginCapture(updating: UUID(), pid: nil) == nil)
        #expect(model.state.presets == [existing])
        #expect(try Data(contentsOf: store.url) == original)

        let entries = try diagnosticRecords(at: log)
        #expect(entries.map(\.operation) == ["save", "save", "save", "capture"])
        #expect(entries.map(\.reason) == ["permission", "emptyCapture", "missingName", "missingPreset"])
        #expect(entries.map { $0.context?.workspace } == ["Existing", "No windows", nil, nil])
    }
}
#endif

@Test(arguments: [0, 1, 12, 13])
@MainActor func cycleEditsPersistOnlySupportedSequenceLengths(count: Int) throws {
    try withStore { store in
        let log = store.url.deletingLastPathComponent().appending(path: ".awm.error.log")
        let model = AppModel(store: store, errorLog: ErrorLog(url: log))
        let before = model.state.preferences
        let original = try Data(contentsOf: store.url)
        let input = Array(repeating: " 50% ", count: count).joined(separator: ",")
        let saved = model.saveCycle(input, at: \.topHeights)
        let persisted = try store.load().state.preferences

        if (1...12).contains(count) {
            #expect(saved?.map(\.fraction) == Array(repeating: 0.5, count: count))
            #expect(saved == persisted.topHeights)
            #expect(persisted.bottomHeights == before.bottomHeights)
            #expect(!FileManager.default.fileExists(atPath: log.path))
        } else {
            #expect(saved == nil && model.state.preferences == before)
            #expect(try Data(contentsOf: store.url) == original)
            let entries = try diagnosticRecords(at: log)
            #expect(entries.map(\.operation) == ["preferences"])
            #expect(entries.map(\.reason) == ["invalidData"])
        }
    }
}

@Test func yamlIsCreatedOnceAndHomeModeIsPreserved() throws {
    try withStore { store in
        let home = store.url.deletingLastPathComponent()
        let files = FileManager.default
        try files.setAttributes([.posixPermissions: 0o751], ofItemAtPath: home.path)
        let fresh = try store.load(launchAtLogin: true)
        var expected = AppState()
        expected.preferences.launchAtLogin = true
        try expectStored(fresh.state, preserves: expected)
        let bytes = try Data(contentsOf: store.url)
        #expect(try store.load().state == fresh.state)
        #expect(try Data(contentsOf: store.url) == bytes)
        #expect(try permissionMode(at: store.url) == 0o600)
        expected.preferences.windowGapPoints = 24
        _ = try store.write(expected, replacing: fresh)
        #expect(try permissionMode(at: store.url) == 0o600)
        #expect(try permissionMode(at: home) == 0o751)
    }
}

@Test(arguments: [5, 6])
func yamlMigrationRemovesDeviceAndAppDetailsAndPreservesPlacement(version: Int) throws {
    try withStore { store in
        let state = try privacyFixture()
        let secret = try privateStoreData(state, version: version)
        try secret.write(to: store.url)

        let migrated = try store.load()
        try expectStored(migrated.state, preserves: state)
        let migratedYAML = try Data(contentsOf: store.url)
        let yaml = String(decoding: migratedYAML, as: UTF8.self)
        for field in ["PRIVATE_SENTINEL", "runningApps:", "bundlePath:", "serial:", "model:", "name: Chrome",
                      "test.Writer", "987654321", "title:", "document:", "identifier:"] {
            #expect(!yaml.contains(field))
        }
        #expect(yaml.contains("bundleID: com.google.Chrome"))
        #expect(yaml.contains("fingerprint:"))
        #expect(try permissionMode(at: store.url) == 0o600)
        try expectStored(store.load().state, preserves: state)
        #expect(try Data(contentsOf: store.url) == migratedYAML)

        var next = migrated.state
        next.preferences.windowGapPoints = 45
        _ = try store.write(next, replacing: migrated)
        #expect(try store.load().state == next)
        // Restoring an old copy triggers a fresh migration and creates distinct pseudonyms.
        try secret.write(to: store.url, options: .atomic)
        #expect(throws: WorkspaceError.storageChanged) { try store.write(next, replacing: migrated) }
        let restored = try store.load().state
        try expectStored(restored, preserves: state)
        #expect(restored.displaySalt != migrated.state.displaySalt)
        #expect(restored.presets.first?.snapshot.displays != migrated.state.presets.first?.snapshot.displays)
    }
}

@Test func failedYAMLMigrationLeavesOriginalAndCreatesNoBackup() throws {
    try withStore { store in
        let root = store.url.deletingLastPathComponent()
        let secret = try privateStoreData(privacyFixture(), version: 5)
        try secret.write(to: store.url)
        let files = FileManager.default
        try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == secret)
        #expect(try files.contentsOfDirectory(atPath: root.path) == [".awm.yaml"])
    }
}

@Test func unreadableYAMLLeavesItsSymbolicLinkInPlace() throws {
    try withStore { store in
        let files = FileManager.default
        let missing = store.url.deletingLastPathComponent().appending(path: "missing")
        try files.createSymbolicLink(at: store.url, withDestinationURL: missing)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try files.destinationOfSymbolicLink(atPath: store.url.path) == missing.path)
    }
}

@Test(arguments: [
    ("windowGapPercent: 0", #"windowGapPercent: "0""#),
    ("windowGapPoints: 12", "windowGapPoints: [12]"),
    ("windowGapUnit: percentage", "windowGapUnit: pixels"),
    ("launchAtLogin: false", "launchAtLogin: null"),
    ("launchAtLogin: false", #"launchAtLogin: "true""#),
    ("restoreOnLaunch: false", "restoreOnLaunch: {flag: false}")
])
func malformedYAMLValuesArePreserved(field: (String, String)) throws {
    try withStore { store in
        let initial = try store.load()
        let original = try String(contentsOf: store.url, encoding: .utf8)
        try #require(original.contains(field.0))
        let malformed = Data(original.replacingOccurrences(of: field.0, with: field.1).utf8)
        try malformed.write(to: store.url, options: .atomic)
        #expect(throws: WorkspaceError.invalidData) { try store.load() }
        #expect(throws: WorkspaceError.storageChanged) { try store.write(initial.state, replacing: initial) }
        #expect(try Data(contentsOf: store.url) == malformed)
    }
}

@Test func failedWriteLeavesSavedYAMLIntactAndCleansTemporaryFile() throws {
    try withStore { store in
        let files = FileManager.default
        let initial = try store.load()
        let original = try Data(contentsOf: store.url)
        let home = store.url.deletingLastPathComponent()
        let mode = try permissionMode(at: home)
        try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        defer { try? files.setAttributes([.posixPermissions: mode], ofItemAtPath: home.path) }
        var change = initial.state
        change.preferences.windowGapPoints = 60
        #expect(throws: (any Error).self) { try store.write(change, replacing: initial) }
        #expect(try Data(contentsOf: store.url) == original)
        #expect(try files.contentsOfDirectory(atPath: home.path) == [".awm.yaml"])
    }
}

@Test func backupCopiedOverRunningStoreWinsOverStaleInMemorySettings() throws {
    try withStore { store in
        try withStore { backup in
            let initial = try store.load()
            let receiving = try backup.load()
            var external = receiving.state
            external.preferences.windowGapPoints = 40
            _ = try backup.write(external, replacing: receiving)
            let replacement = try Data(contentsOf: backup.url)
            try replacement.write(to: store.url, options: .atomic)
            var stale = initial.state
            stale.preferences.windowGapPoints = 38
            #expect(throws: WorkspaceError.storageChanged) { try store.write(stale, replacing: initial) }
            #expect(try Data(contentsOf: store.url) == replacement)
            #expect(try store.load().state == external)
        }
    }
}

@Test @MainActor func staleModelEditKeepsItsStateAndTheNewerStoredWorkspace() throws {
    try withStore { store in
        let loaded = try store.load()
        var seeded = loaded.state
        let work = try seeded.save(name: "Before", snapshot: preset([SavedApp(identity: identity("Editor"), windows: [saved(window(1))])]).snapshot)
        let initial = try store.write(seeded, replacing: loaded)
        let log = store.url.deletingLastPathComponent().appending(path: ".awm.error.log")
        let model = AppModel(store: store, errorLog: ErrorLog(url: log))

        var edit = initial.state
        try edit.rename(work.id, to: "Newer")
        let current = try store.write(edit, replacing: initial)
        let replacement = try Data(contentsOf: store.url)
        #expect(!model.rename(work.id, to: "Stale"))
        #expect(model.state == initial.state)
        #expect(try store.load().state == current.state)
        #expect(try Data(contentsOf: store.url) == replacement)
        let entries = try diagnosticRecords(at: log)
        #expect(entries.map(\.operation) == ["editPreset"])
        #expect(entries.map(\.reason) == ["storageChanged"])
        #expect(entries.map { $0.context?.workspace } == ["Before"])
    }
}

@Test @MainActor func staleWorkspaceMoveKeepsTheOriginalOrderAndTheExternalFile() throws {
    try withStore { store in
        let initial = try store.load()
        let snapshot = preset([SavedApp(identity: identity("Writer"), windows: [saved(window(1))])]).snapshot
        var seeded = initial.state
        let work = try seeded.save(name: "Before", snapshot: snapshot)
        _ = try seeded.save(name: "Review", snapshot: snapshot)
        let stored = try store.write(seeded, replacing: initial)
        let log = store.url.deletingLastPathComponent().appending(path: ".awm.error.log")
        let model = AppModel(store: store, errorLog: ErrorLog(url: log))

        var edit = stored.state
        try edit.rename(work.id, to: "Newer")
        let current = try store.write(edit, replacing: stored)
        let replacement = try Data(contentsOf: store.url)
        #expect(model.state.canMovePreset(work.id, direction: .down))
        #expect(!model.movePreset(work.id, direction: .down))
        #expect(model.state == stored.state)
        #expect(try store.load().state == current.state)
        #expect(try Data(contentsOf: store.url) == replacement)
        let entries = try diagnosticRecords(at: log)
        #expect(entries.map(\.operation) == ["editPreset"])
        #expect(entries.map(\.reason) == ["storageChanged"])
        #expect(entries.map { $0.context?.workspace } == ["Before"])
    }
}

@Test(arguments: [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound], [false, true])
@MainActor func loginPreferenceAppliesOnlyOnMismatch(status: SMAppService.Status, desired: Bool) throws {
    var events: [String] = []
    let fixture = LoginItem(status: { status }, register: { events.append("register") },
                            unregister: { events.append("unregister") })
    let requested = status == .enabled || status == .requiresApproval
    #expect(fixture.isRequested == requested)
    try fixture.apply(desired)
    #expect(events == (desired == requested ? [] : [desired ? "register" : "unregister"]))
}

@Test @MainActor func loginIntentIsSavedBeforeRequestAndPendingStatusIsShown() throws {
    try withStore { store in
        var status: SMAppService.Status = .notRegistered
        var requests = 0
        let fixture = LoginItem(status: { status }, register: {
            let persisted = try store.load()
            #expect(persisted.state.preferences.launchAtLogin)
            status = .requiresApproval
            requests += 1
        }, unregister: { status = .notRegistered })
        let model = AppModel(store: store, loginItem: fixture)
        model.setLogin(true)
        model.setLogin(true)
        #expect(requests == 1)
        #expect(model.loginStatus == .requiresApproval)
        #expect(model.state.preferences.launchAtLogin)
        model.setLogin(false)
        #expect(model.loginStatus == .notRegistered)
        let persisted = try store.load()
        #expect(!persisted.state.preferences.launchAtLogin)
    }
}

@Test @MainActor func loginRequestFailureKeepsSavedIntentAndCanBeRetried() throws {
    try withStore { store in
        let log = store.url.deletingLastPathComponent().appending(path: ".awm.error.log")
        var status: SMAppService.Status = .notRegistered
        var requests = 0
        let item = LoginItem(status: { status }, register: {
            requests += 1
            let persisted = try store.load()
            #expect(persisted.state.preferences.launchAtLogin)
            if requests == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            status = .enabled
        }, unregister: { Issue.record("Unexpected request to disable login") })
        let model = AppModel(store: store, loginItem: item, errorLog: ErrorLog(url: log))

        model.setLogin(true)
        #expect(model.state.preferences.launchAtLogin && model.loginStatus == .notRegistered)
        let first = try Data(contentsOf: store.url)
        model.setLogin(true)
        #expect(requests == 2 && model.loginStatus == .enabled)
        #expect(try Data(contentsOf: store.url) == first)
        let entries = try diagnosticRecords(at: log)
        #expect(entries.map(\.operation) == ["login"])
        #expect(entries.map(\.reason) == ["posix"])
        #expect(entries.map(\.code) == [Int(EPERM)])
    }
}

@Test func automaticRestorationRequiresOptInAndOneExplicitAssociation() throws {
    var state = AppState()
    let apps = [SavedApp(identity: identity("Writer"), windows: [saved(window(1))])]
    let first = try state.save(name: "First", snapshot: preset(apps).snapshot)
    let second = try state.save(name: "Second", snapshot: preset(apps).snapshot)
    #expect(!state.preferences.autoActivate)
    try state.associateDisplays(first.id, enabled: true)
    #expect(state.automaticPreset(for: referenceLayout) == nil)
    state.preferences.autoActivate = true
    #expect(state.automaticPreset(for: referenceLayout)?.id == first.id)
    try state.associateDisplays(second.id, enabled: true)
    #expect(state.preset(first.id)?.followsDisplays == false)
    #expect(state.automaticPreset(for: referenceLayout)?.id == second.id)

    let other = display("external", frame: CGRect(x: -600, y: 0, width: 600, height: 500))
    let changed = DisplayLayout(screens: [referenceDisplay, other])
    #expect(state.automaticPreset(for: changed) == nil)
    try state.update(second.id, snapshot: preset(apps, layout: changed).snapshot)
    #expect(state.automaticPreset(for: referenceLayout)?.id == second.id)
    #expect(state.automaticPreset(for: changed) == nil)
    #expect(state.preset(second.id)?.snapshot.displays == changed)
    try state.validate()
}

@Test @MainActor func restoreReusesAppsLaunchesOnceAndRaisesSavedFocusLast() async {
    let system = WindowFixture()
    let first = saved(window(1))
    let second = saved(window(2))
    let terminal = saved(window(3))
    let work = preset([
        SavedApp(identity: identity("Writer"), windows: [first, second]),
        SavedApp(identity: identity("Terminal"), windows: [terminal])
    ], focusedWindow: second.id)
    system.running = [liveApp("Writer", pid: 10, hidden: true), liveApp("Outside", pid: 30)]
    system.list[10] = [window(11, frame: first.frame), window(12, minimized: true, frame: second.frame)]
    system.list[30] = [window(21)]
    let app = liveApp("Terminal", pid: 20)
    system.launches[app.identity.key] = (app, [window(31)])
    let restore = WorkspaceRestore(system: system)
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value

    #expect(result == RestoreReport(total: 3, placed: 3))
    #expect(system.events == [
        "launch Terminal", "reveal Writer", "place 11", "unminimize 12",
        "place 12", "raise 11", "raise 12", "place 31", "raise 31", "hide Outside", "focus 12"
    ])
    #expect(system.running.count == 3)
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value
    #expect(result?.placed == 3)
    #expect(system.events.filter { $0 == "launch Terminal" }.count == 1)
    #expect(!system.events.contains("launch Writer"))
}

@Test @MainActor func firstRestoreWaitsForStableCompositorBackedStartupWindows() async {
    let system = WindowFixture()
    let app = liveApp("Starting", pid: 10)
    let destination = saved(window(3))
    let work = preset([SavedApp(identity: app.identity, windows: [destination])])
    system.launches[app.identity.key] = (app, [window(11)])
    system.compositorAvailable = false
    system.fullScreen = [11]
    var time: Duration = .zero
    let interval = Duration.milliseconds(100)
    let timing = WindowPlacement.Timing(now: { time }, sleepUntil: { deadline in
        time = deadline
        if time <= interval * 5 { #expect(system.events == ["launch Starting"]) }
        switch time {
        case interval:
            system.compositorAvailable = true
        case interval * 2:
            system.fullScreen = []
            system.offSpace = [11]
        case interval * 3:
            system.offSpace = []
        case interval * 4:
            system.list[app.pid] = [window(11, frame: window(12).frame)]
        default:
            break
        }
    })
    let restore = WorkspaceRestore(system: system, pollInterval: interval, launchTiming: timing)
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value

    #expect(time == interval * 7)
    #expect(result == RestoreReport(total: 1, placed: 1))
    #expect(system.frame(for: 11) == destination.frame)
    #expect(system.events == ["launch Starting", "place 11", "raise 11", "focus 11"])
}

@Test(arguments: [12, 22]) @MainActor func firstRestoreRetriesRejectedAndOverwrittenStartupWindows(secondHandle: Int) async {
    let system = WindowFixture()
    let app = liveApp("Starting", pid: 10)
    let first = saved(window(1))
    let second = saved(window(20))
    let work = preset([SavedApp(identity: app.identity, windows: [first, second])], focusedWindow: second.id)
    let startupWindow = window(12, frame: window(21).frame)
    system.launches[app.identity.key] = (app, [window(11, frame: window(2).frame), startupWindow])
    system.running = [liveApp("Outside", pid: 20)]
    var rejected = false
    system.placementOverride = { handle, _ in
        guard handle == 11, !rejected else { return nil }
        rejected = true
        return .unavailable
    }
    var time: Duration = .zero
    let interval = Duration.milliseconds(100)
    let timing = WindowPlacement.Timing(now: { time }, sleepUntil: { deadline in
        time = deadline
        if time == interval * 2 {
            #expect(system.frame(for: 12) == second.frame)
            system.list[app.pid] = [window(11, frame: window(2).frame), window(secondHandle, frame: startupWindow.frame)]
        }
    })
    let restore = WorkspaceRestore(system: system, pollInterval: interval, launchTiming: timing)
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value

    #expect(result == RestoreReport(total: 2, placed: 2))
    #expect(system.frame(for: 11) == first.frame && system.frame(for: secondHandle) == second.frame)
    #expect(system.events == ["launch Starting", "place 11", "place 12", "place 11", "place \(secondHandle)",
                              "raise 11", "raise \(secondHandle)", "hide Outside", "focus \(secondHandle)"])
}

@Test @MainActor func restoreSharesOneLaunchTimeoutAndStillPlacesRunningMembers() async {
    let system = WindowFixture()
    let starting = liveApp("Starting", pid: 10)
    let running = liveApp("Running", pid: 20)
    let unresolved = identity("Unresolved")
    system.launches[starting.identity.key] = (starting, [window(11, minimized: true)])
    system.unresolvedLaunches = [unresolved.key]
    system.running = [running]
    system.list[running.pid] = [window(21)]
    let target = saved(window(3))
    let work = preset([
        SavedApp(identity: starting.identity, windows: [saved(window(1))]),
        SavedApp(identity: unresolved, windows: [saved(window(2))]),
        SavedApp(identity: running.identity, windows: [target])
    ])
    var time: Duration = .zero
    let timing = WindowPlacement.Timing(now: { time }, sleepUntil: { deadline in
        if system.events.contains("place 21") {
            #expect(time == .milliseconds(250))
        }
        time = deadline
    })
    let restore = WorkspaceRestore(system: system, launchTimeout: .milliseconds(250),
                                   pollInterval: .milliseconds(100), launchTiming: timing)
    var preferences = Preferences()
    preferences.revealMembers = false
    var result: RestoreReport?
    await restore.request(work, preferences: preferences) { result = try? $0.get() }.value

    #expect(time == .milliseconds(300))
    #expect(result?.placed == 1 && result?.issues == [.minimized, .appUnavailable])
    #expect(system.frame(for: 21) == target.frame)
    #expect(system.events == ["launch Starting", "launch Unresolved", "place 21", "raise 21", "focus 21"])
}

@Test @MainActor func cancellingStartupConfirmationSkipsRetriesAndFinalSideEffects() async {
    let system = WindowFixture()
    let app = liveApp("Starting", pid: 10)
    system.launches[app.identity.key] = (app, [window(11)])
    system.running = [liveApp("Outside", pid: 20)]
    let work = preset([SavedApp(identity: app.identity, windows: [saved(window(1))])])
    var request: Task<Void, Never>?
    var time: Duration = .zero
    let interval = Duration.milliseconds(100)
    let timing = WindowPlacement.Timing(now: { time }, sleepUntil: { deadline in
        time = deadline
        if time == interval * 2 { request?.cancel() }
    })
    let restore = WorkspaceRestore(system: system, pollInterval: interval, launchTiming: timing)
    var completed = false
    request = restore.request(work, preferences: Preferences()) { _ in completed = true }
    await request?.value

    #expect(!completed)
    #expect(system.events == ["launch Starting", "place 11"])
}

@Test(arguments: [12, 22]) @MainActor
func restoreReacquiresAMinimizedWindowWithNoFrame(revealedHandle: Int) async {
    let system = WindowFixture()
    let app = liveApp("Terminal", pid: 10)
    let first = saved(window(1))
    let second = saved(window(2))
    system.running = [app]
    system.list[app.pid] = [window(11, frame: first.frame), window(12, minimized: true)]
    system.unreadable = [12]
    let work = preset([SavedApp(identity: app.identity, windows: [first, second])], focusedWindow: second.id)
    var time: Duration = .zero
    let timing = WindowPlacement.Timing(now: { time }, sleepUntil: { deadline in
        time = deadline
        guard time == .milliseconds(50) else { return }
        #expect(system.events == ["place 11", "unminimize 12"])
        if revealedHandle == 12 {
            system.unreadable.remove(12)
        } else {
            system.list[app.pid]?.append(window(revealedHandle, frame: window(12).frame))
        }
    })
    let restore = WorkspaceRestore(system: system, launchTiming: timing)
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value

    #expect(result == RestoreReport(total: 2, placed: 2))
    #expect(system.frame(for: 11) == first.frame && system.frame(for: revealedHandle) == second.frame)
    #expect(system.events == ["place 11", "unminimize 12", "place \(revealedHandle)", "raise 11",
                              "raise \(revealedHandle)", "focus \(revealedHandle)"])
}

@Test @MainActor func restoreRetriesRunningBrowserWhenItsFrameAppearsThenDrifts() async {
    let system = WindowFixture()
    let app = liveApp("Browser", pid: 10)
    let destination = saved(window(1))
    let original = window(11)
    system.running = [app]
    system.list[app.pid] = [original]
    system.unreadable = [original.handle]
    let work = preset([SavedApp(identity: app.identity, windows: [destination])])
    var time: Duration = .zero
    let timing = WindowPlacement.Timing(now: { time }, sleepUntil: { deadline in
        time = deadline
        switch time {
        case .milliseconds(50):
            system.unreadable.remove(original.handle)
        case .milliseconds(100):
            #expect(system.frame(for: original.handle) == destination.frame)
            system.list[app.pid] = [original]
        default:
            break
        }
    })
    let restore = WorkspaceRestore(system: system, launchTiming: timing)
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value

    #expect(result == RestoreReport(total: 1, placed: 1))
    #expect(system.frame(for: original.handle) == destination.frame)
    #expect(system.events == ["place 11", "place 11", "raise 11", "focus 11"])
}

@Test @MainActor func restoreFindsAMissingWindowAfterActivationWithoutAnOpenRequest() async {
    let system = WindowFixture()
    let app = liveApp("Terminal", pid: 10)
    system.running = [app]
    let destination = saved(window(1))
    let work = preset([SavedApp(identity: app.identity, windows: [destination])])
    var polls = 0
    let restore = WorkspaceRestore(system: system, waitForVisibilityUpdate: {
        guard system.events == ["activate 10"] else { return }
        polls += 1
        if polls == 2 { system.list[app.pid] = [window(11)] }
    })
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value

    #expect(result == RestoreReport(total: 1, placed: 1))
    #expect(system.frame(for: 11) == destination.frame)
    #expect(system.events == ["activate 10", "place 11", "raise 11", "focus 11"])
}

@Test @MainActor func cancellationDuringRunningWindowConfirmationSkipsRetriesAndFinalSideEffects() async {
    let system = WindowFixture()
    let app = liveApp("Browser", pid: 10)
    system.running = [app, liveApp("Outside", pid: 20)]
    system.list[app.pid] = [window(11)]
    let work = preset([SavedApp(identity: app.identity, windows: [saved(window(1))])])
    let timing = WindowPlacement.Timing(now: { .zero }, sleepUntil: { _ in
        withUnsafeCurrentTask { $0?.cancel() }
    })
    let restore = WorkspaceRestore(system: system, launchTiming: timing)
    var completed = false
    await restore.request(work, preferences: Preferences()) { _ in completed = true }.value

    #expect(!completed)
    #expect(system.events == ["place 11"])
}

@Test(arguments: OutsidePolicy.allCases)
@MainActor func partialRestoreOnlyAppliesSelectedOutsidePolicy(policy: OutsidePolicy) async {
    let system = WindowFixture()
    system.running = [liveApp("Writer", pid: 10), liveApp("Outside", pid: 20)]
    system.list[10] = [
        window(11, frame: window(1).frame), window(12, frame: window(2).frame),
        window(13, frame: window(3).frame)
    ]
    system.list[20] = [window(21), window(22, minimized: true)]
    system.restricted = [12]
    system.constrained = [11]
    system.offSpace = [13]
    let work = preset([
        SavedApp(identity: identity("Writer"), windows: [
            saved(window(1)), saved(window(2)),
            saved(window(3)), saved(window(4))
        ]),
        SavedApp(identity: identity("Missing App"), windows: [saved(window(5)), saved(window(6))])
    ])
    var prefs = Preferences()
    prefs.outsidePolicy = policy
    let restore = WorkspaceRestore(system: system)
    var result: RestoreReport?
    await restore.request(work, preferences: prefs) { result = try? $0.get() }.value
    #expect(result?.placed == 1)
    #expect(result?.issues.count == 6)
    #expect(result?.total == 6)
    #expect(result?.issues.filter { $0 == .appUnavailable }.count == 2)
    #expect(result?.issues.contains(.offScreen) == true)
    #expect(system.events.filter { $0 == "raise 13" }.count == 1)
    #expect(system.events.contains("hide Outside") == (policy == .hide))
    #expect(system.events.contains("minimize 21") == (policy == .minimize))
    #expect(!system.events.contains("minimize 22"))
    #expect(!system.events.contains("place 13"))
    #expect(system.events.last == "focus 11")
}

@Test @MainActor func failedRestoreLeavesUnrelatedAppsUntouchedAndHonorsRevealAndLaunchSwitches() async {
    let system = WindowFixture()
    system.running = [
        liveApp("Restricted", pid: 10), liveApp("Hidden", pid: 20, hidden: true), liveApp("Outside", pid: 30)
    ]
    system.list[10] = [window(11)]
    system.list[20] = [window(12, minimized: true)]
    system.list[30] = [window(13)]
    system.restricted = [11]
    let work = preset([
        SavedApp(identity: identity("Restricted"), windows: [saved(window(1))]),
        SavedApp(identity: identity("Hidden"), windows: [saved(window(2))]),
        SavedApp(identity: identity("NotLaunched"), windows: [saved(window(3))])
    ])
    var prefs = Preferences()
    prefs.launchMissing = false
    prefs.revealMembers = false
    let restore = WorkspaceRestore(system: system)
    var result: RestoreReport?
    await restore.request(work, preferences: prefs) { result = try? $0.get() }.value
    #expect(result?.placed == 0)
    #expect(result?.issues == [.placementFailed, .hidden, .notRunning])
    #expect(system.events == Array(repeating: "place 11", count: 6))
}

@Test @MainActor func minimizingOtherAppsLeavesUnselectedSiblingsAndReportsFailure() async {
    let system = WindowFixture()
    system.running = [liveApp("Chrome", pid: 10), liveApp("Outside", pid: 20)]
    let first = window(1)
    system.list[10] = [first, window(2)]
    system.list[20] = [window(3), window(4)]
    system.restricted = [4]
    let work = preset([SavedApp(identity: identity("Chrome"), windows: [saved(first)])])
    var prefs = Preferences()
    prefs.outsidePolicy = .minimize
    let restore = WorkspaceRestore(system: system)
    var result: RestoreReport?
    await restore.request(work, preferences: prefs) { result = try? $0.get() }.value
    #expect(result?.placed == 1)
    #expect(result?.issues == [.minimizeOutsideFailed])
    #expect(system.events == ["place 1", "raise 1", "minimize 3", "minimize 4", "focus 1"])
    #expect(system.list[10]?.last?.minimized == false)
}

@Test @MainActor func newestRestoreCancelsAndCoalescesEarlierRequests() async {
    let system = WindowFixture()
    system.running = [liveApp("Writer", pid: 10), liveApp("Editor", pid: 20)]
    system.list[10] = [window(11)]
    system.list[20] = [window(21)]
    system.unresolvedLaunches = [identity("Slow").key]
    let restore = WorkspaceRestore(system: system, launchTimeout: .seconds(10))
    let slow = preset([SavedApp(identity: identity("Slow"), windows: [saved(window(1))])])
    let middle = preset([SavedApp(identity: identity("Writer"), windows: [saved(window(2))])])
    let last = preset([SavedApp(identity: identity("Editor"), windows: [saved(window(3))])])
    var completions: [String] = []
    var first: Task<Void, Never>?
    await withCheckedContinuation { continuation in
        system.onLaunch = {
            system.onLaunch = nil
            continuation.resume()
        }
        first = restore.request(slow, preferences: Preferences()) { _ in completions.append("slow") }
    }
    let second = restore.request(middle, preferences: Preferences()) { _ in completions.append("middle") }
    let latest = restore.request(last, preferences: Preferences()) { _ in completions.append("last") }
    await latest.value
    await first?.value
    await second.value
    #expect(completions == ["last"])
    #expect(system.events == ["launch Slow", "place 21", "raise 21", "hide Writer", "focus 21"])
}

@Test @MainActor func restoreInsetsFullWindowAndPreservesExistingMarginsAcrossRepeatedRuns() async throws {
    let system = WindowFixture()
    let usable = CGRect(x: 0, y: 33, width: 1512, height: 949)
    let primary = display("primary", usable: usable, primary: true)
    let external = display("external", frame: CGRect(x: -1600, y: -30, width: 1600, height: 1000))
    system.layout = DisplayLayout(screens: [primary, external])
    let gappedLeft = CGRect(x: -1588, y: -18, width: 782, height: 976)
    let gappedRight = CGRect(x: -794, y: -18, width: 782, height: 976)
    let interior = CGRect(x: 200, y: 350, width: 603.125, height: 444.25)
    let windows = [window(1, frame: usable), window(2, frame: gappedLeft),
                   window(3, frame: gappedRight), window(4, frame: interior)]
    let members = zip(windows, [primary, external, external, primary]).map { window, display in
        SavedApp(identity: identity("App \(window.handle)"), windows: [saved(window, display: display)])
    }
    system.running = members.enumerated().map { LiveApp(pid: pid_t($0 + 10), identity: $1.identity, hidden: false) }
    for (app, window) in zip(system.running, windows) { system.list[app.pid] = [window] }
    let work = preset(members, layout: system.layout)
    var preferences = Preferences()
    preferences.windowGapUnit = .points
    let restore = WorkspaceRestore(system: system)
    for _ in 0..<2 {
        var result: RestoreReport?
        await restore.request(work, preferences: preferences) { result = try? $0.get() }.value
        #expect(result == RestoreReport(total: 4, placed: 4))
        let frames = system.running.compactMap { system.list[$0.pid]?.first?.frame }
        #expect(frames == [CGRect(x: 12, y: 45, width: 1488, height: 925), gappedLeft, gappedRight, interior])
    }
    #expect(work.snapshot.members.first?.windows.first?.frame == usable)
}

@Test @MainActor func restoreWaitsForRevealAndTriesOneNonactivatingRaiseBeforePlacement() async {
    let system = WindowFixture()
    system.running = [liveApp("Editor", pid: 10, hidden: true), liveApp("Browser", pid: 20)]
    system.list[10] = [window(11, frame: window(1).frame), window(12, minimized: true, frame: window(2).frame)]
    system.list[20] = [window(21)]
    system.offSpace = [11, 12, 21]
    let target = saved(window(3))
    let work = preset([
        SavedApp(identity: identity("Editor"), windows: [saved(window(1)), saved(window(2))]),
        SavedApp(identity: identity("Browser"), windows: [target])
    ], focusedWindow: target.id)
    var polls: [String: Int] = [:]
    let restore = WorkspaceRestore(system: system, waitForVisibilityUpdate: {
        guard let action = system.events.last else { return }
        polls[action, default: 0] += 1
        guard polls[action] == 2 else { return }
        switch action {
        case "reveal Editor": system.offSpace.remove(11)
        case "unminimize 12": system.offSpace.remove(12)
        case "raise 21": system.offSpace.remove(21)
        default: break
        }
    })
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value
    #expect(result == RestoreReport(total: 3, placed: 3))
    #expect(polls == ["reveal Editor": 2, "unminimize 12": 2, "raise 21": 2])
    #expect(system.events == [
        "reveal Editor", "place 11", "unminimize 12", "place 12", "raise 11", "raise 12", "raise 21", "place 21", "focus 21"
    ])
}

@Test @MainActor func restoreDistinguishesUnavailableWindowsWithGenericDetailsAndNotifications() async throws {
    let system = WindowFixture()
    system.running = [liveApp("Editor", pid: 10), liveApp("Files", pid: 20), liveApp("Outside", pid: 30)]
    system.list[10] = [
        window(11), window(12),
        window(13), window(14, minimized: true)
    ]
    system.fullScreen = [11]
    system.unreadable = [12]
    system.offSpace = [13]
    let work = preset([
        SavedApp(identity: identity("Editor"), windows: (system.list[10] ?? []).map { saved($0) }),
        SavedApp(identity: identity("Files"), windows: [saved(window(22))])
    ])
    var preferences = Preferences()
    preferences.revealMembers = false
    let restore = WorkspaceRestore(system: system)
    var result: RestoreReport?
    await restore.request(work, preferences: preferences) { result = try? $0.get() }.value
    let report = try #require(result)
    #expect(report.total == 5)
    #expect(report.placed == 0)
    #expect(report.issues == [.fullScreen, .unreadable, .offScreen, .minimized, .missing])
    #expect(system.events.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func restoreDiscoversWindowsAfterUnhiding(partial: Bool) async {
    let system = WindowFixture()
    let first = window(11)
    let second = window(12)
    system.running = [liveApp("Editor", pid: 10, hidden: true)]
    system.list[10] = partial ? [first] : []
    system.withdrawnPIDs = [10]
    let work = preset([SavedApp(identity: identity("Editor"), windows: [saved(first), saved(second)])])
    var polls = 0
    let restore = WorkspaceRestore(system: system, waitForVisibilityUpdate: {
        polls += 1
        if polls == 2 { system.list[10] = [first, second] }
    })
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value

    #expect(result == RestoreReport(total: 2, placed: 2))
    #expect(polls == 2)
    #expect(system.events == ["reveal Editor", "place 11", "place 12", "raise 11", "raise 12", "focus 11"])
}

@Test(arguments: [false, true])
@MainActor func restoreDiscoversWithdrawnWindowsAndFocusesSavedWindow(partial: Bool) async {
    let system = WindowFixture()
    let first = window(11)
    let second = window(12)
    let last = window(21)
    let focused = saved(last)
    system.running = [
        liveApp("Editor", pid: 10), liveApp("Editor", pid: 11),
        liveApp("Browser", pid: 20), liveApp("Outside", pid: 30)
    ]
    system.withdrawnPIDs = [10, 20, 30]
    system.frontmostPID = 30
    system.list[10] = partial ? [first, first] : []
    system.list[20] = [last]
    let work = preset([
        SavedApp(identity: identity("Editor"), windows: [saved(first), saved(second)]),
        SavedApp(identity: identity("Browser"), windows: [focused])
    ], focusedWindow: focused.id)
    var polls = 0
    let restore = WorkspaceRestore(system: system, waitForVisibilityUpdate: {
        polls += 1
        if polls == 2 {
            system.list[10] = [first, first]
            system.list[11] = [second]
        }
    })
    var preferences = Preferences()
    preferences.launchMissing = false
    var result: RestoreReport?
    await restore.request(work, preferences: preferences) { result = try? $0.get() }.value

    #expect(result == RestoreReport(total: 3, placed: 3))
    #expect(polls == 2)
    #expect(system.events == [
        "reopen 10", "place 11", "place 12", "raise 11", "raise 12", "place 21",
        "raise 21", "hide Outside", "focus 21"
    ])
    #expect(system.frontmostPID == 20)
}

@Test(arguments: [false, true])
@MainActor func restoreReopensRunningWindowlessAppsAndConfirmsTheirWindows(useRex: Bool) async {
    let system = WindowFixture()
    let app = useRex ? rexApp(pid: 10) : liveApp("Editor", pid: 10)
    let slot = saved(window(1))
    let work = preset([SavedApp(identity: app.identity, windows: [slot])], focusedWindow: slot.id)
    system.running = [app]
    system.reopenRows = menuBackingRows(pid: app.pid)
    var polls = 0
    var pollsAfterReopen = 0
    let restore = WorkspaceRestore(system: system, waitForVisibilityUpdate: {
        polls += 1
        if system.events.last == "reopen 10" {
            pollsAfterReopen += 1
            if pollsAfterReopen == 2 { system.list[app.pid] = [window(11)] }
        }
    })
    var preferences = Preferences()
    preferences.revealMembers = false
    preferences.launchMissing = false
    var result: RestoreReport?
    await restore.request(work, preferences: preferences) { result = try? $0.get() }.value

    #expect(result?.issues == [.missing])
    #expect(system.events.isEmpty)
    #expect(polls == 0)

    preferences.revealMembers = true
    for _ in 0..<2 {
        result = nil
        await restore.request(work, preferences: preferences) { result = try? $0.get() }.value

        #expect(result == RestoreReport(total: 1, placed: 1))
        #expect(system.frame(for: 11) == slot.frame)
        #expect(system.restoreState(of: 11, in: app) == .visible)
        #expect(system.list[app.pid]?.map(\.handle) == [11])
        #expect(system.events.filter { $0 == "reopen 10" }.count == 1)
    }
    #expect(polls == 5)
    #expect(pollsAfterReopen == 2)
}

@Test(arguments: [false, true], [false, true])
@MainActor func reopenTimeoutKeepsOutsideAppsUntouched(focusChanged: Bool, windowless: Bool) async {
    let system = WindowFixture()
    system.running = [liveApp("Editor", pid: 10), liveApp("Outside", pid: 20), liveApp("Other", pid: 30)]
    if windowless {
        system.reopenRows = menuBackingRows(pid: 10)
    } else {
        system.withdrawnPIDs = [10, 20]
    }
    system.frontmostPID = 20
    let slots = (1...20).map { saved(window($0)) }
    let work = preset([SavedApp(identity: identity("Editor"), windows: slots)])
    var polls = 0
    let restore = WorkspaceRestore(system: system, waitForVisibilityUpdate: {
        polls += 1
        if focusChanged, system.events.last == "reopen 10" { system.frontmostPID = 30 }
    })
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value

    #expect(result?.placed == 0)
    #expect(result?.issues == Array(repeating: .missing, count: slots.count))
    #expect(polls == (windowless ? 13 : 10))
    #expect(system.events == (focusChanged ? ["reopen 10"] : ["reopen 10", "activate 20"]))
    #expect(system.frontmostPID == (focusChanged ? 30 : 20))
}

@Test @MainActor func restoreHonorsRevealOffAndFallsBackToActivationWhenInventoryIsUnavailable() async {
    let system = WindowFixture()
    system.running = [liveApp("Hidden", pid: 10, hidden: true), liveApp("Editor", pid: 20), liveApp("Closed", pid: 30)]
    system.frontmostPID = 20
    system.withdrawnPIDs = [20]
    let work = preset([
        SavedApp(identity: identity("Hidden"), windows: [saved(window(1))]),
        SavedApp(identity: identity("Editor"), windows: [saved(window(2))]),
        SavedApp(identity: identity("Closed"), windows: [saved(window(3))])
    ])
    var preferences = Preferences()
    preferences.revealMembers = false
    let restore = WorkspaceRestore(system: system)
    var result: RestoreReport?
    await restore.request(work, preferences: preferences) { result = try? $0.get() }.value

    #expect(result?.issues == [.hidden, .missing, .missing])
    #expect(system.events.isEmpty)

    let closedOnly = preset([SavedApp(identity: identity("Closed"), windows: [saved(window(3))])])
    await restore.request(closedOnly, preferences: Preferences()) { result = try? $0.get() }.value
    #expect(result?.issues == [.missing])
    #expect(system.events == ["activate 30", "activate 20"])
}

@Test(arguments: [false, true])
@MainActor func restoreWaitsForALateWindowBeforeReopening(hidden: Bool) async {
    let system = WindowFixture()
    let app = liveApp("Editor", pid: 10, hidden: hidden)
    let slot = saved(window(1))
    let work = preset([SavedApp(identity: app.identity, windows: [slot])])
    system.running = [app]
    system.reopenRows = menuBackingRows(pid: app.pid)
    var polls = 0
    let restore = WorkspaceRestore(system: system, waitForVisibilityUpdate: {
        polls += 1
        if polls == 3 { system.list[app.pid] = [window(11)] }
    })
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value

    #expect(result == RestoreReport(total: 1, placed: 1))
    #expect(system.frame(for: 11) == slot.frame)
    #expect(system.events == (hidden ? ["reveal Editor"] : []) + ["place 11", "raise 11", "focus 11"])
}

private enum WindowlessReopenBlocker: CaseIterable {
    case partialInventory, unavailableAXList, unavailableCompositor, unavailableServerRows
    case additionalInstance, unmanagedAXWindow, visibleServerSurface, newlyLaunched
}

@Test(arguments: WindowlessReopenBlocker.allCases)
@MainActor private func restoreSkipsWindowlessReopenWhenItCannotConfirmAbsence(_ blocker: WindowlessReopenBlocker) async {
    let system = WindowFixture()
    let app = liveApp("Editor", pid: 10)
    let live = window(11)
    let work = preset([SavedApp(identity: app.identity, windows: [saved(window(1)), saved(window(2))])])
    system.running = [app]
    system.reopenRows = menuBackingRows(pid: app.pid)
    switch blocker {
    case .partialInventory: system.list[app.pid] = [live]
    case .unavailableAXList: system.unavailableAXLists = [app.pid]
    case .unavailableCompositor: system.compositorAvailable = false
    case .unavailableServerRows: system.reopenRows = nil
    case .additionalInstance: system.running.append(liveApp("Editor", pid: 12))
    case .unmanagedAXWindow: system.otherAXWindows = [app.pid]
    case .visibleServerSurface: system.reopenRows?.append(windowServerRow(app.pid, CGRect(x: 0, y: 50, width: 200, height: 300)))
    case .newlyLaunched:
        system.running = []
        system.launches[app.identity.key] = (app, [])
    }
    let restore = WorkspaceRestore(system: system, launchTimeout: .zero, waitForVisibilityUpdate: {})
    var result: RestoreReport?
    await restore.request(work, preferences: Preferences()) { result = try? $0.get() }.value

    #expect(!system.events.contains("reopen 10"))
    #expect(!system.events.contains("reopen 12"))
    #expect(result?.placed == (blocker == .partialInventory ? 1 : 0))
    #expect(result?.issues == (blocker == .partialInventory ? [.missing] : [.missing, .missing]))
    #expect(system.events.contains("launch Editor") == (blocker == .newlyLaunched))
}

@Test @MainActor func cancellationBeforeWindowlessReopenSkipsRecoveryAndPlacement() async {
    let system = WindowFixture()
    let app = liveApp("Editor", pid: 10)
    let work = preset([SavedApp(identity: app.identity, windows: [saved(window(1))])])
    system.running = [app]
    system.reopenRows = menuBackingRows(pid: app.pid)
    let restore = WorkspaceRestore(system: system, waitForVisibilityUpdate: {
        withUnsafeCurrentTask { $0?.cancel() }
    })
    var completed = false
    await restore.request(work, preferences: Preferences()) { _ in completed = true }.value

    #expect(!completed)
    #expect(system.events.isEmpty)
}

@Test(arguments: [false, true])
@MainActor func cancellationDuringWindowDiscoveryStopsBeforePlacement(hidden: Bool) async {
    let system = WindowFixture()
    system.running = [liveApp("Editor", pid: 10, hidden: hidden), liveApp("Outside", pid: 20)]
    system.withdrawnPIDs = [10]
    system.frontmostPID = 20
    let work = preset([SavedApp(identity: identity("Editor"), windows: [saved(window(1))])])
    let restore = WorkspaceRestore(system: system, waitForVisibilityUpdate: {
        system.list[10] = [window(11)]
        withUnsafeCurrentTask { $0?.cancel() }
    })
    var completed = false
    await restore.request(work, preferences: Preferences()) { _ in completed = true }.value

    #expect(!completed)
    #expect(system.events == (hidden ? ["reveal Editor"] : ["reopen 10", "activate 20"]))
}

@Test @MainActor func cancellationDuringVisibilityRetrySkipsPlacementAndCompletion() async {
    let system = WindowFixture()
    system.running = [liveApp("Editor", pid: 10), liveApp("Outside", pid: 20)]
    system.list[10] = [window(11)]
    system.offSpace = [11]
    let work = preset([SavedApp(identity: identity("Editor"), windows: [saved(window(1))])])
    let restore = WorkspaceRestore(system: system, waitForVisibilityUpdate: {
        withUnsafeCurrentTask { $0?.cancel() }
    })
    var completed = false
    await restore.request(work, preferences: Preferences()) { _ in completed = true }.value
    #expect(!completed)
    #expect(system.events == ["raise 11"])
}

@Test @MainActor func errorLogIdentifiesFailingWindowsWithoutRecordingSuccessOrCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appending(path: ".awm.error.log")
    let store = WorkspaceStore(url: directory.appending(path: ".awm.yaml"))
    let logger = ErrorLog(url: log)
    let model = AppModel(store: store, errorLog: logger)
    model.set(\.animate, true)
    model.set(\.animate, true)
    #expect(!FileManager.default.fileExists(atPath: log.path))

    let system = WindowFixture()
    let app = liveApp("Editor", pid: 10)
    let savedIdentity = AppIdentity(bundleID: app.identity.bundleID, bundlePath: "/Private/Editor.app", name: nil)
    let title = "Draft \"one\"\nSecond line"
    let workspace = "Project \"notes\"\nMonday"
    system.running = [app]
    system.list[app.pid] = [window(11), window(22)]
    system.windowTitles = [11: title]
    let restore = WorkspaceRestore(system: system, errorLog: logger)
    let work = preset([SavedApp(identity: savedIdentity, windows: [saved(window(11)), saved(window(22))])],
                      name: workspace)
    var report: RestoreReport?
    await restore.request(work, preferences: Preferences()) { report = try? $0.get() }.value
    #expect(report == RestoreReport(total: 2, placed: 2))
    let cancelled = restore.request(work, preferences: Preferences()) { _ in
        Issue.record("Expected no completion after cancellation")
    }
    restore.cancel()
    await cancelled.value
    #expect(!FileManager.default.fileExists(atPath: log.path))
    #expect(system.titleReads.isEmpty)

    logger.record(.load, .invalidData)
    let firstRecord = try Data(contentsOf: log)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
    system.constrained = [11]
    system.restricted = [22]
    await restore.request(work, preferences: Preferences()) { report = try? $0.get() }.value
    #expect(report?.issues == [.constrained, .placementFailed])
    #expect(system.titleReads == [11, 22])
    system.running = []
    var keepClosed = Preferences()
    keepClosed.launchMissing = false
    await restore.request(work, preferences: keepClosed) { report = try? $0.get() }.value
    #expect(report?.issues == [.notRunning, .notRunning])
    #expect(system.titleReads == [11, 22])
    system.authorized = false
    await restore.request(work, preferences: Preferences()) { report = try? $0.get() }.value
    #expect(report == nil)
    logger.record(.shortcut, ShortcutError.duplicate("PRIVATE_SENTINEL_PRESET"))
    logger.record(.shortcut, ShortcutError.unavailable(-42))
    logger.record(.login, NSError(domain: "PRIVATE_SENTINEL_DOMAIN", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "PRIVATE_SENTINEL_PATH"]))
    logger.record(.save, CancellationError())
    let logText = try String(contentsOf: log, encoding: .utf8)
    let lines = logText.split(separator: "\n")
    #expect(logText.utf8.starts(with: firstRecord))
    #expect(!logText.contains("PRIVATE_SENTINEL"))
    #expect(!logText.contains("Private"))
    let entries = try lines.map {
        try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    #expect(entries.allSatisfy { ($0["timestamp"] as? String).flatMap { try? Date.ISO8601FormatStyle().parse($0) } != nil })
    #expect(entries.compactMap { $0["operation"] as? String } ==
            ["load", "restore", "restore", "restore", "restore", "restore", "shortcut", "shortcut", "login"])
    #expect(entries.compactMap { $0["reason"] as? String } ==
            ["invalidData", "constrained", "placementFailed", "notRunning", "notRunning",
             "permission", "shortcutConflict", "shortcutUnavailable", "unexpected"])
    let contexts = entries.compactMap { $0["context"] as? [String: String] }
    #expect(contexts == [
        ["workspace": workspace, "app": "Editor", "windowTitle": title, "windowSlot": "Window 1"],
        ["workspace": workspace, "app": "Editor", "windowSlot": "Window 2"],
        ["workspace": workspace, "app": "test.Editor", "windowSlot": "Window 1"],
        ["workspace": workspace, "app": "test.Editor", "windowSlot": "Window 2"],
        ["workspace": workspace],
    ])
    #expect(entries.first { ($0["reason"] as? String) == "shortcutUnavailable" }?["code"] as? Int == -42)
    #expect(try permissionMode(at: log) == 0o600)
}

@Test func errorLogRefusesSymbolicAndHardLinks() throws {
    try withStore { store in
        let parent = store.url.deletingLastPathComponent()
        let target = parent.appending(path: "target")
        let log = parent.appending(path: ".awm.error.log")
        let data = Data("original".utf8)
        try data.write(to: target)
        let fileManager = FileManager.default
        let logger = ErrorLog(url: log)
        try fileManager.createSymbolicLink(at: log, withDestinationURL: target)
        logger.record(.load, .invalidData)
        #expect(try Data(contentsOf: target) == data)
        try fileManager.removeItem(at: log)
        try fileManager.linkItem(at: target, to: log)
        logger.record(.load, .invalidData)
        #expect(try Data(contentsOf: target) == data)
    }
}

@Test @MainActor func privateBackupRestoresPortChangesAndAppsWithoutBundleIDs() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStore(url: directory.appending(path: ".awm.yaml"))
    let writer = AppIdentity(bundleID: nil, bundlePath: "/Custom/Writer.app", name: "PRIVATE_WRITER_NAME")
    let editor = AppIdentity(bundleID: nil, bundlePath: nil, name: "Name-only editor")
    let frame = CGRect(x: -900, y: 0, width: 900, height: 800)
    let old = display("old-port", frame: frame, uuid: "old-hardware", model: "one-model", serial: 42)
    let new = display("new-port", frame: frame, uuid: "new-hardware", model: "one-model", serial: 42)
    let savedFrame = frame.insetBy(dx: 30, dy: 30)
    let writerWindow = saved(window(1, frame: savedFrame), display: old)
    let editorWindow = saved(window(2))
    let layout = DisplayLayout(screens: [referenceDisplay, old])
    let captured = preset([SavedApp(identity: writer, windows: [writerWindow]),
                          SavedApp(identity: editor, windows: [editorWindow])],
                         focusedWindow: writerWindow.id, layout: layout)
    let initial = try store.load()
    var state = initial.state
    let savedPreset = try state.save(name: captured.name, snapshot: captured.snapshot)
    try state.associateDisplays(savedPreset.id, enabled: true)
    state.preferences.autoActivate = true
    _ = try store.write(state, replacing: initial)

    let backupURL = directory.appending(path: "backup.yaml")
    try FileManager.default.copyItem(at: store.url, to: backupURL)
    let backup = try WorkspaceStore(url: backupURL).load().state
    let salt = try #require(backup.displaySalt)
    let yaml = try String(contentsOf: backupURL, encoding: .utf8)
    #expect(!yaml.contains("PRIVATE_WRITER_NAME"))
    #expect(yaml.contains("/Custom/Writer.app"))
    #expect(yaml.contains("Name-only editor"))

    let system = WindowFixture()
    system.layout = DisplayLayout(screens: [new, referenceDisplay])
    system.running = [LiveApp(pid: 20, identity: editor, hidden: false)]
    system.list[20] = [window(22)]
    system.launches[writer.key] = (LiveApp(pid: 10, identity: writer, hidden: false), [window(11)])
    let mapped = try #require(backup.automaticPreset(for: system.layout))
    #expect(mapped.id == savedPreset.id)
    let restore = WorkspaceRestore(system: system)
    var report: RestoreReport?
    await restore.request(mapped, preferences: backup.preferences, salt: salt) {
        report = try? $0.get()
    }.value
    #expect(report == RestoreReport(total: 2, placed: 2))
    #expect(system.list[10]?.first?.frame == savedFrame)
    #expect(system.events.last == "focus 11")
}

@Test func collidingLegacyDisplayIDsLeaveYAMLIntact() throws {
    try withStore { store in
        var root = try #require(try JSONSerialization.jsonObject(with: privateStoreData(privacyFixture(), version: 6))
                                   as? [String: Any])
        var presets = try #require(root["presets"] as? [[String: Any]])
        var snapshot = try #require(presets[0]["snapshot"] as? [String: Any])
        var displays = try #require(snapshot["displays"] as? [String: Any])
        var screens = try #require(displays["screens"] as? [[String: Any]])
        screens[1]["id"] = screens[0]["id"]
        displays["screens"] = screens
        snapshot["displays"] = displays
        presets[0]["snapshot"] = snapshot
        root["presets"] = presets
        let bytes = try JSONSerialization.data(withJSONObject: root)
        try bytes.write(to: store.url)
        #expect(throws: WorkspaceError.invalidData) { try store.load() }
        #expect(try Data(contentsOf: store.url) == bytes)
    }
}

private func expectStored(_ actual: AppState, preserves source: AppState) throws {
    let salt = try #require(actual.displaySalt)
    #expect(actual.hasPrivateStorage)
    #expect(actual.version == AppState.currentFormat)
    #expect(actual.preferences == source.preferences)
    #expect(actual.shortcuts == source.shortcuts)
    #expect(actual.lastActive == source.lastActive)
    #expect(actual.presets.count == source.presets.count)
    for (stored, original) in zip(actual.presets, source.presets) {
        #expect(stored.id == original.id)
        #expect(stored.name == original.name)
        #expect(stored.icon == original.icon)
        #expect(stored.followsDisplays == original.followsDisplays)
        #expect((stored.associatedDisplays == nil) == (original.associatedDisplays == nil))
        if let storedLayout = stored.associatedDisplays, let originalLayout = original.associatedDisplays {
            #expect(storedLayout.matchesArrangement(originalLayout, salt: salt))
        }
        #expect(stored.snapshot.displays.matchesArrangement(original.snapshot.displays, salt: salt))
        #expect(stored.snapshot.focusedWindow == original.snapshot.focusedWindow)
        #expect(stored.snapshot.members.count == original.snapshot.members.count)
        for (actualMember, originalMember) in zip(stored.snapshot.members, original.snapshot.members) {
            #expect(actualMember.id == originalMember.id)
            #expect(actualMember.windows.count == originalMember.windows.count)
            for (actualWindow, originalWindow) in zip(actualMember.windows, originalMember.windows) {
                #expect(actualWindow.id == originalWindow.id)
                #expect(actualWindow.frame == originalWindow.frame)
                #expect(actualWindow.relativeFrame == originalWindow.relativeFrame)
                #expect(actualWindow.order == originalWindow.order)
                let sourceIndex = try #require(original.snapshot.displays.screens.firstIndex {
                    $0.id == originalWindow.displayID
                })
                #expect(stored.snapshot.displays.screens[sourceIndex].id == actualWindow.displayID)
            }
        }
    }
}

private func withStore<T>(_ operation: (WorkspaceStore) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try operation(WorkspaceStore(url: directory.appending(path: ".awm.yaml")))
}

private struct DiagnosticRecord: Decodable {
    struct Context: Decodable { let workspace: String? }

    let operation: String
    let reason: String
    let code: Int?
    let context: Context?
}

private func diagnosticRecords(at url: URL) throws -> [DiagnosticRecord] {
    let decoder = JSONDecoder()
    return try Data(contentsOf: url).split(separator: 0x0A).map { try decoder.decode(DiagnosticRecord.self, from: $0) }
}

private func permissionMode(at url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
}

private func privacyFixture() throws -> AppState {
    var state = AppState()
    let screen = display("PRIVATE_SENTINEL_RAW_ID", frame: referenceDisplay.frame,
                         usable: referenceDisplay.usable, primary: true, uuid: "PRIVATE_SENTINEL_UUID",
                         model: "PRIVATE_SENTINEL_MODEL", serial: 987654321)
    let slot = saved(window(1), display: screen)
    let chrome = AppIdentity(bundleID: "com.google.Chrome", bundlePath: "/PRIVATE_SENTINEL_PATH/Chrome.app", name: "Chrome")
    let writer = identity("Writer")
    let snapshot = WorkspaceSnapshot(displays: DisplayLayout(screens: [screen]), runningApps: [chrome, writer],
                                     members: [SavedApp(identity: chrome, windows: [slot])],
                                     focusedWindow: slot.id)
    let preset = try state.save(name: "Privacy fixture", snapshot: snapshot)
    try state.associateDisplays(preset.id, enabled: true)
    let extra = display("extra", frame: CGRect(x: -900, y: 0, width: 900, height: 800))
    let layout = DisplayLayout(screens: [screen, extra])
    try state.update(preset.id, snapshot: WorkspaceSnapshot(displays: layout, runningApps: [chrome, writer],
                                                            members: snapshot.members, focusedWindow: slot.id))
    let key = try #require(HotKey(code: UInt32(kVK_F17), modifiers: UInt32(cmdKey)))
    try state.assign(key, to: .preset(preset.id))
    state.lastActive = preset.id
    return state
}

private func privateStoreData(_ state: AppState, version: Int) throws -> Data {
    let encoded = try JSONEncoder().encode(state)
    var root = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    root["version"] = version
    root["unrelated"] = ["title": "annotation", "document": ["type": "note"]]
    var presets = try #require(root["presets"] as? [[String: Any]])
    var snapshot = try #require(presets[0]["snapshot"] as? [String: Any])
    var members = try #require(snapshot["members"] as? [[String: Any]])
    var windows = try #require(members[0]["windows"] as? [[String: Any]])
    windows[0]["identity"] = [
        "title": "PRIVATE_SENTINEL_TITLE",
        "document": "https://example.test/PRIVATE_SENTINEL_URL",
        "identifier": "PRIVATE_SENTINEL_ID"
    ]
    members[0]["windows"] = windows
    snapshot["members"] = members
    presets[0]["snapshot"] = snapshot
    root["presets"] = presets
    return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
}
