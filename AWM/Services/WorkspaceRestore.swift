import Foundation

enum RestoreIssue: String, Error {
    case appUnavailable, notRunning, missing, hidden, unhideFailed, minimized, unminimizeFailed
    case fullScreen, unreadable, offScreen, visibilityUnavailable, displayUnavailable
    case placementFailed, constrained, hideOutsideFailed, minimizeOutsideFailed, outsideVisibilityUnavailable
    case focusFailed
}

struct RestoreReport: Equatable {
    struct Failure: Equatable {
        let issue: RestoreIssue
        let context: ErrorLog.Context
    }

    let total: Int
    var placed = 0
    var failures: [Failure] = []

    var issues: [RestoreIssue] { failures.map(\.issue) }
    var successful: Bool { placed > 0 }
}

@MainActor
final class WorkspaceRestore<System: WindowSystem> {
    private struct MemberInventory {
        let apps: [LiveApp]
        var windows: [LiveWindow<System.Handle>] = []
        var owners: [System.Handle: LiveApp] = [:]

        func needsWindows(for targetCount: Int) -> Bool {
            windows.lazy.filter { !$0.fullScreen }.count < targetCount
        }
    }

    private let system: System
    private let errorLog: ErrorLog
    private let launchTimeout: Duration
    private let pollInterval: Duration
    private let waitForVisibilityUpdate: @MainActor () async throws -> Void
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    init(system: System, errorLog: ErrorLog = .init(url: nil), launchTimeout: Duration = .seconds(5),
         pollInterval: Duration = .milliseconds(160), waitForVisibilityUpdate: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(for: .milliseconds(50))
         }) {
        self.system = system
        self.errorLog = errorLog
        self.launchTimeout = launchTimeout
        self.pollInterval = pollInterval
        self.waitForVisibilityUpdate = waitForVisibilityUpdate
    }

    @discardableResult
    func request(_ preset: Preset, preferences: Preferences, salt: UUID? = nil,
                 completion: @escaping (Result<RestoreReport, Error>) -> Void) -> Task<Void, Never> {
        let previous = task
        previous?.cancel()
        let id = UUID()
        requestID = id
        let next = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            defer {
                if self.requestID == id {
                    self.task = nil
                    self.requestID = nil
                }
            }
            do {
                let report = try await self.restore(preset, preferences: preferences, salt: salt)
                try Task.checkCancellation()
                for failure in report.failures {
                    self.errorLog.recordRestore(failure.issue, context: failure.context)
                }
                completion(.success(report))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.errorLog.record(.restore, error, context: .init(workspace: preset.name))
                completion(.failure(error))
            }
        }
        task = next
        return next
    }

    func cancel() {
        task?.cancel()
    }

    private func restore(_ preset: Preset, preferences: Preferences, salt: UUID?) async throws -> RestoreReport {
        let snapshot = preset.snapshot
        guard system.authorized else { throw WorkspaceError.permission }
        guard system.displays().primary != nil else { throw WorkspaceError.displays }
        let running = Set(system.apps().map { $0.identity.key })
        var pending: [SavedApp] = []
        if preferences.launchMissing {
            for member in snapshot.members where !running.contains(member.id) {
                try Task.checkCancellation()
                if system.requestLaunch(member.identity) { pending.append(member) }
            }
        }
        try await waitForLaunches(pending)
        try Task.checkCancellation()
        let layout = system.displays()
        guard layout.primary != nil else { throw WorkspaceError.displays }
        let destinations = layout.destinations(from: snapshot.displays, salt: salt)

        var report = RestoreReport(total: snapshot.windowCount)
        var placed: [(id: UUID, window: System.Handle, app: LiveApp, slot: String)] = []
        func addFailure(_ issue: RestoreIssue, app: AppIdentity? = nil, window: System.Handle? = nil, slot: String? = nil) {
            let title = errorLog.isEnabled && !Task.isCancelled ? window.flatMap(system.windowTitle(for:)) : nil
            let context = ErrorLog.Context(workspace: preset.name, app: app?.diagnosticName,
                                           windowTitle: title, windowSlot: slot)
            report.failures.append(.init(issue: issue, context: context))
        }
        let previousFocus = preferences.revealMembers ? system.frontmostApp() : nil
        var recoveryTargets: [pid_t: AppIdentity] = [:]
        defer {
            if placed.isEmpty, !recoveryTargets.isEmpty, let previousFocus,
               let frontmost = system.frontmostApp(), frontmost.pid != previousFocus.pid,
               recoveryTargets[frontmost.pid] == frontmost.identity {
                _ = system.activate(previousFocus)
            }
        }
        for member in snapshot.members {
            try Task.checkCancellation()
            let targets = layout.targets(for: member.windows, from: snapshot.displays,
                                         destinations: destinations, preferences: preferences, salt: salt)
            let initial = inventory(for: member.id)
            guard !initial.apps.isEmpty else {
                let reason: RestoreIssue = preferences.launchMissing ? .appUnavailable : .notRunning
                for saved in member.windows {
                    addFailure(reason, app: member.identity, slot: member.windowLabel(for: saved))
                }
                continue
            }
            let discovered = try await discoverWindows(initial, memberID: member.id, targetCount: targets.count,
                                                       reveal: preferences.revealMembers) { app in
                recoveryTargets[app.pid] = app.identity
            }
            let matches = WorkspaceMatching.windows(member.windows, with: discovered.windows, targets: targets)
            let matchedIDs = Set(matches.map(\.saved.id))
            let missing: RestoreIssue =
                !discovered.apps.isEmpty && discovered.apps.allSatisfy(\.hidden)
                ? (preferences.revealMembers ? .unhideFailed : .hidden) : .missing
            for saved in member.windows where !matchedIDs.contains(saved.id) {
                let reason: RestoreIssue = targets[saved.id] == nil ? .displayUnavailable : missing
                addFailure(reason, app: discovered.apps.first?.identity ?? member.identity, slot: member.windowLabel(for: saved))
            }
            for match in matches {
                try Task.checkCancellation()
                let window = match.live.handle
                let slot = member.windowLabel(for: match.saved)
                guard let app = discovered.owners[window], let frame = targets[match.saved.id]
                else {
                    addFailure(.displayUnavailable, app: discovered.owners[window]?.identity ?? member.identity,
                               window: window, slot: slot)
                    continue
                }
                let preparation = try await prepare(window, in: app, reveal: preferences.revealMembers)
                let alreadyRaised: Bool
                switch preparation {
                case .failure(let reason):
                    addFailure(reason, app: app.identity, window: window, slot: slot)
                    continue
                case .success(let raised):
                    alreadyRaised = raised
                }

                let placement = await system.place(window, in: frame, animate: preferences.animate)
                try Task.checkCancellation()
                guard placement.usable else {
                    let reason = system.restoreState(of: window, in: app).issue ?? .placementFailed
                    addFailure(reason, app: app.identity, window: window, slot: slot)
                    continue
                }

                let state = try await waitForState(window, in: app, while: [.offScreen, .visibilityUnavailable])
                if let reason = state.issue {
                    addFailure(reason, app: app.identity, window: window, slot: slot)
                    continue
                }

                report.placed += 1
                placed.append((match.saved.id, window, app, slot))
                if placement == .constrained {
                    addFailure(.constrained, app: app.identity, window: window, slot: slot)
                }
                if !alreadyRaised { _ = system.raise(window, app: app, activate: false) }
            }
        }
        try Task.checkCancellation()
        guard report.successful else { return report }

        let memberIDs = Set(snapshot.members.map(\.id))
        switch preferences.outsidePolicy {
        case .hide:
            for app in system.apps() where !memberIDs.contains(app.identity.key) && !app.hidden {
                try Task.checkCancellation()
                if !system.setApp(app, hidden: true) {
                    addFailure(.hideOutsideFailed, app: app.identity)
                }
            }
        case .minimize:
            if let onScreen = system.compositor() {
                for app in system.apps() where !memberIDs.contains(app.identity.key) && !app.hidden {
                    for window in system.windows(for: app, on: onScreen) where window.onScreen && !window.minimized {
                        try Task.checkCancellation()
                        if !system.setWindow(window.handle, minimized: true) {
                            addFailure(.minimizeOutsideFailed, app: app.identity, window: window.handle,
                                       slot: "Window \(window.order + 1)")
                        }
                    }
                }
            } else {
                addFailure(.outsideVisibilityUnavailable)
            }
        case .leave:
            break
        }
        try Task.checkCancellation()
        func visible(_ item: (id: UUID, window: System.Handle, app: LiveApp, slot: String)) -> Bool {
            system.restoreState(of: item.window, in: item.app) == .visible
        }
        let focus = placed.first { $0.id == snapshot.focusedWindow && visible($0) } ?? placed.first(where: visible)
        if focus.map({ system.raise($0.window, app: $0.app, activate: true) }) != true {
            let attempted = focus ?? placed.first { $0.id == snapshot.focusedWindow } ?? placed.first
            addFailure(.focusFailed, app: attempted?.app.identity, window: attempted?.window, slot: attempted?.slot)
        }
        return report
    }

    private func inventory(for memberID: String) -> MemberInventory {
        let apps = system.apps().filter { $0.identity.key == memberID }
        var inventory = MemberInventory(apps: apps)
        guard !apps.isEmpty else { return inventory }
        let composited = system.compositor()
        for app in apps {
            for window in system.windows(for: app, on: composited) where inventory.owners[window.handle] == nil {
                inventory.owners[window.handle] = app
                inventory.windows.append(window)
            }
        }
        return inventory
    }

    private func discoverWindows(_ initial: MemberInventory, memberID: String, targetCount: Int, reveal: Bool,
                                 recoveryRequested: (LiveApp) -> Void) async throws -> MemberInventory {
        guard reveal, initial.needsWindows(for: targetCount) else { return initial }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        var current = initial

        func poll(maxPolls: Int) async throws {
            for _ in 0..<maxPolls {
                try Task.checkCancellation()
                guard clock.now < deadline, current.needsWindows(for: targetCount) else { return }
                try await waitForVisibilityUpdate()
                try Task.checkCancellation()
                current = inventory(for: memberID)
            }
        }

        var askedToUnhide = false
        for app in current.apps where app.hidden && clock.now < deadline {
            try Task.checkCancellation()
            if system.setApp(app, hidden: false) {
                askedToUnhide = true
                recoveryRequested(app)
            }
        }
        if askedToUnhide { try await poll(maxPolls: 3) }
        guard current.needsWindows(for: targetCount) else { return current }

        var askedToReopen = false
        for app in current.apps where !app.hidden && clock.now < deadline {
            try Task.checkCancellation()
            let knownWindows = current.windows.filter { current.owners[$0.handle]?.pid == app.pid }
            if system.requestReopen(app, knownWindows: knownWindows) {
                askedToReopen = true
                recoveryRequested(app)
            }
        }
        if askedToReopen { try await poll(maxPolls: 10) }
        return current
    }

    private func prepare(_ window: System.Handle, in app: LiveApp, reveal: Bool)
    async throws -> Result<Bool, RestoreIssue> {
        var state = system.restoreState(of: window, in: app)
        var revealed = false
        if state == .hidden, reveal {
            guard system.setApp(app, hidden: false) else { return .failure(.unhideFailed) }
            revealed = true
            state = try await waitForState(window, in: app, while: [.hidden])
        }
        if state == .minimized, reveal {
            guard system.setWindow(window, minimized: false) else { return .failure(.unminimizeFailed) }
            revealed = true
        }
        if revealed || state == .visibilityUnavailable {
            state = try await waitForState(window, in: app, while: [.minimized, .offScreen, .visibilityUnavailable])
        }
        let triedRaise = state == .offScreen && reveal
        if triedRaise {
            _ = system.raise(window, app: app, activate: false)
            state = try await waitForState(window, in: app, while: [.offScreen, .visibilityUnavailable])
        }
        if let reason = state.issue { return .failure(reason) }
        return .success(triedRaise)
    }

    private func waitForState(_ window: System.Handle, in app: LiveApp,
                              while pending: Set<RestoreWindowState>) async throws -> RestoreWindowState {
        try Task.checkCancellation()
        var state = system.restoreState(of: window, in: app)
        // Wait for the window server to publish changes after reveal, raise or placement.
        for _ in 0..<6 where pending.contains(state) {
            try await waitForVisibilityUpdate()
            try Task.checkCancellation()
            state = system.restoreState(of: window, in: app)
        }
        return state
    }

    private func waitForLaunches(_ pending: [SavedApp]) async throws {
        guard !pending.isEmpty else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: launchTimeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            let running = Dictionary(grouping: system.apps(), by: { $0.identity.key })
            if pending.allSatisfy({ member in
                guard let apps = running[member.id] else { return false }
                return apps.reduce(0) { $0 + system.windows(for: $1, on: nil).count } >= member.windows.count
            }) { return }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: pollInterval)), tolerance: .milliseconds(20))
        }
    }

}

private extension RestoreWindowState {
    var issue: RestoreIssue? {
        switch self {
        case .visible: nil
        case .hidden: .hidden
        case .minimized: .minimized
        case .fullScreen: .fullScreen
        case .unreadable: .unreadable
        case .offScreen: .offScreen
        case .visibilityUnavailable: .visibilityUnavailable
        }
    }
}
