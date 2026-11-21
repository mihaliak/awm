import Darwin
import Foundation
import Yams

enum PresetMoveDirection: Int {
    case up = -1
    case down = 1
}

struct AppState: Codable, Equatable {
    static let currentFormat = 7

    var version = currentFormat
    var displaySalt: UUID?
    var presets: [Preset] = []
    var preferences = Preferences()
    var shortcuts = KeyboardBinding.defaults
    var lastActive: UUID?

    func preset(_ id: UUID) -> Preset? { presets.first { $0.id == id } }

    func index(ofPreset id: UUID) -> Int? { presets.firstIndex { $0.id == id } }

    func canMovePreset(_ id: UUID, direction: PresetMoveDirection) -> Bool {
        guard let index = index(ofPreset: id) else { return false }
        return neighbor(of: index, direction: direction) != nil
    }

    mutating func movePreset(_ id: UUID, direction: PresetMoveDirection) throws -> Bool {
        let index = try presetIndex(id)
        guard let destination = neighbor(of: index, direction: direction) else { return false }
        presets.swapAt(index, destination)
        return true
    }

    func automaticPreset(for display: DisplayLayout) -> Preset? {
        guard preferences.autoActivate else { return nil }
        return presets.first { $0.automaticLayout?.matchesArrangement(display, salt: displaySalt) == true }
    }

    mutating func save(name: String, snapshot: WorkspaceSnapshot, icon: WorkspaceIcon = .standard) throws -> Preset {
        let preset = Preset(id: UUID(), name: try validatedName(name), snapshot: snapshot, icon: icon)
        guard validSnapshot(snapshot) else { throw WorkspaceError.emptyCapture }
        presets.append(preset)
        return preset
    }

    mutating func rename(_ id: UUID, to name: String) throws {
        let index = try presetIndex(id)
        presets[index].name = try validatedName(name)
    }

    mutating func setIcon(_ icon: WorkspaceIcon, for id: UUID) throws {
        let index = try presetIndex(id)
        presets[index].icon = icon
    }

    mutating func update(_ id: UUID, snapshot: WorkspaceSnapshot) throws {
        let index = try presetIndex(id)
        guard validSnapshot(snapshot) else { throw WorkspaceError.emptyCapture }
        if let automatic = presets[index].automaticLayout {
            presets[index].associatedDisplays = automatic.matchesArrangement(snapshot.displays, salt: displaySalt) ? nil : automatic
        }
        presets[index].snapshot = snapshot
    }

    mutating func delete(_ id: UUID) throws {
        presets.remove(at: try presetIndex(id))
        shortcuts.removeAll { $0.action == .preset(id) }
        if lastActive == id { lastActive = nil }
    }

    mutating func associateDisplays(_ id: UUID, enabled: Bool) throws {
        let index = try presetIndex(id)
        let layout = presets[index].automaticLayout ?? presets[index].snapshot.displays
        if enabled {
            for i in presets.indices where i != index && presets[i].automaticLayout?.matchesArrangement(layout, salt: displaySalt) == true {
                presets[i].followsDisplays = false
                presets[i].associatedDisplays = nil
            }
        } else {
            presets[index].associatedDisplays = nil
        }
        presets[index].followsDisplays = enabled
    }

    mutating func assign(_ key: HotKey?, to action: ShortcutAction) throws {
        if let key, let conflict = shortcuts.first(where: { $0.key == key && $0.action != action }) {
            throw ShortcutError.duplicate(shortcutName(conflict.action))
        }
        shortcuts.removeAll { $0.action == action }
        if let key { shortcuts.append(KeyboardBinding(action: action, key: key)) }
    }

    mutating func resetWindowShortcuts() throws {
        var next = self
        next.shortcuts.removeAll {
            if case .arrange = $0.action { return true }
            return false
        }
        for binding in KeyboardBinding.defaults {
            try next.assign(binding.key, to: binding.action)
        }
        shortcuts = next.shortcuts
    }

