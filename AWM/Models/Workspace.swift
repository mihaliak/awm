import Foundation

struct AppIdentity: Codable, Equatable {
    let bundleID: String?
    let bundlePath: String?
    private let storedName: String?

    private enum CodingKeys: String, CodingKey { case bundleID, bundlePath, storedName = "name" }

    init(bundleID: String?, bundlePath: String?, name: String?) {
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        storedName = name
    }

    var name: String { storedName ?? key }
    var key: String { bundleID ?? bundlePath ?? storedName ?? "" }

    var diagnosticName: String? {
        if let storedName, !storedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedName
        }
        if let bundleID { return bundleID }
        return bundlePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }

    var forStorage: Self {
        if let bundleID { return Self(bundleID: bundleID, bundlePath: nil, name: nil) }
        if let bundlePath { return Self(bundleID: nil, bundlePath: bundlePath, name: nil) }
        return self
    }

}

struct SavedWindow: Codable, Equatable, Identifiable {
    let id: UUID
    let displayID: String
    let frame: CGRect
    let relativeFrame: CGRect
    let order: Int
}

struct SavedApp: Codable, Equatable, Identifiable {
    let identity: AppIdentity
    let windows: [SavedWindow]

    var id: String { identity.key }

    func windowLabel(for window: SavedWindow) -> String {
        guard let index = windows.firstIndex(where: { $0.id == window.id }) else { return "Window" }
        return "Window \(index + 1)"
    }
}

struct WorkspaceSnapshot: Codable, Equatable {
    let displays: DisplayLayout
    // Historical inventory. New captures only record the selected members.
    var runningApps: [AppIdentity]? = nil
    let members: [SavedApp]
    let focusedWindow: UUID?

    var windowCount: Int { members.reduce(0) { $0 + $1.windows.count } }
}

enum WorkspaceIcon: String, Codable, CaseIterable, Identifiable {
    case layout, code, video, book, pencil, photo, music, terminal, folder, globe, chart, star

    static let standard: Self = .layout

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .layout: "rectangle.split.2x1"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .video: "video"
        case .book: "book"
        case .pencil: "pencil"
        case .photo: "photo"
        case .music: "music.note"
        case .terminal: "terminal"
        case .folder: "folder"
        case .globe: "globe"
        case .chart: "chart.bar"
        case .star: "star"
        }
    }

    var title: String {
        switch self {
        case .layout: "Layout"
        case .code: "Code"
        case .video: "Video"
        case .book: "Book"
        case .pencil: "Pencil"
        case .photo: "Photo"
        case .music: "Music"
        case .terminal: "Terminal"
        case .folder: "Folder"
        case .globe: "Globe"
        case .chart: "Chart"
        case .star: "Star"
        }
    }
}

struct Preset: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var snapshot: WorkspaceSnapshot
    var followsDisplays: Bool
    var associatedDisplays: DisplayLayout?
    var icon: WorkspaceIcon

    private enum CodingKeys: String, CodingKey { case id, name, snapshot, followsDisplays, associatedDisplays, icon }

    init(id: UUID, name: String, snapshot: WorkspaceSnapshot, followsDisplays: Bool = false,
         associatedDisplays: DisplayLayout? = nil, icon: WorkspaceIcon = .standard) {
        self.id = id
        self.name = name
        self.snapshot = snapshot
        self.followsDisplays = followsDisplays
        self.associatedDisplays = associatedDisplays
        self.icon = icon
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        snapshot = try container.decode(WorkspaceSnapshot.self, forKey: .snapshot)
        followsDisplays = try container.decode(Bool.self, forKey: .followsDisplays)
        associatedDisplays = try container.decodeIfPresent(DisplayLayout.self, forKey: .associatedDisplays)
        icon = (try? container.decode(WorkspaceIcon.self, forKey: .icon)) ?? .standard
    }

    var automaticLayout: DisplayLayout? {
        followsDisplays ? associatedDisplays ?? snapshot.displays : nil
    }
}

struct LiveApp: Equatable {
    let pid: pid_t
    let identity: AppIdentity
    let hidden: Bool
}

struct LiveWindow<Handle: Hashable> {
    let handle: Handle
    let frame: CGRect?
    let order: Int
    var minimized: Bool
    var onScreen: Bool
    var fullScreen = false
}

enum WorkspaceError: LocalizedError, Equatable {
    case permission, displays, visibility, emptyCapture, name, missingPreset, invalidData
    case newerData(Int)
    case storageUnavailable, storageChanged

    var errorDescription: String? {
        switch self {
        case .permission: "Allow window control in System Settings."
        case .displays: "No usable display is available."
        case .visibility: "macOS did not return the visible window list."
        case .emptyCapture: "No visible, supported windows to save."
        case .name: "Enter a workspace name."
        case .missingPreset: "This workspace is no longer available."
        case .invalidData: "Saved workspace data could not be read."
        case .newerData(let version): "Saved data requires a newer version of Another Window Management (format \(version))."
        case .storageUnavailable: "Another Window Management can’t save changes while its data file is unavailable."
        case .storageChanged: "The workspace data file changed on disk. Quit and reopen Another Window Management to load it."
        }
    }
}
