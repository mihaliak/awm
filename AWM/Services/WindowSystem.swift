import Foundation

enum Placement: Equatable {
    case exact
    case gapAdjusted(CGRect)
    case constrained
    case unavailable

    var usable: Bool { self != .unavailable }
}

@MainActor
struct WindowPlacement {
    struct Timing {
        let now: () -> Duration
        let sleepUntil: @MainActor (Duration) async throws -> Void

        static func continuous() -> Self {
            let clock = ContinuousClock()
            let origin = clock.now
            return Self(now: { origin.duration(to: clock.now) }, sleepUntil: { deadline in
                try await clock.sleep(until: origin.advanced(by: deadline), tolerance: .milliseconds(1))
            })
        }
    }

    let readFrame: () -> CGRect?
    let setPosition: (CGPoint) -> Bool
    let setSize: (CGSize) -> Bool

    func place(_ target: WindowTarget, animate: Bool, timing: Timing = .continuous(),
               gap: WorkspaceWindowTarget.Gap? = nil) async -> Placement {
        guard !Task.isCancelled, let initial = readFrame() else { return .unavailable }
        let destination: CGRect
        let canResize: Bool
        switch target {
        case .frame(let frame):
            destination = frame
            canResize = true
        case .move(let origin):
            destination = CGRect(origin: origin, size: initial.size)
            canResize = false
        }
        if initial.isNear(destination) { return .exact }

        var previous = initial
        do {
            if animate {
                try await animateFrames(from: initial, to: destination, canResize: canResize, timing: timing)
                guard !Task.isCancelled, let measured = readFrame() else { return .unavailable }
                previous = measured
            }
            try Task.checkCancellation()
            if previous.isNear(destination) { return .exact }
            write(destination, from: &previous, canResize: canResize, tolerance: 2)
            guard var actual = try await settledFrame(near: destination, timing: timing) else { return .unavailable }
            if actual.isNear(destination) { return .exact }

            // A window may only accept the final size after it moves to the destination display.
            if canResize || !CGRect(origin: actual.origin, size: destination.size).isNear(destination) {
                var correction = actual
                write(destination, from: &correction, canResize: canResize, tolerance: 2, positionFirst: true)
                guard let corrected = try await settledFrame(near: destination, timing: timing) else {
                    return .unavailable
                }
                actual = corrected
            }
            if actual.isNear(destination) { return .exact }
            if let adjusted = gap?.adjustedFrame(for: actual.size, requested: destination) {
                if !actual.isNear(adjusted) {
                    write(adjusted, from: &actual, canResize: false, tolerance: 2)
                    guard let measured = try await settledFrame(near: adjusted, timing: timing) else {
                        return .unavailable
                    }
                    actual = measured
                }
                if actual.isNear(adjusted) { return .gapAdjusted(adjusted) }
            }
            return actual.isNear(initial) ? .unavailable : .constrained
        } catch {
            return .unavailable
        }
    }

    private func animateFrames(from initial: CGRect, to destination: CGRect, canResize: Bool,
                               timing: Timing) async throws {
        let start = timing.now()
        let interval = Duration.milliseconds(16)
        let steps = 6
        var previous = initial
        for step in 1..<steps {
            let deadline = start + interval * step
            if timing.now() < deadline { try await timing.sleepUntil(deadline) }
            try Task.checkCancellation()
            // Coalesce missed frames when another process falls behind on AX calls.
            guard timing.now() < deadline + interval else { continue }
            let progress = CGFloat(step) / CGFloat(steps)
            let t = progress * progress * (3 - 2 * progress)
            let intermediate = CGRect(
                x: initial.minX + (destination.minX - initial.minX) * t,
                y: initial.minY + (destination.minY - initial.minY) * t,
                width: initial.width + (destination.width - initial.width) * t,
                height: initial.height + (destination.height - initial.height) * t
            )
            if !write(intermediate, from: &previous, canResize: canResize, tolerance: 0) { return }
        }
        let finish = start + interval * steps
        if timing.now() < finish { try await timing.sleepUntil(finish) }
    }

