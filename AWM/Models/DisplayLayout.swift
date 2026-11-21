import CryptoKit
import Foundation

private struct DisplayFingerprint: Codable, Equatable {
    let uuid: String?
    let device: String
    let hasSerial: Bool

    init(uuid: String?, model: String, serial: UInt32, salt: UUID?) {
        hasSerial = serial != 0
        guard let salt else {
            self.uuid = uuid
            device = "\(model):\(serial)"
            return
        }
        func digest(_ domain: String, _ value: String) -> String {
            SHA256.hash(data: Data("AWM/display/v1/\(salt.uuidString)/\(domain)/\(value)".utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        self.uuid = uuid.map { digest("uuid", $0) }
        device = hasSerial ? digest("serial", "\(model):\(serial)") : digest("model", model)
    }

    var isValid: Bool {
        func isDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return isDigest(device) && (uuid.map(isDigest) ?? true)
    }
}

struct DisplaySnapshot: Codable, Equatable, Identifiable {
    let id: String
    private let uuid: String?
    private let model: String?
    private let serial: UInt32?
    private let localizedName: String?
    private var fingerprint: DisplayFingerprint? = nil
    let frame: CGRect
    let usable: CGRect
    let scale: CGFloat
    let primary: Bool

    private enum CodingKeys: String, CodingKey {
        case id, uuid, model, serial, localizedName = "name", fingerprint, frame, usable, scale, primary
    }

    init(id: String, uuid: String?, model: String?, serial: UInt32?, name: String?,
         frame: CGRect, usable: CGRect, scale: CGFloat, primary: Bool) {
        self.id = id
        self.uuid = uuid
        self.model = model
        self.serial = serial
        localizedName = name
        self.frame = frame
        self.usable = usable
        self.scale = scale
        self.primary = primary
    }

    var name: String { localizedName ?? "Display" }

    var hasRawIdentity: Bool {
        model != nil && serial != nil && localizedName != nil && fingerprint == nil
    }

    var hasPrivateIdentity: Bool {
        UUID(uuidString: id) != nil && uuid == nil && model == nil && serial == nil && localizedName == nil &&
            fingerprint?.isValid == true
    }

    func forStorage(salt: UUID) throws -> Self {
        if hasPrivateIdentity { return self }
        guard hasRawIdentity, let fingerprint = identity(salt: salt) else { throw WorkspaceError.invalidData }
        var screen = Self(id: UUID().uuidString, uuid: nil, model: nil, serial: nil, name: nil,
                          frame: frame, usable: usable, scale: scale, primary: primary)
        screen.fingerprint = fingerprint
        return screen
    }

    fileprivate func identity(salt: UUID?) -> DisplayFingerprint? {
        if let fingerprint { return fingerprint }
        guard let model, let serial else { return nil }
        return DisplayFingerprint(uuid: uuid, model: model, serial: serial, salt: salt)
    }
}

struct DisplayLayout: Codable, Equatable {
    let screens: [DisplaySnapshot]

    var primary: DisplaySnapshot? {
        screens.first(where: \.primary) ?? screens.first
    }

    static func accessibilityRect(_ appKitRect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: appKitRect.minX, y: primaryTop - appKitRect.maxY,
               width: appKitRect.width, height: appKitRect.height)
    }

    func display(for frame: CGRect) -> DisplaySnapshot? {
        let intersections = screens.map { ($0, frame.intersection($0.frame).area) }
        guard let best = intersections.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return primary }
        return best.0
    }

    func matchesArrangement(_ other: DisplayLayout, salt: UUID? = nil) -> Bool {
        guard screens.count == other.screens.count, !screens.isEmpty else { return false }
        var candidates = other.screens
        for screen in screens {
            guard let index = candidates.firstIndex(where: {
                sameDevice(screen, $0, salt: salt) && screen.frame == $0.frame &&
                    screen.scale == $0.scale && screen.primary == $0.primary
            }) else { return false }
            candidates.remove(at: index)
        }
        return true
    }

    func destinations(from original: DisplayLayout, salt: UUID? = nil) -> [String: DisplaySnapshot] {
        var result: [String: DisplaySnapshot] = [:]
        var available = screens
        for saved in original.screens {
            guard let uuid = saved.identity(salt: salt)?.uuid,
                  let index = available.firstIndex(where: { $0.identity(salt: salt)?.uuid == uuid })
            else { continue }
            result[saved.id] = available.remove(at: index)
        }
        for saved in original.screens where result[saved.id] == nil {
            let options = available.indices.filter { sameDevice(saved, available[$0], salt: salt) }
            guard let index = options.min(by: { distance(saved, available[$0]) < distance(saved, available[$1]) })
            else { continue }
            result[saved.id] = available.remove(at: index)
        }
        return result
    }

    func target(for window: SavedWindow, from original: DisplayLayout,
                destinations: [String: DisplaySnapshot], preferences: Preferences, salt: UUID? = nil) -> CGRect? {
        guard let source = original.screens.first(where: { $0.id == window.displayID }),
              let display = destinations[source.id] ?? primary else { return nil }
        let bounds = display.usable
        let frame: CGRect
        if sameDevice(source, display, salt: salt), source.frame == display.frame,
           source.usable == display.usable, source.scale == display.scale {
            frame = window.frame
        } else {
            let ratio = window.relativeFrame
            let size = CGSize(width: max(1, ratio.width * bounds.width), height: max(1, ratio.height * bounds.height))
            frame = CGRect(x: bounds.minX + ratio.minX * bounds.width,
                           y: bounds.minY + ratio.minY * bounds.height,
                           width: size.width, height: size.height).fitted(in: bounds)
        }
        let gap = preferences.windowGaps(in: bounds)
        guard gap.horizontal > 0 || gap.vertical > 0 else { return frame }
        let inset = bounds.insetBy(dx: gap.horizontal, dy: gap.vertical)
        guard !inset.contains(frame) else { return frame }
        let x = Self.insetSpan(frame.minX...frame.maxX, within: inset.minX...inset.maxX)
        let y = Self.insetSpan(frame.minY...frame.maxY, within: inset.minY...inset.maxY)
        return CGRect(x: x.lowerBound, y: y.lowerBound,
                      width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound)
    }

    func targets(for windows: [SavedWindow], from original: DisplayLayout,
                 destinations: [String: DisplaySnapshot], preferences: Preferences, salt: UUID? = nil) -> [UUID: CGRect] {
        var targets: [UUID: CGRect] = [:]
        for window in windows {
            targets[window.id] = target(for: window, from: original, destinations: destinations,
                                        preferences: preferences, salt: salt)
        }
        return targets
    }

    private static func insetSpan(_ span: ClosedRange<CGFloat>,
                                  within bounds: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        let minimum = max(span.lowerBound, bounds.lowerBound)
        let maximum = min(span.upperBound, bounds.upperBound)
        if maximum - minimum >= min(1, span.upperBound - span.lowerBound) {
            return minimum...maximum
        }
        let length = min(span.upperBound - span.lowerBound, bounds.upperBound - bounds.lowerBound)
        let origin = min(minimum, bounds.upperBound - length)
        return origin...(origin + length)
    }

    private func sameDevice(_ left: DisplaySnapshot, _ right: DisplaySnapshot, salt: UUID?) -> Bool {
        guard let a = left.identity(salt: salt), let b = right.identity(salt: salt) else { return false }
        if let uuid = a.uuid, uuid == b.uuid { return true }
        guard a.device == b.device, a.hasSerial == b.hasSerial else { return false }
        return a.hasSerial || a.uuid == nil || b.uuid == nil
    }

    private func distance(_ a: DisplaySnapshot, _ b: DisplaySnapshot) -> CGFloat {
        abs(a.frame.midX - b.frame.midX) + abs(a.frame.midY - b.frame.midY) +
            abs(a.frame.width - b.frame.width) + abs(a.frame.height - b.frame.height)
    }
}

extension CGRect {
    var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }

    var isUsableWindowFrame: Bool {
        !isNull && !isInfinite && [minX, minY, width, height].allSatisfy(\.isFinite) &&
            width > 0 && height > 0
    }

    func relative(to bounds: CGRect) -> CGRect {
        CGRect(x: (minX - bounds.minX) / bounds.width,
               y: (minY - bounds.minY) / bounds.height,
               width: width / bounds.width, height: height / bounds.height)
    }

    fileprivate func fitted(in bounds: CGRect) -> CGRect {
        let width = min(bounds.width, width)
        let height = min(bounds.height, height)
        let x = min(max(bounds.minX, minX), bounds.maxX - width)
        let y = min(max(bounds.minY, minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func isNear(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
