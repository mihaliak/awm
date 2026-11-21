import Foundation

enum OutsidePolicy: String, Codable, CaseIterable, Identifiable {
    case hide, minimize, leave

    var id: Self { self }
    var label: String {
        switch self {
        case .hide: "Hide other apps"
        case .minimize: "Minimize other windows"
        case .leave: "Leave other apps unchanged"
        }
    }
}

enum WindowGapUnit: String, Codable, CaseIterable, Identifiable {
    case percentage, points

    var id: Self { self }
    var label: String { self == .percentage ? "Percentage" : "Points" }
}

struct WindowFraction: Codable, Equatable {
    let fraction: Double

    init?(_ fraction: Double) {
        guard (0.10...1).contains(fraction) else { return nil }
        self.fraction = fraction
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Double.self)
        guard let fraction = Self(value) else { throw WorkspaceError.invalidData }
        self = fraction
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fraction)
    }

    private init(validFraction: Double) {
        fraction = validFraction
    }

    static let defaults: [Self] = [.init(validFraction: 1.0 / 3), .init(validFraction: 2.0 / 3),
                                  .init(validFraction: 0.5)]

    var entry: String {
        if let index = Self.defaults.firstIndex(of: self) { return ["1/3", "2/3", "1/2"][index] }
        let percent = (fraction * 100).formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never).precision(.fractionLength(0...8)))
        return percent + "%"
    }

    init?(text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = input.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]) {
            self.init(numerator / denominator)
        } else {
            let number = input.hasSuffix("%") ? String(input.dropLast()) : input
            guard let percent = Double(number) ?? (try? Double(number, format: .number)) else { return nil }
            self.init(percent / 100)
        }
    }
}

struct Preferences: Codable, Equatable {
    // Leave positive space for the smallest 10% tile.
    static let windowGapPercentRange = 0...8
    static let windowGapPointsRange = 0...128

    var outsidePolicy: OutsidePolicy = .hide
    var autoActivate = false
    var launchMissing = true
    var revealMembers = true
    var leftWidths = WindowFraction.defaults
    var rightWidths = WindowFraction.defaults
    var topHeights = WindowFraction.defaults
    var bottomHeights = WindowFraction.defaults
    var windowGapUnit: WindowGapUnit = .percentage
    var windowGapPercent = 0
    var windowGapPoints = 12
    var marginPercent = 5
    var animate = false
    var restoreOnLaunch = false
    var launchAtLogin = false

    var edgeCycles: [[WindowFraction]] {
        [leftWidths, rightWidths, topHeights, bottomHeights]
    }

    var isValid: Bool {
        edgeCycles.allSatisfy { (1...12).contains($0.count) } &&
            Self.windowGapPercentRange.contains(windowGapPercent) &&
            Self.windowGapPointsRange.contains(windowGapPoints) &&
            (0...40).contains(marginPercent)
    }

    func windowGaps(in usable: CGRect) -> (horizontal: CGFloat, vertical: CGFloat) {
        switch windowGapUnit {
        case .percentage:
            let fraction = CGFloat(windowGapPercent) / 100
            return (usable.width * fraction, usable.height * fraction)
        case .points:
            let fraction = CGFloat(Self.windowGapPercentRange.upperBound) / 100
            let gap = min(CGFloat(windowGapPoints), min(usable.width, usable.height) * fraction)
            return (gap, gap)
        }
    }
}

enum ArrangementAction: String, Codable, CaseIterable, Identifiable {
    case left, right, top, bottom, center, centerWithoutResizing

    var id: Self { self }
    var label: String {
        switch self {
        case .left: "Align left"
        case .right: "Align right"
        case .top: "Align top"
        case .bottom: "Align bottom"
        case .center: "Center / fill"
        case .centerWithoutResizing: "Center without resizing"
        }
    }
}

enum WindowTarget: Equatable {
    case frame(CGRect)
    case move(CGPoint)
}

struct WindowCycles<Handle: Hashable> {
    private var edge: (action: ArrangementAction, next: Int)?
    private var fullNext: Set<Handle> = []
    private var focused: Handle?

    mutating func focusChanged(to window: Handle?) {
        guard focused != window else { return }
        focused = window
        resetEdge()
    }

    mutating func resetEdge() {
        edge = nil
    }

    mutating func target(_ action: ArrangementAction, window: Handle, frame: CGRect, usable: CGRect,
                         preferences: Preferences) -> WindowTarget {
        focusChanged(to: window)
        let (horizontalGap, verticalGap) = preferences.windowGaps(in: usable)
        let filled = usable.insetBy(dx: horizontalGap, dy: verticalGap)
        switch action {
        case .left, .right:
            let widths = action == .left ? preferences.leftWidths : preferences.rightWidths
            let fraction = nextFraction(for: action, from: widths)
            let span = Self.edgeSpan(minimum: usable.minX, length: usable.width, fraction: fraction,
                                     gap: horizontalGap, farEdge: action == .right)
            return .frame(CGRect(x: span.origin, y: filled.minY, width: span.length, height: filled.height))
        case .top, .bottom:
            let heights = action == .top ? preferences.topHeights : preferences.bottomHeights
            let fraction = nextFraction(for: action, from: heights)
            let span = Self.edgeSpan(minimum: usable.minY, length: usable.height, fraction: fraction,
                                     gap: verticalGap, farEdge: action == .bottom)
            return .frame(CGRect(x: filled.minX, y: span.origin, width: filled.width, height: span.length))
        case .center:
            resetEdge()
            if fullNext.remove(window) != nil { return .frame(filled) }
            fullNext.insert(window)
            let margin = CGFloat(preferences.marginPercent) / 100
            return .frame(usable.insetBy(dx: max(horizontalGap, usable.width * margin),
                                         dy: max(verticalGap, usable.height * margin)))
        case .centerWithoutResizing:
            resetEdge()
            return .move(CGPoint(x: usable.midX - frame.width / 2, y: usable.midY - frame.height / 2))
        }
    }

    private static func edgeSpan(minimum: CGFloat, length: CGFloat, fraction: CGFloat,
                                 gap: CGFloat, farEdge: Bool) -> (origin: CGFloat, length: CGFloat) {
        // Fractions share an axis of length (length - gap). Each tile gives up one gap,
        // so complementary tiles leave exactly one gap where they meet.
        let tileLength = gap == 0 ? (length * fraction).rounded() : (length - gap) * fraction - gap
        let origin = farEdge ? minimum + length - gap - tileLength : minimum + gap
        return (origin, tileLength)
    }

    private mutating func nextFraction(for action: ArrangementAction, from values: [WindowFraction]) -> CGFloat {
        let index = edge.flatMap { $0.action == action ? $0.next % values.count : nil } ?? 0
        edge = (action, (index + 1) % values.count)
        return CGFloat(values[index].fraction)
    }

    mutating func removeWindows(where predicate: (Handle) -> Bool) {
        fullNext = Set(fullNext.filter { !predicate($0) })
        if let focused, predicate(focused) { focusChanged(to: nil) }
    }
}
