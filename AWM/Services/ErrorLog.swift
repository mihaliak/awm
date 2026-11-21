import Darwin
import Foundation

struct ErrorLog {
    enum Operation: String {
        case load, save, capture, editPreset, preferences, login, shortcut, arrange, restore
    }

    enum Reason: String {
        case permission, displays, visibility, emptyCapture, missingName, missingPreset, invalidData
        case newerData, storageUnavailable, storageChanged
        case shortcutConflict, shortcutUnavailable, shortcutInvalid, shortcutHandler
        case noFocusedWindow, constrained, placementFailed, displaysChanged, unexpected
    }

    struct Context: Encodable, Equatable {
        var workspace: String?
        var app: String?
        var windowTitle: String?
        var windowSlot: String?
    }

    private struct Entry: Encodable {
        let timestamp: String
        let operation: String
        let reason: String
        let code: Int?
        let context: Context?
    }

    private let url: URL?
    var isEnabled: Bool { url != nil }

    init(url: URL?) {
        self.url = url
    }

    func record(_ operation: Operation, _ error: any Error, context: Context = .init()) {
        switch error {
        case is CancellationError: return
        case let error as WorkspaceError:
            let reason: Reason = switch error {
            case .permission: .permission
            case .displays: .displays
            case .visibility: .visibility
            case .emptyCapture: .emptyCapture
            case .name: .missingName
            case .missingPreset: .missingPreset
            case .invalidData: .invalidData
            case .newerData: .newerData
            case .storageUnavailable: .storageUnavailable
            case .storageChanged: .storageChanged
            }
            record(operation, reason, context: context)
        case let error as ShortcutError:
            switch error {
            case .duplicate: record(operation, .shortcutConflict, context: context)
            case .invalid: record(operation, .shortcutInvalid, context: context)
            case .unavailable(let code): append(operation, Reason.shortcutUnavailable.rawValue, code: Int(code), context: context)
            case .eventHandler(let code): append(operation, Reason.shortcutHandler.rawValue, code: Int(code), context: context)
            }
        default:
            let system = error as NSError
            switch system.domain {
            case NSPOSIXErrorDomain: append(operation, "posix", code: system.code, context: context)
            case NSOSStatusErrorDomain: append(operation, "osstatus", code: system.code, context: context)
            case NSCocoaErrorDomain: append(operation, "cocoa", code: system.code, context: context)
            default: record(operation, .unexpected, context: context)
            }
        }
    }

    func record(_ operation: Operation, _ reason: Reason, context: Context = .init()) {
        append(operation, reason.rawValue, context: context)
    }

    func recordRestore(_ issue: RestoreIssue, context: Context) {
        append(.restore, issue.rawValue, context: context)
    }

    private func append(_ operation: Operation, _ reason: String, code: Int? = nil, context: Context) {
        guard let url else { return }
        let entry = Entry(timestamp: Date().ISO8601Format(), operation: operation.rawValue, reason: reason,
                          code: code, context: context == Context() ? nil : context)
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)

        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return }
        defer { _ = close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1 else { return }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { return }
        }
        guard fchmod(fd, mode_t(0o600)) == 0 else { return }

        line.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count == 0 || errno != EINTR { return }
            }
        }
    }
}
