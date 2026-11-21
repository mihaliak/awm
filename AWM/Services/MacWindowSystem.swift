import AppKit
@preconcurrency import ApplicationServices

struct AXWindow: Hashable {
    let element: AXUIElement
    let pid: pid_t

    static func == (left: Self, right: Self) -> Bool {
        left.pid == right.pid && CFEqual(left.element, right.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(CFHash(element))
    }
}

enum WindowServerRows {
    static func composited(_ rows: [[String: Any]], excluding ownPID: pid_t) -> [CompositedWindow] {
        rows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? NSNumber, pid.int32Value != ownPID,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let frame = normalFrame(row) else { return nil }
            return CompositedWindow(pid: pid.int32Value, frame: frame)
        }
    }

    static func hasWithdrawnWindow(in rows: [[String: Any]], pid: pid_t, knownOffscreenFrames: [CGRect]) -> Bool {
        var knownFrames = knownOffscreenFrames
        return rows.contains { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowIsOnscreen as String] as? Bool) != true,
                  let frame = normalFrame(row),
                  // An app's menu bar backing surfaces can also have layer zero.
                  min(frame.width, frame.height) >= 48 else { return false }
            guard let match = knownFrames.firstIndex(where: { $0.isNear(frame, tolerance: 4) }) else { return true }
            knownFrames.remove(at: match)
            return false
        }
    }

    private static func normalFrame(_ row: [String: Any]) -> CGRect? {
        guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.isUsableWindowFrame
        else { return nil }
        return frame
    }
}

@MainActor
final class MacWindowSystem: WindowSystem {
    typealias Handle = AXWindow
    private let workspace = NSWorkspace.shared
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let systemWide = AXUIElementCreateSystemWide()
    private var pendingLaunches = Set<String>()

    init() {
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }

    var authorized: Bool { AXIsProcessTrusted() }

