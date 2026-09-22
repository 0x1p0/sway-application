import Foundation
import Carbon
import Combine

/// Carbon hotkeys remain active when the menu bar popover is closed.
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published private(set) var registrationError: String?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var currentHotkey: HotkeyCombo = .none
    private static let signature = OSType(0x5357_4159) // 'SWAY'

    private init() {}

    @discardableResult
    func update(hotkey: HotkeyCombo) -> Bool {
        if hotkey == currentHotkey, hotKeyRef != nil { return true }
        guard unregister() else { return false }
        currentHotkey = hotkey
        registrationError = nil
        guard !hotkey.isEmpty else { return true }
        guard hotkey.modifiers != 0 else {
            registrationError = "Include a modifier such as ⌘, ⌥, or ⌃ in your shortcut."
            return false
        }
        guard installEventHandler() else { return false }
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let result = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, identifier,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard result == noErr else {
            hotKeyRef = nil
            registrationError = "This shortcut is unavailable. Try another combination. (\(result))"
            return false
        }
        return true
    }

    func startWithSavedHotkey() {
        update(hotkey: TrackpadSettings.shared.toggleHotkey)
    }

    private func installEventHandler() -> Bool {
        if eventHandlerRef != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                nil, &identifier)
            guard result == noErr, identifier.signature == HotkeyManager.signature,
                  identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                TrackpadSettings.shared.isEnabled.toggle()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)
        guard result == noErr else {
            eventHandlerRef = nil
            registrationError = "macOS could not enable global shortcuts. (\(result))"
            return false
        }
        return true
    }

    private func unregister() -> Bool {
        guard let reference = hotKeyRef else { return true }
        let result = UnregisterEventHotKey(reference)
        guard result == noErr else {
            registrationError = "macOS could not release the previous shortcut. (\(result))"
            return false
        }
        hotKeyRef = nil
        return true
    }
}