    func shortcutName(_ action: ShortcutAction) -> String {
        switch action {
        case .arrange(let action): action.label
        case .preset(let id): preset(id)?.name ?? "Workspace"
        }
    }

    func forStorage(salt: UUID) throws -> Self {
        guard displaySalt == nil || displaySalt == salt else { throw WorkspaceError.invalidData }
        try validate()
        func privateLayout(_ layout: DisplayLayout) throws -> DisplayLayout {
            DisplayLayout(screens: try layout.screens.map { try $0.forStorage(salt: salt) })
        }
        var next = self
        next.displaySalt = salt
        next.presets = try presets.map { preset in
            let layout = try privateLayout(preset.snapshot.displays)
            let slots = Dictionary(uniqueKeysWithValues: zip(preset.snapshot.displays.screens.map(\.id),
                                                            layout.screens.map(\.id)))
            let members = try preset.snapshot.members.map { member in
                let windows = try member.windows.map { window in
                    guard let slot = slots[window.displayID] else { throw WorkspaceError.invalidData }
                    return SavedWindow(id: window.id, displayID: slot, frame: window.frame,
                                       relativeFrame: window.relativeFrame, order: window.order)
                }
                return SavedApp(identity: member.identity.forStorage, windows: windows)
            }
            var projected = preset
            projected.snapshot = WorkspaceSnapshot(displays: layout, members: members,
                                                   focusedWindow: preset.snapshot.focusedWindow)
            projected.associatedDisplays = try preset.associatedDisplays.map(privateLayout)
            return projected
        }
        return next
    }

    var hasPrivateStorage: Bool {
        displaySalt != nil && presets.allSatisfy { preset in
            preset.snapshot.runningApps == nil &&
                preset.snapshot.members.allSatisfy { $0.identity == $0.identity.forStorage } &&
                preset.snapshot.displays.screens.allSatisfy(\.hasPrivateIdentity) &&
                (preset.associatedDisplays?.screens.allSatisfy(\.hasPrivateIdentity) ?? true)
        }
    }

    var hasLegacyStorage: Bool {
        displaySalt == nil && presets.allSatisfy { preset in
            preset.snapshot.displays.screens.allSatisfy(\.hasRawIdentity) &&
                (preset.associatedDisplays?.screens.allSatisfy(\.hasRawIdentity) ?? true)
        }
    }

    func validate() throws {
        let ids = Set(presets.map(\.id))
        guard version == Self.currentFormat,
              ids.count == presets.count,
              lastActive.map(ids.contains) ?? true,
              preferences.isValid,
              Set(shortcuts.map(\.action)).count == shortcuts.count,
              Set(shortcuts.map(\.key)).count == shortcuts.count,
              shortcuts.allSatisfy({ binding in
                  if case .preset(let id) = binding.action { return ids.contains(id) }
                  return true
              }),
              presets.allSatisfy({
                  (try? validatedName($0.name)) == $0.name && validSnapshot($0.snapshot) &&
                      ($0.associatedDisplays.map { validLayout($0) } ?? true) &&
                      ($0.followsDisplays || $0.associatedDisplays == nil)
              })
        else { throw WorkspaceError.invalidData }

        let automatic = presets.compactMap(\.automaticLayout)
        for (index, layout) in automatic.enumerated() {
            guard !automatic.dropFirst(index + 1).contains(where: {
                $0.matchesArrangement(layout, salt: displaySalt)
            }) else { throw WorkspaceError.invalidData }
        }
    }

    private func presetIndex(_ id: UUID) throws -> Int {
        guard let index = index(ofPreset: id) else {
            throw WorkspaceError.missingPreset
        }
        return index
    }

    private func neighbor(of index: Int, direction: PresetMoveDirection) -> Int? {
        let destination = index + direction.rawValue
        return presets.indices.contains(destination) ? destination : nil
    }

