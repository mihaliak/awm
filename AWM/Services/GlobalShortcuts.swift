import AppKit
import Carbon

@MainActor
final class GlobalShortcuts {
    private struct Registration {
        let id: UInt32
        let ref: EventHotKeyRef
    }

    private static let signature: OSType = 0x41574D4B // AWMK
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var registered: [HotKey: Registration] = [:]
    private var bindings: [KeyboardBinding] = []
    private var recordingMonitor: Any?
    private var recorder: ((Result<HotKey, Error>?) -> Void)?
    var onAction: ((ShortcutAction) -> Void)?

    func start(_ bindings: [KeyboardBinding], onError: (any Error) -> Void = { _ in }) -> [ShortcutAction] {
        do {
            try installHandler()
        } catch {
            self.bindings = bindings
            if !bindings.isEmpty { onError(error) }
            return bindings.map(\.action)
        }
        self.bindings = bindings
        return bindings.compactMap { binding in
            do {
                try register(binding.key)
                return nil
            } catch {
                onError(error)
                return binding.action
            }
        }
    }

    func apply(_ next: [KeyboardBinding], requiring actions: Set<ShortcutAction> = [],
               persist: () throws -> Void) throws {
        let oldKeys = Set(registered.keys)
        let newKeys = Set(next.map(\.key))
        do {
            for binding in next where !oldKeys.contains(binding.key) &&
                (!bindings.contains(binding) || actions.contains(binding.action)) {
                try installHandler()
                try register(binding.key)
            }
            try persist()
        } catch {
            for key in Set(registered.keys).subtracting(oldKeys) { unregister(key) }
            throw error
        }
        bindings = next
        for key in Set(registered.keys).subtracting(newKeys) { unregister(key) }
    }

    func retry(_ binding: KeyboardBinding) throws {
        try installHandler()
        try register(binding.key)
    }

    func isRegistered(_ key: HotKey) -> Bool { registered[key] != nil }

    func beginRecording(_ receive: @escaping (Result<HotKey, Error>?) -> Void) {
        stopRecording()
        recorder = receive
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let receive = self.recorder else { return event }
            if event.isARepeat { return nil }
            let flags = event.modifierFlags
            if event.keyCode == UInt16(kVK_Escape),
               flags.intersection([.command, .option, .control, .shift]).isEmpty {
                receive(nil)
            } else if let key = HotKey(event: event) {
                receive(.success(key))
            } else {
                receive(.failure(ShortcutError.invalid))
            }
            return nil
        }
    }

    func stopRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        recorder = nil
    }

    func stop() {
        stopRecording()
        for key in Array(registered.keys) { unregister(key) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func installHandler() throws {
        guard eventHandler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let manager = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { manager.receive(id) }
        }, 1, &type, context, &eventHandler)
        guard status == noErr else { throw ShortcutError.eventHandler(status) }
    }

    private func register(_ key: HotKey) throws {
        guard registered[key] == nil else { return }
        let id = nextID
        nextID &+= 1
        let identifier = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.code, key.modifiers, identifier,
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { throw ShortcutError.unavailable(status) }
        registered[key] = Registration(id: id, ref: ref)
    }

    private func unregister(_ key: HotKey) {
        if let prior = registered.removeValue(forKey: key) { UnregisterEventHotKey(prior.ref) }
    }

    private func receive(_ id: EventHotKeyID) -> OSStatus {
        guard id.signature == Self.signature, let entry = registered.first(where: { $0.value.id == id.id })
        else { return OSStatus(eventNotHandledErr) }
        if let recorder {
            recorder(.success(entry.key))
        } else if let binding = bindings.first(where: { $0.key == entry.key }) {
            onAction?(binding.action)
        }
        return noErr
    }
}

extension HotKey {
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(code: UInt32(event.keyCode), modifiers: modifiers)
    }

    var label: String {
        let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        let prefix = symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
        let named: [UInt32: String] = [
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_Return): " Enter", UInt32(kVK_ANSI_KeypadEnter): "⌤",
            UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Escape): "⎋", UInt32(kVK_Space): "Space",
            UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
            UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟"
        ]
        if let name = named[code] { return prefix + name }
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
        ]
        if let index = functionKeys.firstIndex(of: Int(code)) { return prefix + "F\(index + 1)" }
        return prefix + (character ?? "Key \(code)")
    }

    private var character: String? {
        guard let input = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPointer = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let result = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKey, characters.count, &length, &characters)
        guard result == noErr, length > 0 else { return nil }
        return String(decoding: characters.prefix(length), as: UTF16.self).uppercased()
    }
}
