import AppKit
import ApplicationServices

enum AWMIdentity {
    static let displayName = "Another Window Management"
    static let statusItemName = "AWM"
}

@main
@MainActor
enum AWMApp {
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--accessibility-status") {
            print("Accessibility granted: \(AXIsProcessTrusted())")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var status: StatusPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["AWM_HOSTED_TESTS"] == "1" { return }
        let arguments = ProcessInfo.processInfo.arguments
        let captureWebsite = arguments.contains("--capture-website")
        let capturePreview = arguments.contains("--capture-design-preview")
        if captureWebsite || capturePreview || arguments.contains("--verify-menu-bar") {
            Task {
                do {
                    if captureWebsite {
                        guard let index = arguments.firstIndex(of: "--capture-website"),
                              let path = arguments.dropFirst(index + 1).first else {
                            throw CocoaError(.fileWriteInvalidFileName)
                        }
                        try await Self.verifyFirstSetup(screenshots: URL(fileURLWithPath: path, isDirectory: true))
                    } else if capturePreview {
                        guard let index = arguments.firstIndex(of: "--capture-design-preview"),
                              let path = arguments.dropFirst(index + 1).first else {
                            throw CocoaError(.fileWriteInvalidFileName)
                        }
                        try await Self.captureDesignPreview(in: URL(fileURLWithPath: path, isDirectory: true))
                    } else {
                        let environment = ProcessInfo.processInfo.environment
                        let reduceMotion = switch environment["AWM_VERIFY_REDUCE_MOTION"] {
                        case "0": false
                        case "1": true
                        default: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        }
                        let snapshots = environment["AWM_VERIFY_SNAPSHOT_DIRECTORY"].map {
                            URL(fileURLWithPath: $0, isDirectory: true)
                        }
                        try await Self.verifyMenuBar(reduceMotion: reduceMotion, snapshots: snapshots)
                    }
                    NSApp.terminate(nil)
                } catch {
                    print("Menu bar check failed: \(error.localizedDescription)")
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        #endif

        let model = AppModel(loginItem: .system)
        self.model = model
        status = StatusPopover(model: model)
        model.start()
    }

    #if DEBUG
    static func verifyMenuBar(reduceMotion: Bool, snapshots: URL? = nil) async throws {
        let fixture = try MenuFixture()
        defer { fixture.remove() }
        let longName = "Planning across all the displays for the design and engineering teams"
        let focus = try fixture.addWorkspaces(thirdName: longName, includeShortcut: true)
        let model = fixture.makeModel(authorized: true)
        var handoffActions: [StatusPopover.VerificationHandoff] = []
        let status = StatusPopover(model: model, windowControl: WindowControlHandoff(
            openSettings: { handoffActions.append(.settings) },
            revealApplication: { handoffActions.append(.finder($0)) }
        ), reduceMotion: { reduceMotion })
        defer { status.uninstall() }
        try await status.verify(store: fixture.store, focus: focus, longName: longName,
                                snapshots: snapshots, handoffs: { handoffActions })
    }

    static func verifyFirstSetup(screenshots: URL? = nil, designPreview: Bool = false) async throws {
        if let screenshots {
            try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        }
        let fixture = try MenuFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel(authorized: false)
        var handoffActions: [StatusPopover.VerificationHandoff] = []
        let handoff = WindowControlHandoff(
            openSettings: { handoffActions.append(.settings) },
            revealApplication: { handoffActions.append(.finder($0)) }
        )
        let status = StatusPopover(model: model, windowControl: handoff, reduceMotion: { true })
        defer { status.uninstall() }
        try await status.verifyFirstSetup(store: fixture.store, output: screenshots,
                                          designPreview: designPreview, handoffs: { handoffActions })
        let relaunched = fixture.makeModel(authorized: true)
        relaunched.refreshSystemState()
        guard relaunched.windowControlStage == .ready else {
            throw StatusPopover.VerificationFailure(message: "launching again should preserve completed setup")
        }
        guard let screenshots, !designPreview else { return }
        status.uninstall()
        let focus = try fixture.addWorkspaces(thirdName: "Planning")
        let ready = StatusPopover(model: fixture.makeModel(authorized: true), windowControl: handoff, reduceMotion: { true })
        defer { ready.uninstall() }
        try await ready.captureReady(focus: focus, output: screenshots)
    }

    private static func captureDesignPreview(in output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try MenuFixture()
        defer { fixture.remove() }
        let focus = try fixture.addWorkspaces(thirdName: "Planning", designPreview: true)
        let model = fixture.makeModel(authorized: true)
        model.verificationCapture = fixture.previewSnapshot
        let status = StatusPopover(model: model, reduceMotion: { true })
        defer { status.uninstall() }
        try await status.captureReady(focus: focus, output: output, designPreview: true)
        status.uninstall()
        try await verifyFirstSetup(screenshots: output, designPreview: true)
    }

    private struct MenuFixture {
        private let directory: URL
        private let suiteName = "com.mihaliak.awm.fixture.\(UUID().uuidString)"
        private let defaults: UserDefaults
        let store: WorkspaceStore

        init() throws {
            guard let defaults = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileWriteUnknown) }
            self.defaults = defaults
            directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: FileManager.default.temporaryDirectory, create: true)
            store = WorkspaceStore(url: directory.appending(path: ".awm.yaml"))
            let initial = try store.load()
            _ = try store.write(initial.state, replacing: initial)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        @MainActor
        func makeModel(authorized: Bool) -> AppModel {
            let model = AppModel(store: store, errorLog: ErrorLog(url: nil), setupDefaults: defaults)
            model.verificationCapture = snapshot
            model.verificationAuthorized = authorized
            return model
        }

        func addWorkspaces(thirdName: String, includeShortcut: Bool = false, designPreview: Bool = false) throws -> UUID {
            let initial = try store.load()
            var state = initial.state
            let snapshot = designPreview ? previewSnapshot : snapshot
            let focus = try state.save(name: "Focus", snapshot: snapshot, icon: .layout)
            let smaller = PresetCapture(snapshot, preferences: state.preferences)
            let vibing = designPreview ? smaller.selecting(Set(snapshot.members[0].windows.map(\.id))) : snapshot
            let planning = designPreview ? smaller.selecting(Set(snapshot.members[1].windows.map(\.id))) : snapshot
            _ = try state.save(name: "Vibing", snapshot: vibing, icon: .code)
            _ = try state.save(name: thirdName, snapshot: planning, icon: .video)
            state.lastActive = focus.id
            if designPreview { state.preferences.autoActivate = true }
            if includeShortcut, let key = state.shortcuts.first?.key {
                try state.assign(nil, to: .arrange(.left))
                try state.assign(key, to: .preset(focus.id))
            }
            _ = try store.write(state, replacing: initial)
            return focus.id
        }

        var previewSnapshot: WorkspaceSnapshot {
            let original = snapshot
            let windows = original.members.flatMap(\.windows)
            guard let display = original.displays.primary else { return original }
            let frame = CGRect(x: 780, y: 36, width: 620, height: 790)
            let third = SavedWindow(id: UUID(), displayID: display.id, frame: frame,
                                    relativeFrame: frame.relative(to: display.usable), order: 2)
            let members = [
                SavedApp(identity: AppIdentity(bundleID: nil, bundlePath: nil, name: "Editor"), windows: windows),
                SavedApp(identity: AppIdentity(bundleID: nil, bundlePath: nil, name: "Browser"), windows: [third])
            ]
            return WorkspaceSnapshot(displays: original.displays, members: members, focusedWindow: original.focusedWindow)
        }

        private var snapshot: WorkspaceSnapshot {
            let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
            let screen = DisplaySnapshot(id: "fixture", uuid: nil, model: "fixture", serial: 0,
                                         name: "Example Display", frame: bounds, usable: bounds, scale: 2, primary: true)
            let frame = CGRect(x: 20, y: 32, width: 680, height: 680)
            let window = SavedWindow(id: UUID(), displayID: screen.id, frame: frame,
                                     relativeFrame: frame.relative(to: screen.usable), order: 0)
            let secondFrame = frame.offsetBy(dx: 320, dy: 40)
            let second = SavedWindow(id: UUID(), displayID: screen.id, frame: secondFrame,
                                     relativeFrame: secondFrame.relative(to: screen.usable), order: 1)
            let app = SavedApp(identity: AppIdentity(bundleID: "test.awm", bundlePath: nil, name: "Example App"),
                               windows: [window, second])
            return WorkspaceSnapshot(displays: DisplayLayout(screens: [screen]), members: [app],
                                             focusedWindow: window.id)
        }
    }
    #endif

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refreshSystemState()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        model?.screensChanged()
        status?.displayConfigurationChanged()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        status?.uninstall()
    }
}
