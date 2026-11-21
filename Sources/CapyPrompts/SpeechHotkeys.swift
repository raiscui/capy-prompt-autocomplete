import Carbon.HIToolbox
import Foundation

private let speechSignature: FourCharCode = 0x4350_5350 // 'CPSP'

final class SpeechHotkeys {
    enum Binding: UInt32, CaseIterable {
        case toggle = 1, replay

        var label: String { self == .toggle ? "⌘F8" : "⇧⌘F8" }
        var modifiers: UInt32 { UInt32(self == .toggle ? cmdKey : (shiftKey | cmdKey)) }
    }

    private var handler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    fileprivate let perform: @MainActor (Binding) -> Void

    init(perform: @escaping @MainActor (Binding) -> Void) throws {
        self.perform = perform
        let target = GetApplicationEventTarget()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(target, speechHotkeyPressed, 1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            throw RegistrationError(message: "朗读快捷键处理器启动失败 (OSStatus \(status)). 请使用菜单朗读.")
        }
        for binding in Binding.allCases {
            var key: EventHotKeyRef?
            let id = EventHotKeyID(signature: speechSignature, id: binding.rawValue)
            let status = RegisterEventHotKey(UInt32(kVK_F8), binding.modifiers, id, target,
                                             UInt32(kEventHotKeyExclusive), &key)
            guard status == noErr, let key else {
                uninstall()
                throw RegistrationError(message: "无法注册 \(binding.label) (OSStatus \(status)). 请使用菜单朗读, 或解除快捷键冲突后重启.")
            }
            keys.append(key)
        }
    }

    private struct RegistrationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func uninstall() {
        for key in keys { UnregisterEventHotKey(key) }
        keys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { uninstall() }
}

private func speechHotkeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                 _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == speechSignature,
          let binding = SpeechHotkeys.Binding(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
    let hotkeys = Unmanaged<SpeechHotkeys>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { hotkeys.perform(binding) }
    return noErr
}
