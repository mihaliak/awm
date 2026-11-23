import Foundation

struct CompositedWindow {
    let pid: pid_t
    let frame: CGRect
}

extension LiveWindow {
    static func markOnScreen(_ windows: [Self], pid: pid_t,
                             compositor: [CompositedWindow], appHidden: Bool) -> [Self] {
        guard !appHidden else { return windows }
        var visible = compositor.filter { $0.pid == pid }
        return windows.map { window in
            guard !window.minimized, let frame = window.frame,
                  let index = visible.firstIndex(where: { frame.isNear($0.frame, tolerance: 4) })
            else { return window }
            var match = window
            match.onScreen = true
            visible.remove(at: index)
            return match
        }
    }
}

struct WindowMatch<Handle: Hashable> {
    let saved: SavedWindow
    let live: LiveWindow<Handle>
}

enum WorkspaceMatching {
    static func windows<Handle>(
        _ saved: [SavedWindow], with live: [LiveWindow<Handle>], targets: [UUID: CGRect]
    ) -> [WindowMatch<Handle>] {
        typealias Pair = (saved: Int, live: Int, visibility: Int, distance: CGFloat, orderDifference: Int)
        var pairs: [Pair] = []
        for (savedIndex, slot) in saved.enumerated() {
            guard let target = targets[slot.id] else { continue }
            for (liveIndex, candidate) in live.enumerated() {
                let availability = candidate.fullScreen ? 2 : candidate.onScreen && !candidate.minimized ? 0 : 1
                pairs.append((savedIndex, liveIndex, availability,
                              candidate.frame.map { distance($0, target) } ?? .infinity,
                              abs(candidate.order - slot.order)))
            }
        }
        // Reserve exact destinations across the app before allowing approximate matches.
        // Off-Space/minimized windows are only considered after visible candidates.
        pairs.sort { a, b in
            let first = (a.visibility, a.distance, a.orderDifference, saved[a.saved].order, a.saved, a.live)
            let second = (b.visibility, b.distance, b.orderDifference, saved[b.saved].order, b.saved, b.live)
            return first < second
        }
        var used = Set<Handle>()
        var assigned: [Int: LiveWindow<Handle>] = [:]
        for pair in pairs where assigned[pair.saved] == nil {
            let candidate = live[pair.live]
            if used.insert(candidate.handle).inserted { assigned[pair.saved] = candidate }
        }
        return saved.enumerated().compactMap { index, slot in
            assigned[index].map { WindowMatch(saved: slot, live: $0) }
        }
    }

    private static func distance(_ frame: CGRect, _ target: CGRect) -> CGFloat {
        abs(frame.minX - target.minX) + abs(frame.minY - target.minY) +
            abs(frame.width - target.width) + abs(frame.height - target.height)
    }
}

enum ShortcutError: LocalizedError {
    case duplicate(String)
    case unavailable(OSStatus)
    case invalid
    case eventHandler(OSStatus)

    var errorDescription: String? {
        switch self {
        case .duplicate(let name): "This shortcut is already assigned to \(name)."
        case .unavailable: "macOS couldn’t register this shortcut. Choose a different combination."
        case .invalid: "Press a key with Command, Option, Control or Shift."
        case .eventHandler: "Another Window Management couldn’t start global shortcuts."
        }
    }
}
