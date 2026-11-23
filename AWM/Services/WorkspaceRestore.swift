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

        func readyWindows(reveal: Bool) -> [LiveWindow<System.Handle>] {
            windows.filter { window in
                !window.fullScreen && (window.onScreen ||
                    (reveal && (window.minimized || owners[window.handle]?.hidden == true)))
            }
        }
    }

    private struct PlacedWindow {
        let placement: Placement
        let alreadyRaised: Bool
    }

    private typealias Attempt = Result<PlacedWindow, RestoreIssue>

    private struct PendingPlacement {
        struct Candidate {
            let handle: System.Handle
            let app: LiveApp
        }

        let saved: SavedWindow
        let target: WorkspaceWindowTarget
        var candidate: Candidate?
        var attempt: Attempt
        var placedFrame: CGRect?
        var confirmations = 0
        var confirmationIssue: RestoreIssue?

        var result: Attempt {
            confirmationIssue.map(Attempt.failure) ?? attempt
        }
    }

    private let system: System
    private let errorLog: ErrorLog
    private let launchTimeout: Duration
    private let pollInterval: Duration
    private let launchTiming: WindowPlacement.Timing
    private let waitForVisibilityUpdate: @MainActor () async throws -> Void
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    init(system: System, errorLog: ErrorLog = .init(url: nil), launchTimeout: Duration = .seconds(5),
         pollInterval: Duration = .milliseconds(160), launchTiming: WindowPlacement.Timing = .continuous(),
         waitForVisibilityUpdate: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(for: .milliseconds(50))
         }) {
        self.system = system
        self.errorLog = errorLog
        self.launchTimeout = launchTimeout
        self.pollInterval = pollInterval
        self.launchTiming = launchTiming
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
        let running = Dictionary(grouping: system.apps(), by: { $0.identity.key })
        var pending: [SavedApp] = []
        if preferences.launchMissing {
            for member in snapshot.members where running[member.id] == nil {
                try Task.checkCancellation()
                if system.requestLaunch(member.identity) { pending.append(member) }
            }
        }
        try await waitForLaunches(pending, reveal: preferences.revealMembers)
        try Task.checkCancellation()
        let launched = Set(pending.map(\.id))
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
        func recordPlacement(_ result: Attempt, id: UUID, window: System.Handle,
                             app: LiveApp, slot: String) {
            switch result {
            case .failure(let issue):
                addFailure(issue, app: app.identity, window: window, slot: slot)
            case .success(let success):
                report.placed += 1
                placed.append((id, window, app, slot))
                if success.placement == .constrained {
                    addFailure(.constrained, app: app.identity, window: window, slot: slot)
                }
                if !success.alreadyRaised { _ = system.raise(window, app: app, activate: false) }
            }
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
            let alreadyRunning = running[member.id, default: []]
            let windowlessCandidate = alreadyRunning.count == 1 ? alreadyRunning.first : nil
            let discovered = try await discoverWindows(initial, memberID: member.id, targetCount: targets.count,
                                                       reveal: preferences.revealMembers,
                                                       windowlessCandidate: windowlessCandidate) { app in
                recoveryTargets[app.pid] = app.identity
            }
            let matches = WorkspaceMatching.windows(member.windows, with: discovered.windows,
                                                    targets: targets.mapValues(\.frame))
            let bySlot = Dictionary(uniqueKeysWithValues: matches.map { ($0.saved.id, $0.live.handle) })
            let missing: RestoreIssue =
                !discovered.apps.isEmpty && discovered.apps.allSatisfy(\.hidden)
                ? (preferences.revealMembers ? .unhideFailed : .hidden) : .missing
            let starting = launched.contains(member.id)
            var placements: [PendingPlacement] = []
            for saved in member.windows {
                try Task.checkCancellation()
                guard let target = targets[saved.id] else {
                    addFailure(.displayUnavailable, app: discovered.apps.first?.identity ?? member.identity,
                               slot: member.windowLabel(for: saved))
                    continue
                }
                var item = PendingPlacement(saved: saved, target: target, attempt: .failure(missing))
                if let handle = bySlot[saved.id], let app = discovered.owners[handle] {
                    try await attemptPlacement(&item, on: .init(handle: handle, app: app),
                                               reveal: preferences.revealMembers, animate: preferences.animate,
                                               starting: starting)
                }
                placements.append(item)
            }
            try await confirmPlacements(&placements, memberID: member.id, reveal: preferences.revealMembers,
                                        starting: starting)
            for item in placements {
                let slot = member.windowLabel(for: item.saved)
                if let candidate = item.candidate {
                    recordPlacement(item.result, id: item.saved.id, window: candidate.handle, app: candidate.app, slot: slot)
                } else if case .failure(let issue) = item.result {
                    addFailure(issue, app: discovered.apps.first?.identity ?? member.identity, slot: slot)
                }
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
        return inventory(for: apps, on: apps.isEmpty ? nil : system.compositor())
    }

    private func inventory(for apps: [LiveApp], on composited: [CompositedWindow]?) -> MemberInventory {
        var inventory = MemberInventory(apps: apps)
        for app in apps {
            for window in system.windows(for: app, on: composited) where inventory.owners[window.handle] == nil {
                inventory.owners[window.handle] = app
                inventory.windows.append(window)
            }
        }
        return inventory
    }

    private func place(_ window: System.Handle, in app: LiveApp, at target: WorkspaceWindowTarget,
                       reveal: Bool, animate: Bool)
    async throws -> Attempt {
        let preparation = try await prepare(window, in: app, reveal: reveal)
        let alreadyRaised: Bool
        switch preparation {
        case .success(let raised): alreadyRaised = raised
        case .failure(let issue): return .failure(issue)
        }

        try Task.checkCancellation()
        let placement = await system.place(window, in: target, animate: animate)
        try Task.checkCancellation()
        guard placement.usable else {
            return .failure(system.restoreState(of: window, in: app).issue ?? .placementFailed)
        }
        let state = try await waitForState(window, in: app, while: [.offScreen, .visibilityUnavailable])
        if let issue = state.issue { return .failure(issue) }
        return .success(.init(placement: placement, alreadyRaised: alreadyRaised))
    }

    private func canRetry(_ attempt: Attempt) -> Bool {
        switch attempt {
        case .success, .failure(.offScreen), .failure(.visibilityUnavailable), .failure(.unreadable),
             .failure(.placementFailed), .failure(.missing): true
        case .failure: false
        }
    }

    private func attemptPlacement(_ item: inout PendingPlacement, on candidate: PendingPlacement.Candidate,
                                  reveal: Bool, animate: Bool, starting: Bool) async throws {
        item.candidate = candidate
        item.attempt = try await place(candidate.handle, in: candidate.app, at: item.target, reveal: reveal,
                                       animate: animate)
        item.confirmations = 0
        item.confirmationIssue = nil
        item.placedFrame = nil
        if case .success(let success) = item.attempt {
            switch success.placement {
            case .exact: item.placedFrame = item.target.frame
            case .gapAdjusted(let frame): item.placedFrame = frame
            case .constrained: item.placedFrame = system.frame(for: candidate.handle)
            case .unavailable: break
            }
            if !starting { item.confirmations = 1 }
        }
    }

    private func confirmPlacements(_ placements: inout [PendingPlacement], memberID: String, reveal: Bool,
                                   starting: Bool) async throws {
        guard placements.contains(where: { canRetry($0.attempt) }) else { return }
        // Reuse siblings' inventory while checking for AX replacement, late geometry and overwritten frames.
        let polls = starting ? 4 : 6
        let interval = starting ? pollInterval : min(pollInterval, .milliseconds(50))
        for poll in 1...polls {
            try await launchTiming.sleepUntil(launchTiming.now() + interval)
            try Task.checkCancellation()
            let current = inventory(for: memberID)
            let windows = Dictionary(uniqueKeysWithValues: current.windows.map { ($0.handle, $0) })
            let ready = current.readyWindows(reveal: reveal)
            let readyHandles = Set(ready.map(\.handle))
            let reserved = Set(placements.compactMap { $0.candidate?.handle })
            let missing = placements.filter { item in
                guard canRetry(item.attempt) else { return false }
                guard let handle = item.candidate?.handle, let window = windows[handle] else { return true }
                return window.frame == nil && !readyHandles.contains(handle)
            }
            let replacements = Dictionary(uniqueKeysWithValues: WorkspaceMatching.windows(
                missing.map(\.saved), with: ready.filter { !reserved.contains($0.handle) },
                targets: Dictionary(uniqueKeysWithValues: missing.map { ($0.saved.id, $0.target.frame) })
            ).map { ($0.saved.id, $0.live) })

            for index in placements.indices {
                try Task.checkCancellation()
                var item = placements[index]
                guard canRetry(item.attempt) else { continue }
                let handle = item.candidate?.handle
                let existing = handle.flatMap { windows[$0] }
                if let existing, existing.onScreen, !existing.fullScreen, let actual = existing.frame,
                   let frame = item.placedFrame, actual.isNear(frame) {
                    item.confirmations += 1
                    item.confirmationIssue = nil
                } else {
                    item.confirmations = 0
                    if case .success = item.attempt, let candidate = item.candidate {
                        item.confirmationIssue = system.restoreState(of: candidate.handle, in: candidate.app).issue
                            ?? .placementFailed
                    }
                    if poll < polls, let window = replacements[item.saved.id] ?? existing,
                       readyHandles.contains(window.handle), let app = current.owners[window.handle] {
                        try await attemptPlacement(&item, on: .init(handle: window.handle, app: app),
                                                   reveal: reveal, animate: false, starting: starting)
                    }
                }
                placements[index] = item
            }
            if placements.allSatisfy({ $0.confirmations >= 2 || !canRetry($0.attempt) }) { return }
        }
        for index in placements.indices where placements[index].confirmations < 2 {
            if case .success = placements[index].result {
                placements[index].confirmationIssue = .placementFailed
            }
        }
    }

    private func discoverWindows(_ initial: MemberInventory, memberID: String, targetCount: Int, reveal: Bool,
                                 windowlessCandidate: LiveApp?, recoveryRequested: (LiveApp) -> Void)
    async throws -> MemberInventory {
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
            if system.requestReopen(app, knownWindows: knownWindows, allowWindowless: false) {
                askedToReopen = true
                recoveryRequested(app)
            }
        }
        if askedToReopen {
            try await poll(maxPolls: 10)
            return current
        }

        func windowlessApp() -> LiveApp? {
            guard let candidate = windowlessCandidate, current.apps.count == 1, let app = current.apps.first,
                  app.pid == candidate.pid, app.identity == candidate.identity,
                  !app.hidden, current.windows.isEmpty else { return nil }
            return app
        }
        if windowlessApp() != nil {
            if !askedToUnhide { try await poll(maxPolls: 3) }
            try Task.checkCancellation()
            if let app = windowlessApp(), clock.now < deadline,
               system.requestReopen(app, knownWindows: [], allowWindowless: true) {
                recoveryRequested(app)
                try await poll(maxPolls: 10)
                return current
            }
        }
        if let app = current.apps.first(where: { app in
            !app.hidden && !current.owners.values.contains { $0.pid == app.pid }
        }) {
            try Task.checkCancellation()
            // Activation gives an existing process a chance to publish AX windows without an open request.
            if system.activate(app) {
                recoveryRequested(app)
                try await poll(maxPolls: 3)
            }
        }
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
            guard system.setWindow(window, minimized: false) else {
                return .failure(system.restoreState(of: window, in: app) == .unreadable ? .unreadable : .unminimizeFailed)
            }
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

    private func waitForLaunches(_ pending: [SavedApp], reveal: Bool) async throws {
        guard !pending.isEmpty else { return }
        let deadline = launchTiming.now() + launchTimeout
        var previous: [String: [System.Handle: CGRect?]] = [:]
        while launchTiming.now() < deadline {
            try Task.checkCancellation()
            if let composited = system.compositor() {
                let running = Dictionary(grouping: system.apps(), by: { $0.identity.key })
                var current: [String: [System.Handle: CGRect?]] = [:]
                var allReady = true
                for member in pending {
                    let inventory = inventory(for: running[member.id, default: []], on: composited)
                    let frames = Dictionary(uniqueKeysWithValues: inventory.readyWindows(reveal: reveal).map {
                        ($0.handle, $0.frame)
                    })
                    let stable = frames.filter { handle, frame in
                        guard let old = previous[member.id]?[handle] else { return false }
                        return frame.map { old?.isNear($0) == true } ?? (old == nil)
                    }
                    allReady = allReady && stable.count >= member.windows.count
                    current[member.id] = frames
                }
                if allReady { return }
                previous = current
            } else {
                previous.removeAll()
            }
            try await launchTiming.sleepUntil(min(deadline, launchTiming.now() + pollInterval))
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
