import Carbon
import Foundation

struct HotKey: Codable, Hashable {
    let code: UInt32
    let modifiers: UInt32

    private static let accepted = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    init?(code: UInt32, modifiers: UInt32) {
        guard code <= 127, modifiers != 0, modifiers & ~Self.accepted == 0,
              !Self.modifierCodes.contains(code) else { return nil }
        self.code = code
        self.modifiers = modifiers
    }

    private static let modifierCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_RightCommand), UInt32(kVK_Shift), UInt32(kVK_RightShift),
        UInt32(kVK_Option), UInt32(kVK_RightOption), UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_Function), UInt32(kVK_CapsLock)
    ]

    private enum CodingKeys: String, CodingKey { case code, modifiers }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = try Self(code: container.decode(UInt32.self, forKey: .code),
                                 modifiers: container.decode(UInt32.self, forKey: .modifiers))
        else { throw WorkspaceError.invalidData }
        self = key
    }

    fileprivate init(defaultCode: Int) {
        code = UInt32(defaultCode)
        modifiers = UInt32(cmdKey | optionKey)
    }
}

enum ShortcutAction: Codable, Hashable {
    case arrange(ArrangementAction)
    case preset(UUID)
}

struct KeyboardBinding: Codable, Equatable {
    let action: ShortcutAction
    let key: HotKey

    static let defaults: [Self] = [
        .init(action: .arrange(.left), key: HotKey(defaultCode: kVK_LeftArrow)),
        .init(action: .arrange(.right), key: HotKey(defaultCode: kVK_RightArrow)),
        .init(action: .arrange(.center), key: HotKey(defaultCode: kVK_Return)),
        .init(action: .arrange(.top), key: HotKey(defaultCode: kVK_UpArrow)),
        .init(action: .arrange(.bottom), key: HotKey(defaultCode: kVK_DownArrow)),
        .init(action: .arrange(.centerWithoutResizing), key: HotKey(defaultCode: kVK_ANSI_C))
    ]
}
