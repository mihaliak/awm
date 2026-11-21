import Foundation
@testable import AWM

let defaultBounds = CGRect(x: 0, y: 0, width: 1200, height: 900)
let defaultUsable = CGRect(x: 0, y: 25, width: 1200, height: 825)

func display(_ id: String, frame: CGRect = defaultBounds, usable: CGRect? = nil,
             primary: Bool = false, scale: CGFloat = 1, uuid: String? = nil, model: String? = nil, serial: UInt32 = 0) -> DisplaySnapshot {
    DisplaySnapshot(id: id, uuid: uuid, model: model ?? id, serial: serial, name: id, frame: frame, usable: usable ?? frame,
                    scale: scale, primary: primary)
}

let referenceDisplay = display("built-in", usable: defaultUsable, primary: true, scale: 2)
let referenceLayout = DisplayLayout(screens: [referenceDisplay])

func identity(_ name: String) -> AppIdentity {
    AppIdentity(bundleID: "test.\(name)", bundlePath: nil, name: name)
}

func liveApp(_ name: String, pid: pid_t, hidden: Bool = false) -> LiveApp {
    LiveApp(pid: pid, identity: identity(name), hidden: hidden)
}

func window(_ index: Int, minimized: Bool = false, visible: Bool = true, frame: CGRect? = nil,
            order: Int? = nil) -> LiveWindow<Int> {
    LiveWindow(handle: index, frame: frame ?? CGRect(x: 30 * index, y: 50, width: 360, height: 400),
               order: order ?? index,
               minimized: minimized, onScreen: visible && !minimized)
}

func saved(_ from: LiveWindow<Int>, display: DisplaySnapshot = referenceDisplay) -> SavedWindow {
    SavedWindow(id: UUID(), displayID: display.id, frame: from.frame,
                relativeFrame: from.frame.relative(to: display.usable), order: from.order)
}

func preset(_ members: [SavedApp], focusedWindow: UUID? = nil, layout: DisplayLayout = referenceLayout,
            name: String = "Work") -> Preset {
    Preset(id: UUID(), name: name, snapshot: WorkspaceSnapshot(displays: layout,
        members: members, focusedWindow: focusedWindow))
}

@MainActor
final class WindowFixture: WindowSystem {
    var authorized = true
    var layout = referenceLayout
    var running: [LiveApp] = []
    var list: [pid_t: [LiveWindow<Int>]] = [:]
    var focus: Int?
    var windowTitles: [Int: String] = [:]
    var titleReads: [Int] = []
    var frontmostPID: pid_t?
    var compositorAvailable = true
    var offSpace: Set<Int> = []
    var fullScreen: Set<Int> = []
    var unreadable: Set<Int> = []
    var restricted: Set<Int> = []
    var constrained: Set<Int> = []
    var canReveal = true
    var launches: [String: (LiveApp, [LiveWindow<Int>])] = [:]
    var unresolvedLaunches: Set<String> = []
    var withdrawnPIDs: Set<pid_t> = []
    var events: [String] = []
    var onLaunch: (() -> Void)?

    func displays() -> DisplayLayout { layout }
    func apps() -> [LiveApp] { running }
    func compositor() -> [CompositedWindow]? {
        guard compositorAvailable else { return nil }
        return running.filter { !$0.hidden }.flatMap { app in
            (list[app.pid] ?? []).filter { $0.onScreen && !$0.minimized && !offSpace.contains($0.handle) }
                .map { CompositedWindow(pid: app.pid, frame: $0.frame) }
        }
    }

    func windows(for app: LiveApp, on compositor: [CompositedWindow]?) -> [LiveWindow<Int>] {
        let windows = (list[app.pid] ?? []).map { window in
            var result = window
            result.onScreen = false
            result.fullScreen = fullScreen.contains(window.handle)
            return result
        }
        guard let compositor else { return windows }
        return LiveWindow.markOnScreen(windows, pid: app.pid, compositor: compositor,
                                       appHidden: running.first { $0.pid == app.pid }?.hidden ?? app.hidden)
    }

    func restoreState(of window: Int, in app: LiveApp) -> RestoreWindowState {
        guard !unreadable.contains(window),
              let entry = list[app.pid]?.first(where: { $0.handle == window }),
              let current = running.first(where: { $0.pid == app.pid }) else { return .unreadable }
        if fullScreen.contains(window) { return .fullScreen }
        if current.hidden { return .hidden }
        if entry.minimized { return .minimized }
        guard let compositor = compositor() else { return .visibilityUnavailable }
        return windows(for: app, on: compositor).contains { $0.handle == window && $0.onScreen } ? .visible : .offScreen
    }

    func focusedWindow(pid: pid_t?) -> Int? { focus }

    func windowTitle(for window: Int) -> String? {
        titleReads.append(window)
        return windowTitles[window]
    }

    func frontmostApp() -> LiveApp? { running.first { $0.pid == frontmostPID } }

    func activate(_ app: LiveApp) -> Bool {
        guard running.contains(where: { $0.pid == app.pid && $0.identity == app.identity }) else { return false }
        events.append("activate \(app.pid)")
        frontmostPID = app.pid
        return true
    }

    func requestLaunch(_ app: AppIdentity) -> Bool {
        events.append("launch \(app.name)")
        onLaunch?()
        if let (app, windows) = launches.removeValue(forKey: app.key) {
            running.append(app)
            list[app.pid] = windows
            return true
        }
        return unresolvedLaunches.contains(app.key)
    }

    func requestReopen(_ app: LiveApp, knownWindows: [LiveWindow<Int>]) -> Bool {
        guard withdrawnPIDs.contains(app.pid) else { return false }
        events.append("reopen \(app.pid)")
        frontmostPID = app.pid
        return true
    }

    func setApp(_ app: LiveApp, hidden: Bool) -> Bool {
        events.append("\(hidden ? "hide" : "reveal") \(app.identity.name)")
        guard canReveal || hidden, let index = running.firstIndex(where: { $0.pid == app.pid }) else { return false }
        running[index] = LiveApp(pid: app.pid, identity: app.identity, hidden: hidden)
        return true
    }

    func setWindow(_ window: Int, minimized: Bool) -> Bool {
        events.append("\(minimized ? "minimize" : "unminimize") \(window)")
        guard !restricted.contains(window), let (pid, index) = locate(window) else { return false }
        list[pid]?[index].minimized = minimized
        list[pid]?[index].onScreen = !minimized
        return true
    }

    func place(_ window: Int, in frame: CGRect, animate: Bool) async -> Placement {
        events.append("place \(window)")
        guard !restricted.contains(window), let (pid, index) = locate(window),
              let entry = list[pid]?[index] else { return .unavailable }
        list[pid]?[index] = LiveWindow(handle: window, frame: frame, order: entry.order,
                                      minimized: entry.minimized, onScreen: entry.onScreen)
        return constrained.contains(window) ? .constrained : .exact
    }

    func raise(_ window: Int, app: LiveApp, activate: Bool) -> Bool {
        events.append("\(activate ? "focus" : "raise") \(window)")
        if activate { frontmostPID = app.pid }
        return true
    }

    private func locate(_ window: Int) -> (pid_t, Int)? {
        for (pid, windows) in list {
            if let index = windows.firstIndex(where: { $0.handle == window }) { return (pid, index) }
        }
        return nil
    }
}
