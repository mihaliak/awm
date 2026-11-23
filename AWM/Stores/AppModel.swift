import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = AppState()
    enum WindowControlStage {
        case required
        case confirmation
        case ready
    }

    @Published private(set) var windowControlStage: WindowControlStage = .required
    private(set) var restoringID: UUID?
    @Published private(set) var recording: ShortcutAction?
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var lastExternalPID: pid_t?

    let system: MacWindowSystem
    let hotkeys: GlobalShortcuts

    var authorized: Bool { windowControlStage != .required }
    var canSave: Bool { stored != nil }

    private let errorLog: ErrorLog
    private enum SetupProgress: String {
        case awaitingFirstGrant
        case finished
    }

    private static let setupProgressKey = "windowControlSetupProgress"
    private let setupDefaults: UserDefaults
    private let store: WorkspaceStore
    private var stored: WorkspaceStore.Snapshot?
    private let loginItem: LoginItem?
    private let restore: WorkspaceRestore<MacWindowSystem>
    private let focusObserver = FocusObserver()
    private var workspaceObservers: Set<AnyCancellable> = []
    private var cycles = WindowCycles<AXWindow>()
    private var layout = DisplayLayout(screens: [])
    private var displayWork: Task<Void, Never>?
    private var arrangeWork: (task: Task<Void, Never>, window: AXWindow)?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    #if DEBUG
    var verificationCapture: WorkspaceSnapshot?
    var verificationAuthorized = true
    var verificationRestore: ((UUID) -> Void)?
    #endif

    private var windowControlAuthorized: Bool {
        #if DEBUG
        if verificationCapture != nil { return verificationAuthorized }
        #endif
        return system.authorized
    }

    private var usesGlobalShortcuts: Bool {
        #if DEBUG
        return verificationCapture == nil
        #else
        return true
        #endif
    }

    init(store: WorkspaceStore = .user, loginItem: LoginItem? = nil, errorLog: ErrorLog? = nil,
         setupDefaults: UserDefaults = .standard) {
        self.store = store
        self.setupDefaults = setupDefaults
        self.loginItem = loginItem
        let errorLog = errorLog ?? ErrorLog(url: store.url.deletingLastPathComponent().appending(path: ".awm.error.log"))
        self.errorLog = errorLog
        let system = MacWindowSystem()
        self.system = system
        hotkeys = GlobalShortcuts()
        restore = WorkspaceRestore(system: system, errorLog: errorLog)
        do {
            let snapshot = try store.load(launchAtLogin: loginItem?.isRequested ?? false)
            stored = snapshot
            state = snapshot.state
        } catch {
            errorLog.record(.load, error)
        }
    }

    func start() {
        hotkeys.onAction = { [weak self] action in self?.performShortcut(action) }
        _ = hotkeys.start(state.shortcuts) { errorLog.record(.shortcut, $0) }
        focusObserver.onChange = { [weak self] in self?.syncFocus() }
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                Task { @MainActor [weak self] in self?.applicationActivated(pid) }
            }
            .store(in: &workspaceObservers)
        workspace.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                Task { @MainActor [weak self] in
                    guard let self, let pid else { return }
                    self.cycles.removeWindows { $0.pid == pid }
                }
            }
            .store(in: &workspaceObservers)
        layout = system.displays()
        refreshSystemState()
        syncLoginItem()
        if state.preferences.restoreOnLaunch, let active = state.lastActive {
            activate(active)
        }
    }

    func stop() {
        displayWork?.cancel()
        arrangeWork?.task.cancel()
        restore.cancel()
        hotkeys.stop()
        focusObserver.stop()
        workspaceObservers.removeAll()
    }

    func refreshSystemState() {
        updateWindowControl(trusted: windowControlAuthorized)
        if let loginItem { loginStatus = loginItem.status() }
        #if DEBUG
        if verificationCapture != nil { return }
        #endif
        applicationActivated(NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    private func updateWindowControl(trusted: Bool) {
        let progress: SetupProgress
        if let value = setupDefaults.string(forKey: Self.setupProgressKey),
           let recorded = SetupProgress(rawValue: value) {
            progress = recorded
        } else {
            // An already-authorized installation can continue directly to its workspaces.
            progress = trusted ? .finished : .awaitingFirstGrant
            setupDefaults.set(progress.rawValue, forKey: Self.setupProgressKey)
        }

        let stage: WindowControlStage
        if !trusted { stage = .required }
        else if progress == .awaitingFirstGrant { stage = .confirmation }
        else { stage = .ready }
        if stage != windowControlStage { windowControlStage = stage }
    }

    func finishWindowControlSetup() {
        // The grant may have been revoked while the confirmation was visible.
        refreshSystemState()
        guard windowControlStage == .confirmation else { return }
        setupDefaults.set(SetupProgress.finished.rawValue, forKey: Self.setupProgressKey)
        windowControlStage = .ready
    }

    func openPermissionSettings() {
        system.openPermissionSettings()
        refreshSystemState()
    }

    func watchAccessibility() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            if windowControlAuthorized != authorized { refreshSystemState() }
        }
    }

    func beginCapture(updating id: UUID?, pid: pid_t?) -> PresetCapture? {
        var capture: PresetCapture?
        let workspace = id.flatMap { state.preset($0)?.name }
        attempt(.capture, context: .init(workspace: workspace)) {
            guard canSave else { throw WorkspaceError.storageUnavailable }
            let previous = try id.map {
                guard let preset = state.preset($0) else { throw WorkspaceError.missingPreset }
                return preset
            }
            #if DEBUG
            let snapshot = try verificationCapture ?? system.capture(focusedPID: pid)
            #else
            let snapshot = try system.capture(focusedPID: pid)
            #endif
            capture = PresetCapture(snapshot, updating: previous, preferences: state.preferences, salt: state.displaySalt)
        }
        return capture
    }

    func saveCapture(_ capture: PresetCapture, name: String, selected: Set<UUID>, icon: WorkspaceIcon = .standard) -> Bool {
        let workspace: String? = switch capture.mode {
        case .save: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        case .update(let id, let previousName): state.preset(id)?.name ?? previousName
        }
        return attempt(.save, context: .init(workspace: workspace)) {
            guard windowControlAuthorized else { throw WorkspaceError.permission }
            let snapshot = capture.selecting(selected)
            var next = state
            switch capture.mode {
            case .save:
                _ = try next.save(name: name, snapshot: snapshot, icon: icon)
            case .update(let id, _):
                try next.update(id, snapshot: snapshot)
            }
            try commit(next)
        }
    }

    func rename(_ id: UUID, to name: String) -> Bool {
        attempt(.editPreset, context: .init(workspace: state.preset(id)?.name)) {
            var next = state
            try next.rename(id, to: name)
            try commit(next)
        }
    }

    func setIcon(_ icon: WorkspaceIcon, for id: UUID) -> Bool {
        attempt(.editPreset, context: .init(workspace: state.preset(id)?.name)) {
            var next = state
            try next.setIcon(icon, for: id)
            try commit(next)
        }
    }

    @discardableResult
    func movePreset(_ id: UUID, direction: PresetMoveDirection) -> Bool {
        attempt(.editPreset, context: .init(workspace: state.preset(id)?.name)) {
            var next = state
            if try next.movePreset(id, direction: direction) { try commit(next) }
        }
    }

    func delete(_ id: UUID) {
        attempt(.editPreset, context: .init(workspace: state.preset(id)?.name)) {
            var next = state
            try next.delete(id)
            try commit(next)
            if restoringID == id {
                restore.cancel()
                restoringID = nil
            }
        }
    }

    func associate(_ id: UUID, enabled: Bool) {
        attempt(.editPreset, context: .init(workspace: state.preset(id)?.name)) {
            var next = state
            try next.associateDisplays(id, enabled: enabled)
            try commit(next)
        }
    }

    func activate(_ id: UUID) {
        #if DEBUG
        if verificationCapture != nil {
            verificationRestore?(id)
            return
        }
        #endif
        guard let preset = state.preset(id) else { return }
        arrangeWork?.task.cancel()
        arrangeWork = nil
        cycles.resetEdge()
        restoringID = id
        restore.request(preset, preferences: state.preferences, salt: state.displaySalt) { [weak self] result in
            guard let self else { return }
            self.restoringID = nil
            if case .success(let report) = result, report.successful, self.state.lastActive != id {
                self.attempt(.restore, context: .init(workspace: preset.name)) {
                    var next = self.state
                    next.lastActive = id
                    try self.commit(next)
                }
            }
        }
    }

    func screensChanged() {
        if !layout.matchesArrangement(system.displays()) {
            cancelForDisplayChange()
        }
        displayWork?.cancel()
        displayWork = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self else { return }
            let actual = self.system.displays()
            let previous = self.layout
            self.layout = actual
            guard actual.primary != nil, !previous.matchesArrangement(actual) else { return }
            self.cancelForDisplayChange()
            if let preset = self.state.automaticPreset(for: actual) {
                self.activate(preset.id)
            }
        }
    }

    private func cancelForDisplayChange() {
        cycles.resetEdge()
        if let arrangeWork {
            arrangeWork.task.cancel()
            self.arrangeWork = nil
            errorLog.record(.arrange, .displaysChanged,
                            context: arrangementContext(pid: arrangeWork.window.pid, window: arrangeWork.window))
        }
        if let restoringID {
            restore.cancel()
            self.restoringID = nil
            errorLog.record(.restore, .displaysChanged, context: .init(workspace: state.preset(restoringID)?.name))
        }
    }

    @discardableResult
    func set<Value: Equatable>(_ path: WritableKeyPath<Preferences, Value>, _ value: Value) -> Bool {
        guard state.preferences[keyPath: path] != value else { return true }
        return attempt(.preferences) {
            let previous = state.preferences
            var next = state
            next.preferences[keyPath: path] = value
            try commit(next)
            if previous.edgeCycles != next.preferences.edgeCycles {
                cycles.resetEdge()
            }
        }
    }

    func saveCycle(_ text: String, at path: WritableKeyPath<Preferences, [WindowFraction]>) -> [WindowFraction]? {
        let entries = text.split(separator: ",", omittingEmptySubsequences: false)
        let parsed = entries.compactMap { WindowFraction(text: String($0)) }
        guard parsed.count == entries.count, (1...12).contains(parsed.count) else {
            errorLog.record(.preferences, .invalidData)
            return nil
        }
        return set(path, parsed) ? parsed : nil
    }

    func setLogin(_ enabled: Bool) {
        guard loginItem != nil else { return }
        if state.preferences.launchAtLogin != enabled {
            guard attempt(.login, {
                var next = state
                next.preferences.launchAtLogin = enabled
                try commit(next)
            }) else { return }
        }
        syncLoginItem()
    }

    func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func shortcut(for action: ShortcutAction) -> HotKey? {
        state.shortcuts.first { $0.action == action }?.key
    }

    func beginRecording(_ action: ShortcutAction) {
        recording = action
        hotkeys.beginRecording { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let key):
                if self.assign(key, to: action) { self.stopRecording() }
            case .failure(let error):
                self.errorLog.record(.shortcut, error)
            case nil:
                self.stopRecording()
            }
        }
    }

    func stopRecording() {
        hotkeys.stopRecording()
        recording = nil
    }

    @discardableResult
    func assign(_ key: HotKey?, to action: ShortcutAction) -> Bool {
        attempt(.shortcut) {
            var next = state
            try next.assign(key, to: action)
            if usesGlobalShortcuts, let key, state.shortcuts.contains(KeyboardBinding(action: action, key: key)) {
                try hotkeys.retry(KeyboardBinding(action: action, key: key))
            }
            try commit(next)
        }
    }

    func resetShortcuts() {
        attempt(.shortcut) {
            var next = state
            try next.resetWindowShortcuts()
            try commit(next, requiring: Set(KeyboardBinding.defaults.map(\.action)))
        }
    }

    private func performShortcut(_ action: ShortcutAction) {
        switch action {
        case .arrange(let action):
            arrange(action)
        case .preset(let id):
            activate(id)
        }
    }

    private func arrange(_ action: ArrangementAction) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedPID = frontmost == ownPID ? lastExternalPID : frontmost
        guard system.authorized else {
            updateWindowControl(trusted: false)
            errorLog.record(.arrange, WorkspaceError.permission, context: arrangementContext(pid: focusedPID))
            return
        }
        let focusedWindow = system.focusedWindow(pid: focusedPID)
        guard let window = focusedWindow, let frame = system.frame(for: window) else {
            errorLog.record(.arrange, .noFocusedWindow, context: arrangementContext(pid: focusedPID, window: focusedWindow))
            return
        }
        guard let screen = system.displays().display(for: frame) else {
            errorLog.record(.arrange, .displays, context: arrangementContext(pid: window.pid, window: window))
            return
        }
        if restoringID != nil {
            restore.cancel()
            restoringID = nil
        }
        arrangeWork?.task.cancel()
        let prefs = state.preferences
        let target = cycles.target(action, window: window, frame: frame, usable: screen.usable, preferences: prefs)
        let task = Task { [weak self] in
            guard let self else { return }
            let placement = await self.system.place(window, at: target, animate: prefs.animate)
            guard !Task.isCancelled else { return }
            self.arrangeWork = nil
            switch placement {
            case .exact, .gapAdjusted: break
            case .constrained:
                self.errorLog.record(.arrange, .constrained, context: self.arrangementContext(pid: window.pid, window: window))
            case .unavailable:
                self.errorLog.record(.arrange, .placementFailed, context: self.arrangementContext(pid: window.pid, window: window))
            }
        }
        arrangeWork = (task, window)
    }

    private func arrangementContext(pid: pid_t?, window: AXWindow? = nil) -> ErrorLog.Context {
        guard errorLog.isEnabled else { return .init() }
        let app = (window?.pid ?? pid).flatMap(system.app(pid:))
        return .init(app: app?.identity.diagnosticName, windowTitle: window.flatMap(system.windowTitle(for:)),
                     windowSlot: window.map { _ in "Focused window" })
    }

    private func applicationActivated(_ pid: pid_t?) {
        if let pid, pid != ownPID {
            let changed = lastExternalPID != pid
            lastExternalPID = pid
            if changed { cycles.focusChanged(to: nil) }
        }
        if authorized { focusObserver.watch(lastExternalPID) }
        else { focusObserver.stop() }
        syncFocus()
    }

    private func syncFocus() {
        cycles.focusChanged(to: system.focusedWindow(pid: lastExternalPID))
    }

    private func commit(_ next: AppState, requiring actions: Set<ShortcutAction> = []) throws {
        guard let previous = stored else { throw WorkspaceError.storageUnavailable }
        func persist() throws {
            stored = try store.write(next, replacing: previous)
        }
        if usesGlobalShortcuts && (next.shortcuts != state.shortcuts || !actions.isEmpty) {
            try hotkeys.apply(next.shortcuts, requiring: actions, persist: persist)
        } else {
            try persist()
        }
        if let stored { state = stored.state }
    }

    private func syncLoginItem() {
        guard let loginItem, canSave else { return }
        attempt(.login) { try loginItem.apply(state.preferences.launchAtLogin) }
        loginStatus = loginItem.status()
    }

    @discardableResult
    private func attempt(_ operation: ErrorLog.Operation, context: ErrorLog.Context = .init(),
                         _ action: () throws -> Void) -> Bool {
        do {
            try action()
            return true
        } catch {
            errorLog.record(operation, error, context: context)
            return false
        }
    }
}