    private func settledFrame(near destination: CGRect, timing: Timing) async throws -> CGRect? {
        try Task.checkCancellation()
        guard let actual = readFrame() else { return nil }
        if actual.isNear(destination) { return actual }
        try await timing.sleepUntil(timing.now() + .milliseconds(25))
        try Task.checkCancellation()
        return readFrame()
    }

    @discardableResult
    private func write(_ frame: CGRect, from previous: inout CGRect, canResize: Bool,
                       tolerance: CGFloat, positionFirst: Bool = false) -> Bool {
        let moved = abs(previous.minX - frame.minX) > tolerance || abs(previous.minY - frame.minY) > tolerance
        let resized = canResize &&
            (abs(previous.width - frame.width) > tolerance || abs(previous.height - frame.height) > tolerance)
        func move() -> Bool { moved && !Task.isCancelled && setPosition(frame.origin) }
        func resize() -> Bool { resized && !Task.isCancelled && setSize(frame.size) }
        let wrotePosition: Bool
        let wroteSize: Bool
        if positionFirst {
            wrotePosition = move()
            wroteSize = resize()
        } else {
            wroteSize = resize()
            wrotePosition = move()
        }
        if wrotePosition { previous.origin = frame.origin }
        if wroteSize { previous.size = frame.size }
        return wrotePosition || wroteSize || (!moved && !resized)
    }
}

@MainActor
protocol WindowSystem: AnyObject {
    associatedtype Handle: Hashable

    var authorized: Bool { get }
    func displays() -> DisplayLayout
    func apps() -> [LiveApp]
    func compositor() -> [CompositedWindow]?
    func windows(for app: LiveApp, on compositor: [CompositedWindow]?) -> [LiveWindow<Handle>]
    func restoreState(of window: Handle, in app: LiveApp) -> RestoreWindowState
    func frame(for window: Handle) -> CGRect?
    func focusedWindow(pid: pid_t?) -> Handle?
    func windowTitle(for window: Handle) -> String?
    func frontmostApp() -> LiveApp?
    func activate(_ app: LiveApp) -> Bool
    func requestLaunch(_ app: AppIdentity) -> Bool
    func requestReopen(_ app: LiveApp, knownWindows: [LiveWindow<Handle>], allowWindowless: Bool) -> Bool
    func setApp(_ app: LiveApp, hidden: Bool) -> Bool
    func setWindow(_ window: Handle, minimized: Bool) -> Bool
    func place(_ window: Handle, in target: WorkspaceWindowTarget, animate: Bool) async -> Placement
    func raise(_ window: Handle, app: LiveApp, activate: Bool) -> Bool
}

enum RestoreWindowState {
    case visible, offScreen, hidden, minimized, fullScreen, unreadable, visibilityUnavailable
}

extension WindowSystem {
    func capture(focusedPID: pid_t?) throws -> WorkspaceSnapshot {
        guard authorized else { throw WorkspaceError.permission }
        let layout = displays()
        guard layout.primary != nil else { throw WorkspaceError.displays }
        guard let compositor = compositor() else { throw WorkspaceError.visibility }
        let running = apps()
        let focused = focusedWindow(pid: focusedPID)
        var focusedID: UUID?
        var members: [SavedApp] = []
        var alreadySeen = Set<Handle>()
        for app in running where !app.hidden {
            let visible = windows(for: app, on: compositor).filter { $0.onScreen && !$0.minimized }
            var captured: [SavedWindow] = []
            for window in visible {
                guard let frame = window.frame, alreadySeen.insert(window.handle).inserted,
                      let display = layout.display(for: frame)
                else { continue }
                let id = UUID()
                if window.handle == focused { focusedID = id }
                captured.append(SavedWindow(id: id, displayID: display.id,
                                            frame: frame, relativeFrame: frame.relative(to: display.usable),
                                            order: window.order))
            }
            guard !captured.isEmpty else { continue }
            if let index = members.firstIndex(where: { $0.id == app.identity.key }) {
                let prior = members[index]
                members[index] = SavedApp(identity: prior.identity, windows: prior.windows + captured)
            } else {
                members.append(SavedApp(identity: app.identity, windows: captured))
            }
        }
        guard !members.isEmpty else { throw WorkspaceError.emptyCapture }
        return WorkspaceSnapshot(displays: layout, members: members, focusedWindow: focusedID)
    }
}