    private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.name }
        return trimmed
    }

    private func validSnapshot(_ snapshot: WorkspaceSnapshot) -> Bool {
        let screenIDs = Set(snapshot.displays.screens.map(\.id))
        let windows = snapshot.members.flatMap(\.windows)
        let windowIDs = Set(windows.map(\.id))
        let inventory = snapshot.runningApps.map { Set($0.map(\.key)) }
        return validLayout(snapshot.displays) &&
            !windows.isEmpty && windowIDs.count == windows.count &&
            Set(snapshot.members.map(\.id)).count == snapshot.members.count &&
            inventory?.count == snapshot.runningApps?.count &&
            snapshot.members.allSatisfy {
                !$0.id.isEmpty && !$0.windows.isEmpty && (inventory?.contains($0.id) ?? true)
            } &&
            (snapshot.focusedWindow.map(windowIDs.contains) ?? true) &&
            windows.allSatisfy {
                $0.frame.isUsableWindowFrame && $0.relativeFrame.isUsableWindowFrame &&
                    screenIDs.contains($0.displayID) && $0.order >= 0
            }
    }

    private func validLayout(_ layout: DisplayLayout) -> Bool {
        let screens = layout.screens
        return screens.filter(\.primary).count == 1 && Set(screens.map(\.id)).count == screens.count &&
            screens.allSatisfy {
                !$0.id.isEmpty && $0.frame.isUsableWindowFrame && $0.usable.isUsableWindowFrame &&
                    $0.frame.contains($0.usable) && $0.scale.isFinite && $0.scale > 0
            }
    }
}

struct WorkspaceStore {
    struct Snapshot {
        let state: AppState
        fileprivate let bytes: Data
    }

    private static let legacyYAMLFormats = 5...6
    private static let privateWindowKeys = ["title", "document", "identifier"]

    let url: URL

