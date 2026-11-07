import Carbon

@MainActor
final class DockWindowShortcut {
    private nonisolated static let signature: OSType = 0x44574D58 // DWMX
    private nonisolated static let shortcutID: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (@MainActor () -> Void)?

    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        if hotKey != nil {
            self.handler = handler
            return true
        }

        let target = GetApplicationEventTarget()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            let result = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identity
            )
            guard result == noErr, identity.signature == DockWindowShortcut.signature,
                  identity.id == DockWindowShortcut.shortcutID else { return OSStatus(eventNotHandledErr) }

            // The application event target dispatches hot keys on the main event loop.
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<DockWindowShortcut>.fromOpaque(context).takeUnretainedValue()
                guard let handler = shortcut.handler else { return OSStatus(eventNotHandledErr) }
                handler()
                return noErr
            }
        }
        let installation = InstallEventHandler(
            target, callback, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        guard installation == noErr, eventHandler != nil else {
            stop()
            return false
        }

        let identity = EventHotKeyID(signature: Self.signature, id: Self.shortcutID)
        let registration = RegisterEventHotKey(
            UInt32(kVK_Return), UInt32(controlKey | optionKey), identity, target,
            OptionBits(kEventHotKeyExclusive), &hotKey
        )
        guard registration == noErr, hotKey != nil else {
            stop()
            return false
        }
        self.handler = handler
        return true
    }

    func stop() {
        handler = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
    }

    isolated deinit {
        stop()
    }
}
