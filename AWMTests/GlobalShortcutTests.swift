import Carbon
import Testing
@testable import AWM

@Test @MainActor func realShortcutRegistrationRollsBackOnConflictAndStorageFailure() throws {
    let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    let current = try #require(HotKey(code: UInt32(kVK_F18), modifiers: modifiers))
    let occupied = try #require(HotKey(code: UInt32(kVK_F19), modifiers: modifiers))
    let available = try #require(HotKey(code: UInt32(kVK_F20), modifiers: modifiers))
    let action = ShortcutAction.arrange(.left)
    let other = GlobalShortcuts()
    let manager = GlobalShortcuts()
    defer {
        manager.stop()
        other.stop()
    }
    try #require(other.start([KeyboardBinding(action: .arrange(.right), key: occupied)]).isEmpty)
    try #require(manager.start([KeyboardBinding(action: action, key: current)]).isEmpty)

    var persisted = false
    #expect(throws: ShortcutError.self) {
        try manager.apply([KeyboardBinding(action: action, key: occupied)]) {
            persisted = true
        }
    }
    #expect(!persisted)
    #expect(manager.isRegistered(current))

    #expect(throws: WorkspaceError.storageUnavailable) {
        try manager.apply([KeyboardBinding(action: action, key: available)]) {
            throw WorkspaceError.storageUnavailable
        }
    }
    #expect(manager.isRegistered(current))
    #expect(!manager.isRegistered(available))

    try manager.apply([KeyboardBinding(action: action, key: available)]) { persisted = true }
    #expect(persisted)
    #expect(!manager.isRegistered(current))
    #expect(manager.isRegistered(available))

    try manager.apply([]) {}
    #expect(!manager.isRegistered(available))
}
