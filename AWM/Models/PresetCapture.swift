import Foundation

struct PresetCapture {
    enum Mode {
        case save
        case update(id: UUID, name: String)

        var action: String {
            switch self {
            case .save: "Save"
            case .update: "Update"
            }
        }
    }

    let mode: Mode
    let snapshot: WorkspaceSnapshot
    let initialSelection: Set<UUID>
    let initialIcon: WorkspaceIcon

    init(_ snapshot: WorkspaceSnapshot, updating preset: Preset? = nil, preferences: Preferences, salt: UUID? = nil) {
        self.snapshot = snapshot
        initialIcon = preset?.icon ?? .standard
        guard let preset else {
            mode = .save
            initialSelection = Set(snapshot.members.flatMap(\.windows).map(\.id))
            return
        }
        mode = .update(id: preset.id, name: preset.name)
        let original = preset.snapshot.displays
        let destinations = snapshot.displays.destinations(from: original, salt: salt)
        let previous = Dictionary(uniqueKeysWithValues: preset.snapshot.members.map { ($0.id, $0.windows) })
        var selected = Set<UUID>()
        for member in snapshot.members {
            guard let saved = previous[member.id] else { continue }
            let targets = snapshot.displays.targets(for: saved, from: original, destinations: destinations,
                                                    preferences: preferences, salt: salt)
            let available = member.windows.map {
                LiveWindow(handle: $0.id, frame: $0.frame, order: $0.order, minimized: false, onScreen: true)
            }
            selected.formUnion(WorkspaceMatching.windows(saved, with: available, targets: targets.mapValues(\.frame))
                .map(\.live.handle))
        }
        initialSelection = selected
    }

    func selecting(_ ids: Set<UUID>) -> WorkspaceSnapshot {
        let members = snapshot.members.compactMap { member -> SavedApp? in
            let windows = member.windows.filter { ids.contains($0.id) }
            return windows.isEmpty ? nil : SavedApp(identity: member.identity, windows: windows)
        }
        return WorkspaceSnapshot(displays: snapshot.displays, members: members,
                                 focusedWindow: snapshot.focusedWindow.flatMap { ids.contains($0) ? $0 : nil })
    }

    func location(of window: SavedWindow) -> String {
        guard let display = snapshot.displays.screens.first(where: { $0.id == window.displayID }) else { return "" }
        let format = FloatingPointFormatStyle<CGFloat>().precision(.fractionLength(0))
        let x = (window.frame.minX - display.frame.minX).formatted(format)
        let y = (window.frame.minY - display.frame.minY).formatted(format)
        let width = window.frame.width.formatted(format)
        let height = window.frame.height.formatted(format)
        return "\(display.name) · (\(x), \(y)) · \(width) × \(height) pt"
    }
}
