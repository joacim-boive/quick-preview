import Cocoa
import Carbon

typealias HotkeyHandler = () -> Void

final class GlobalHotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var handler: HotkeyHandler?
    private(set) var activeShortcutName: String = "None"

    @discardableResult
    func registerSpaceHotkey(handler: @escaping HotkeyHandler) -> Bool {
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr else { return noErr }
                if hotKeyID.id == 1 {
                    manager.handler?()
                }
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyHandlerRef
        )

        // Ctrl+Space often conflicts with macOS input source switching.
        // Try multiple simple defaults and use the first that can be registered.
        for candidate in BackgroundShortcutConfiguration.candidates {
            let hotKeyID = EventHotKeyID(signature: OSType(UInt32(truncatingIfNeeded: "QPVW".fourCharCodeValue)), id: 1)
            let status = RegisterEventHotKey(
                candidate.keyCode,
                candidate.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr {
                activeShortcutName = candidate.displayName
                return true
            }
        }

        activeShortcutName = "Unavailable"
        return false
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}

private extension String {
    var fourCharCodeValue: Int {
        utf16.reduce(0) { ($0 << 8) + Int($1) }
    }
}