    static var permissionPaneName: String {
        if #available(macOS 27, *) { return "Device Control and Data Access" }
        return "Accessibility"
    }

    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
           workspace.open(url) {
            return
        }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func displays() -> DisplayLayout {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return DisplayLayout(screens: []) }
        return DisplayLayout(screens: screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = number.uint32Value
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let hardwareID = uuid.map { CFUUIDCreateString(nil, $0) as String }
            let model = "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id))"
            return DisplaySnapshot(
                id: hardwareID ?? "display-\(id)", uuid: hardwareID, model: model, serial: CGDisplaySerialNumber(id),
                name: screen.localizedName,
                frame: DisplayLayout.accessibilityRect(screen.frame, primaryTop: primary.frame.maxY),
                usable: DisplayLayout.accessibilityRect(screen.visibleFrame, primaryTop: primary.frame.maxY),
                scale: screen.backingScaleFactor, primary: screen === primary
            )
        })
    }

    func apps() -> [LiveApp] {
        workspace.runningApplications
            .filter { $0.processIdentifier != ownPID && $0.activationPolicy == .regular && !$0.isTerminated }
            .map(liveApp)
            .sorted { $0.pid < $1.pid }
    }

    func compositor() -> [CompositedWindow]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return WindowServerRows.composited(info, excluding: ownPID)
    }

    func windows(for app: LiveApp, on compositor: [CompositedWindow]?) -> [LiveWindow<AXWindow>] {
        let element = AXUIElementCreateApplication(app.pid)
        guard let elements = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var seen = Set<AXWindow>()
        let windows: [LiveWindow<AXWindow>] = elements.enumerated().compactMap { index, element in
            guard isManaged(element), let frame = frame(of: element) else { return nil }
            let window = AXWindow(element: element, pid: app.pid)
            guard seen.insert(window).inserted else { return nil }
            return LiveWindow(handle: window, frame: frame, order: index,
                              minimized: flag(element, kAXMinimizedAttribute), onScreen: false,
                              fullScreen: flag(element, "AXFullScreen"))
        }
        guard let compositor else { return windows }
        let hidden = NSRunningApplication(processIdentifier: app.pid)?.isHidden ?? app.hidden
        return LiveWindow.markOnScreen(windows, pid: app.pid, compositor: compositor, appHidden: hidden)
    }

    func restoreState(of window: AXWindow, in app: LiveApp) -> RestoreWindowState {
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated,
              let actual = frame(for: window) else { return .unreadable }
        // AXFullScreen is exposed by standard windows that support native full screen.
        if flag(window.element, "AXFullScreen") { return .fullScreen }
        if running.isHidden { return .hidden }
        if flag(window.element, kAXMinimizedAttribute) { return .minimized }
        guard let compositor = compositor() else { return .visibilityUnavailable }
        return compositor.contains { $0.pid == app.pid && actual.isNear($0.frame, tolerance: 4) }
            ? .visible : .offScreen
    }

    func focusedWindow(pid: pid_t?) -> AXWindow? {
        guard authorized, let pid = pid ?? workspace.frontmostApplication?.processIdentifier, pid != ownPID,
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular, !app.isHidden, !app.isTerminated
        else { return nil }
        let element = AXUIElementCreateApplication(pid)
        guard let value = attribute(element, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        guard isManaged(window), !flag(window, kAXMinimizedAttribute) else { return nil }
        return AXWindow(element: window, pid: pid)
    }

    func frame(for window: AXWindow) -> CGRect? { frame(of: window.element) }

    func windowTitle(for window: AXWindow) -> String? {
        guard let title = attribute(window.element, kAXTitleAttribute) as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }

    func app(pid: pid_t) -> LiveApp? {
        guard pid != ownPID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return nil
        }
        return liveApp(app)
    }

    func frontmostApp() -> LiveApp? {
        workspace.frontmostApplication.map(liveApp)
    }

    func activate(_ app: LiveApp) -> Bool {
        guard let running = runningApplication(for: app) else { return false }
        return activate(running)
    }

    func requestLaunch(_ app: AppIdentity) -> Bool {
        if pendingLaunches.contains(app.key) { return true }
        let located = app.bundleID.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        let saved = app.bundlePath.map { URL(fileURLWithPath: $0) }
        let url = located ?? saved
        guard let url, url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              app.bundleID == nil || bundle.bundleIdentifier == app.bundleID
        else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = false
        pendingLaunches.insert(app.key)
        workspace.openApplication(at: url, configuration: config) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.pendingLaunches.remove(app.key) }
        }
        return true
    }

    func requestReopen(_ app: LiveApp, knownWindows: [LiveWindow<AXWindow>]) -> Bool {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        // An ordered-out window may still have WindowServer bounds while absent from AXWindows.
        // Account for the minimized and off-Space windows AX already reported.
        let knownFrames = knownWindows.filter { !$0.onScreen }.map(\.frame)
        let hasWithdrawnWindow = WindowServerRows.hasWithdrawnWindow(in: entries, pid: app.pid, knownOffscreenFrames: knownFrames)
        guard hasWithdrawnWindow, let running = runningApplication(for: app),
              running.activationPolicy == .regular, !running.isHidden,
              let url = running.bundleURL, url.pathExtension.lowercased() == "app" else { return false }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        config.allowsRunningApplicationSubstitution = false
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        workspace.openApplication(at: url, configuration: config, completionHandler: nil)
        return true
    }

    func setApp(_ app: LiveApp, hidden: Bool) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return false }
        if running.isHidden == hidden { return true }
        return hidden ? running.hide() : running.unhide()
    }

    func setWindow(_ window: AXWindow, minimized: Bool) -> Bool {
        let element = window.element
        if flag(element, kAXMinimizedAttribute) == minimized { return true }
        let value = NSNumber(value: minimized)
        return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, value) == .success
    }

    func place(_ window: AXWindow, in target: CGRect, animate: Bool) async -> Placement {
        await place(window, at: .frame(target), animate: animate)
    }

    func place(_ window: AXWindow, at target: WindowTarget, animate: Bool) async -> Placement {
        let placement = WindowPlacement(
            readFrame: { self.frame(for: window) },
            setPosition: { self.setPosition(window.element, $0) },
            setSize: { self.setSize(window.element, $0) }
        )
        return await placement.place(target, animate: animate && !workspace.accessibilityDisplayShouldReduceMotion)
    }

    func raise(_ window: AXWindow, app: LiveApp, activate: Bool) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return false }
        let activated = !activate || self.activate(running)
        let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) == .success
        if activate {
            let application = AXUIElementCreateApplication(app.pid)
            _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window.element)
        }
        return raised && (activated || running.isActive)
    }

    private func liveApp(_ app: NSRunningApplication) -> LiveApp {
        LiveApp(pid: app.processIdentifier,
                identity: AppIdentity(bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.path,
                                      name: app.localizedName ?? app.bundleIdentifier ?? "Application"),
                hidden: app.isHidden)
    }

    private func runningApplication(for app: LiveApp) -> NSRunningApplication? {
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated,
              running.bundleIdentifier == app.identity.bundleID,
              running.bundleURL?.path == app.identity.bundlePath else { return nil }
        return running
    }

    private func activate(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14, *) {
            NSApp.yieldActivation(to: app)
            return app.activate(from: .current, options: [])
        }
        return app.activate(options: [.activateIgnoringOtherApps])
    }

    private func isManaged(_ window: AXUIElement) -> Bool {
        attribute(window, kAXRoleAttribute) as? String == kAXWindowRole &&
            attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute),
              let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions)
        else { return nil }
        let rect = CGRect(origin: origin, size: dimensions)
        return rect.isUsableWindowFrame ? rect : nil
    }

    private func setPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
        var origin = point
        guard let position = AXValueCreate(.cgPoint, &origin) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success
    }

    private func setSize(_ window: AXUIElement, _ size: CGSize) -> Bool {
        var size = size
        guard let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions) == .success
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func flag(_ element: AXUIElement, _ name: String) -> Bool {
        (attribute(element, name) as? NSNumber)?.boolValue ?? false
    }
}