    static var user: Self {
        Self(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".awm.yaml"))
    }

    func load(launchAtLogin: Bool = false) throws -> Snapshot {
        if let data = try read(url), try yamlVersion(data) == AppState.currentFormat {
            return try decodeYAML(data)
        }
        return try coordinate(url) { destination in
            if let data = try read(destination) {
                return try loadYAML(data, at: destination)
            }

            var state = AppState()
            state.preferences.launchAtLogin = launchAtLogin
            let snapshot = try encode(state)
            if try publish(snapshot.bytes, to: destination, replacing: nil) { return snapshot }
            guard let data = try read(destination) else { throw WorkspaceError.storageChanged }
            return try loadYAML(data, at: destination)
        }
    }

    func write(_ state: AppState, replacing previous: Snapshot) throws -> Snapshot {
        let snapshot = try encode(state, salt: previous.state.displaySalt)
        try coordinate(url) { destination in
            _ = try publish(snapshot.bytes, to: destination, replacing: previous.bytes)
        }
        return snapshot
    }

    private struct Header: Decodable { let version: Int }

    private func yamlVersion(_ data: Data) throws -> Int {
        guard let header = try? YAMLDecoder().decode(Header.self, from: data) else {
            throw WorkspaceError.invalidData
        }
        guard header.version <= AppState.currentFormat else { throw WorkspaceError.newerData(header.version) }
        return header.version
    }

    private func decodeYAML(_ data: Data, version: Int = AppState.currentFormat) throws -> Snapshot {
        guard var state = try? YAMLDecoder().decode(AppState.self, from: data), state.version == version
        else { throw WorkspaceError.invalidData }
        guard version == AppState.currentFormat ? state.hasPrivateStorage : state.hasLegacyStorage else {
            throw WorkspaceError.invalidData
        }
        state.version = AppState.currentFormat
        try state.validate()
        return Snapshot(state: state, bytes: data)
    }

    private func loadYAML(_ data: Data, at destination: URL) throws -> Snapshot {
        let version = try yamlVersion(data)
        guard version != AppState.currentFormat else { return try decodeYAML(data) }
        guard Self.legacyYAMLFormats.contains(version) else { throw WorkspaceError.invalidData }
        let before = try decodeYAML(data, version: version)
        if version == Self.legacyYAMLFormats.lowerBound {
            guard let source = String(data: data, encoding: .utf8), let root = try? compose(yaml: source) else {
                throw WorkspaceError.invalidData
            }
            try validateLegacyYAMLWindows(in: root, path: ["presets", "snapshot", "members", "windows"][...])
        }
        let migrated = try encode(before.state)
        _ = try publish(migrated.bytes, to: destination, replacing: before.bytes)
        return migrated
    }

    private func validateLegacyYAMLWindows(in node: Node, path: ArraySlice<String>) throws {
        if let sequence = node.sequence {
            for child in sequence { try validateLegacyYAMLWindows(in: child, path: path) }
            return
        }
        guard let mapping = node.mapping, !mapping.keys.contains(where: { $0.tag.rawValue == Tag.Name.merge.rawValue })
        else { throw WorkspaceError.invalidData }
        if let key = path.first {
            guard let child = mapping[key] else { throw WorkspaceError.invalidData }
            try validateLegacyYAMLWindows(in: child, path: path.dropFirst())
        } else if let identity = mapping["identity"] {
            guard let details = identity.mapping,
                  !details.keys.contains(where: { $0.tag.rawValue == Tag.Name.merge.rawValue }) else {
                throw WorkspaceError.invalidData
            }
            for key in Self.privateWindowKeys {
                if let value = details[key], value.tag.rawValue != Tag.Name.str.rawValue && value.null == nil {
                    throw WorkspaceError.invalidData
                }
            }
        }
    }

    private func encode(_ source: AppState, salt: UUID? = nil) throws -> Snapshot {
        let state = try source.forStorage(salt: salt ?? source.displaySalt ?? UUID())
        try state.validate()
        // JSON is a YAML subset. Preserve Foundation's round-trip decimal tokens
        // when emitting block YAML so fractional cycles and window positions stay exact.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(state), as: UTF8.self)
        guard let node = try compose(yaml: json) else { throw WorkspaceError.invalidData }
        let data = Data(try serialize(node: blockStyle(node), allowUnicode: true).utf8)
        let snapshot = try decodeYAML(data)
        guard snapshot.state == state else { throw WorkspaceError.invalidData }
        return snapshot
    }

    private func blockStyle(_ node: Node) -> Node {
        switch node {
        case .mapping(let mapping):
            Node(mapping.map { (blockStyle($0.key), blockStyle($0.value)) }, .implicit, .block)
        case .sequence(let sequence):
            Node(sequence.map(blockStyle), .implicit, .block)
        case .scalar(let scalar) where scalar.style == .doubleQuoted:
            .scalar(scalar.string.represented())
        default:
            node
        }
    }

    private func coordinate<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        var error: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) {
            destination in
            result = Result { try operation(destination) }
        }
        if let error { throw error }
        guard let result else { throw WorkspaceError.storageUnavailable }
        return try result.get()
    }

    private func read(_ source: URL) throws -> Data? {
        // Refuse symlinks and special files so a broken link never counts as a missing backup.
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw fileError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fileError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceError.invalidData }
        return try handle.readToEnd() ?? Data()
    }

    private func publish(_ bytes: Data, to destination: URL, replacing previous: Data?) throws -> Bool {
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".awm-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw fileError() }
        defer { _ = unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw fileError() }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        try handle.close()

        if let previous {
            guard try read(destination) == previous else { throw WorkspaceError.storageChanged }
            guard rename(temporary.path, destination.path) == 0 else { throw fileError() }
            return true
        }

        // Linking publishes the complete file atomically and cannot replace a concurrent creation.
        if link(temporary.path, destination.path) == 0 { return true }
        if errno == EEXIST { return false }
        throw fileError()
    }

    private func fileError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
