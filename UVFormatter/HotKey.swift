import AppKit
import Carbon

struct HotKey: Equatable, Codable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let standard = HotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | optionKey | shiftKey))

    static func capture(keyCode: UInt32, modifiers flags: NSEvent.ModifierFlags) -> HotKey? {
        guard flags.intersection([.function, .numericPad]).isEmpty,
              !flags.intersection([.command, .control, .option]).isEmpty,
              ![kVK_Escape, kVK_Return, kVK_Tab, kVK_Delete].contains(Int(keyCode))
        else { return nil }

        var modifiers: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey),
                               (.option, optionKey), (.shift, shiftKey)] where flags.contains(flag) {
            modifiers |= UInt32(carbon)
        }
        if modifiers == UInt32(cmdKey),
           [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A,
            kVK_ANSI_Q, kVK_ANSI_W].contains(Int(keyCode)) {
            return nil
        }
        return HotKey(keyCode: keyCode, modifiers: modifiers)
    }

    var display: String {
        let key = KeyboardLayout.label(keyCode)
        let flags = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return flags.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }
}

private enum KeyboardLayout {
    static func label(_ code: UInt32) -> String {
        if code == UInt32(kVK_Space) { return "空格" }
        let functionCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
                             kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        if let index = functionCodes.firstIndex(of: Int(code)) { return "F\(index + 1)" }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "键码 \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "键码 \(code)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var count = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKey, characters.count, &count, &characters)
        if status == noErr && count > 0 {
            return String(decoding: characters.prefix(count), as: UTF16.self).uppercased()
        }
        return "键码 \(code)"
    }
}

@MainActor
final class HotKeyRegistration {
    private(set) var active: HotKey?
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 0
    private var activeID: UInt32 = 0
    private static let signature: OSType = 0x5556464D // UVFM
    var onPress: (() -> Void)?

    /// Replaces the registered shortcut only after the system accepts the new combination.
    /// A nonzero status leaves the original registration active.
    func register(_ shortcut: HotKey) -> OSStatus {
        if active == shortcut { return noErr }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                let registration = Unmanaged<HotKeyRegistration>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    guard id.signature == HotKeyRegistration.signature, id.id == registration.activeID else {
                        return OSStatus(eventNotHandledErr)
                    }
                    registration.onPress?()
                    return noErr
                }
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return status }
        }
        nextID &+= 1
        var candidate: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &candidate)
        guard status == noErr, let candidate else { return status == noErr ? OSStatus(paramErr) : status }
        if let registration { UnregisterEventHotKey(registration) }
        registration = candidate
        activeID = id.id
        active = shortcut
        return noErr
    }

    /// Releases the keyboard reservation and callback when the AppKit process terminates.
    func stop() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
        active = nil
    }
}
